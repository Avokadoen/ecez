const std = @import("std");
const Allocator = std.mem.Allocator;

const ztracy = @import("ztracy");

const zjobs = @import("zjobs");
const JobQueue = zjobs.JobQueue(.{});
const JobId = zjobs.JobId;
const Color = @import("misc.zig").Color;

const meta = @import("meta.zig");
const query = @import("query.zig");
const archetype_container = @import("archetype_container.zig");
const opaque_archetype = @import("opaque_archetype.zig");
const Entity = @import("entity_type.zig").Entity;
const iterator = @import("iterator.zig");

pub fn CreateStorage(
    comptime components: anytype,
    comptime shared_state_types: anytype,
) type {
    return struct {
        pub const sorted_component_types = blk: {
            const components_info = @typeInfo(@TypeOf(components));
            if (components_info != .Struct) {
                @compileError("components was not a tuple of types");
            }
            var types: [components_info.Struct.fields.len]type = undefined;
            for (components_info.Struct.fields, 0..) |_, i| {
                types[i] = components[i];
                if (@typeInfo(types[i]) != .Struct) {
                    @compileError("expected " ++ @typeName(types[i]) ++ " component type to be a struct");
                }
            }
            break :blk query.sortTypes(&types);
        };

        pub const ComponentMask = meta.BitMaskFromComponents(&sorted_component_types);
        pub const Container = archetype_container.FromComponents(&sorted_component_types, ComponentMask);
        pub const OpaqueArchetype = opaque_archetype.FromComponentMask(ComponentMask);
        pub const SharedStateStorage = meta.SharedStateStorage(shared_state_types);

        const Storage = @This();

        allocator: Allocator,
        container: Container,
        shared_state: SharedStateStorage,

        /// intialize the storage structure
        /// Parameters:
        ///     - allocator: allocator used when initiating entities
        ///     - shared_state: a tuple with an initial state for ALL shared state data declared when constructing storage type
        pub fn init(allocator: Allocator, shared_state: anytype) error{OutOfMemory}!Storage {
            const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.storage);
            defer zone.End();

            var actual_shared_state: SharedStateStorage = undefined;
            const shared_state_map = meta.typeMap(shared_state_types, @TypeOf(shared_state));
            inline for (shared_state_map, 0..) |index, i| {
                const shared_info = @typeInfo(@TypeOf(shared_state[index]));
                // copy all data except the added magic field
                inline for (shared_info.Struct.fields) |field| {
                    @field(actual_shared_state[i], field.name) = @field(shared_state[index], field.name);
                }
            }

            const container = try Container.init(allocator);
            errdefer container.deinit();

            return Storage{
                .allocator = allocator,
                .container = container,
                .shared_state = actual_shared_state,
            };
        }

        pub fn deinit(self: *Storage) void {
            const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.storage);
            defer zone.End();

            self.container.deinit();
        }

        /// Clear storage memory for reuse. **All entities will become invalid**.
        pub fn clearRetainingCapacity(self: *Storage) void {
            const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.storage);
            defer zone.End();

            self.container.clearRetainingCapacity();
        }

        /// Create an entity and returns the entity handle
        /// Parameters:
        ///     - entity_state: the components that the new entity should be assigned
        pub fn createEntity(self: *Storage, entity_state: anytype) error{OutOfMemory}!Entity {
            const zone = ztracy.ZoneNC(@src(), "Storage createEntity", Color.storage);
            defer zone.End();

            var create_result = try self.container.createEntity(entity_state);
            return create_result.entity;
        }

        /// Reassign a component value owned by entity
        /// Parameters:
        ///     - entity:    the entity that should be assigned the component value
        ///     - component: the new component value
        pub fn setComponent(self: *Storage, entity: Entity, component: anytype) error{ EntityMissing, OutOfMemory }!void {
            const zone = ztracy.ZoneNC(@src(), "Storage setComponent", Color.storage);
            defer zone.End();

            const new_archetype_created = try self.container.setComponent(entity, component);
            _ = new_archetype_created;
        }

        /// Remove a component owned by entity
        /// Parameters:
        ///     - entity:    the entity that should be assigned the component value
        ///     - component: the new component value
        pub fn removeComponent(self: *Storage, entity: Entity, comptime Component: type) error{ EntityMissing, OutOfMemory }!void {
            const zone = ztracy.ZoneNC(@src(), "Storage removeComponent", Color.storage);
            defer zone.End();
            const new_archetype_created = try self.container.removeComponent(entity, Component);
            _ = new_archetype_created;
        }

        /// Check if an entity has a given component
        /// Parameters:
        ///     - entity:    the entity to check for type Component
        ///     - Component: the type of the component to check after
        pub fn hasComponent(self: Storage, entity: Entity, comptime Component: type) bool {
            const zone = ztracy.ZoneNC(@src(), "Storage hasComponent", Color.storage);
            defer zone.End();
            return self.container.hasComponent(entity, Component);
        }

        /// Fetch an entity's component data
        /// Parameters:
        ///     - entity:    the entity to retrieve Component from
        ///     - Component: the type of the component to retrieve
        pub fn getComponent(self: *Storage, entity: Entity, comptime Component: type) error{ ComponentMissing, EntityMissing }!Component {
            const zone = ztracy.ZoneNC(@src(), "Storage getComponent", Color.storage);
            defer zone.End();
            return self.container.getComponent(entity, Component);
        }

        /// get a shared state using the inner type
        pub fn getSharedStateInnerType(self: Storage, comptime InnerType: type) meta.SharedState(InnerType) {
            return self.getSharedStateWithOuterType(meta.SharedState(InnerType));
        }

        /// get a shared state using ecez.SharedState(InnerType) retrieve it's current value
        pub fn getSharedStateWithOuterType(self: Storage, comptime T: type) T {
            const index = indexOfSharedType(T);
            return self.shared_state[index];
        }

        /// set a shared state using the shared state's inner type
        pub fn setSharedState(self: *Storage, state: anytype) void {
            const ActualType = meta.SharedState(@TypeOf(state));
            const index = indexOfSharedType(ActualType);
            self.shared_state[index] = @as(*const ActualType, @ptrCast(&state)).*;
        }

        /// given a shared state type T retrieve it's pointer
        pub fn getSharedStatePtrWithSharedStateType(self: *Storage, comptime PtrT: type) PtrT {
            // figure out which type we are looking for in the storage
            const QueryT = blk: {
                const info = @typeInfo(PtrT);
                if (info != .Pointer) {
                    @compileError("PtrT '" ++ @typeName(PtrT) ++ "' is not a pointer type, this is a ecez bug. please file an issue!");
                }
                const ptr_info = info.Pointer;

                const child_info = @typeInfo(ptr_info.child);
                if (child_info != .Struct) {
                    @compileError("PtrT child '" ++ @typeName(ptr_info.child) ++ " is not a struct type, this is a ecez bug. please file an issue!");
                }
                break :blk ptr_info.child;
            };

            const index = indexOfSharedType(QueryT);
            return &self.shared_state[index];
        }

        pub const EntityQuery = enum {
            exclude_entity,
            include_entity,
        };
        /// Query components which can be iterated upon.
        /// Parameters:
        ///     - entity_query: wether to include the entity variable in the iterator item
        ///     - include_types: all the components you would like to iterate over with the specified field name that should map to the
        ///                      component type. (see IncludeType)
        ///     - exclude_types: all the components that should be excluded from the query result
        ///
        /// Example:
        /// ```
        /// var a_iter = Storage.Query(.exclude_entity, .{ storage.include("a", A) }, .{B}).submit(storage, std.testing.allocator);
        /// defer a_iter.deinit();
        ///
        /// while (a_iter.next()) |item| {
        ///    std.debug.print("{any}", .{item.a});
        /// }
        /// ```
        pub fn Query(comptime entity_query: EntityQuery, comptime include_types: anytype, comptime exclude_types: anytype) type {
            const include_type_info = @typeInfo(@TypeOf(include_types));
            if (include_type_info != .Struct) {
                @compileError("query include types must be a tuple of types");
            }

            const exclude_type_info = @typeInfo(@TypeOf(exclude_types));
            if (exclude_type_info != .Struct) {
                @compileError("query exclude types must be a tuple of types");
            }

            comptime var query_result_names: [include_type_info.Struct.fields.len][]const u8 = undefined;
            comptime var include_inner_type_arr: [include_type_info.Struct.fields.len]type = undefined;
            comptime var include_outer_type_arr: [include_type_info.Struct.fields.len]type = undefined;
            inline for (
                &query_result_names,
                &include_inner_type_arr,
                &include_outer_type_arr,
                include_types,
                0..,
            ) |*query_result_name, *inner_type, *outer_type, include_type, index| {
                if (@TypeOf(include_type) != query.IncludeType) {
                    const compile_error = std.fmt.comptimePrint(
                        "expected include type number {d} to be of type IncludeType, actual type was {any}",
                        .{ index, @TypeOf(include_type) },
                    );
                    @compileError(compile_error);
                }

                query_result_name.* = include_type.name;
                outer_type.* = include_type.type;
                inner_type.* = blk: {
                    const field_info = @typeInfo(include_type.type);
                    if (field_info != .Pointer) {
                        break :blk include_type.type;
                    }

                    break :blk field_info.Pointer.child;
                };

                var type_is_component = false;
                for (sorted_component_types) |Component| {
                    if (inner_type.* == Component) {
                        type_is_component = true;
                        break;
                    }
                }

                if (type_is_component == false) {
                    @compileError("query include types field " ++ include_type.name ++ " is not a registered Storage component");
                }
            }
            query_result_names = query.sortBasedOnTypes(&include_inner_type_arr, []const u8, &query_result_names);
            include_outer_type_arr = query.sortBasedOnTypes(&include_inner_type_arr, type, &include_outer_type_arr);
            include_inner_type_arr = query.sortTypes(&include_inner_type_arr);

            var exclude_type_arr: [exclude_type_info.Struct.fields.len]type = undefined;
            inline for (&exclude_type_arr, exclude_type_info.Struct.fields, 0..) |*exclude_type, field, index| {
                if (field.type != type) {
                    @compileError("query include types field " ++ field.name ++ "must be a component type, was " ++ @typeName(field.type));
                }

                exclude_type.* = exclude_types[index];

                var type_is_component = false;
                for (sorted_component_types) |Component| {
                    if (exclude_type.* == Component) {
                        type_is_component = true;
                        break;
                    }
                }

                if (type_is_component == false) {
                    @compileError("query include types field " ++ field.name ++ " is not a registered Storage component");
                }
            }

            const include_bitmask = comptime include_bit_blk: {
                var bitmask: ComponentMask.Bits = 0;
                inline for (include_inner_type_arr) |Component| {
                    bitmask |= 1 << Container.componentIndex(Component);
                }
                break :include_bit_blk bitmask;
            };
            const exclude_bitmask = comptime include_bit_blk: {
                var bitmask: ComponentMask.Bits = 0;
                inline for (exclude_type_arr) |Component| {
                    bitmask |= 1 << Container.componentIndex(Component);
                }
                break :include_bit_blk bitmask;
            };

            inline for (include_inner_type_arr) |IncType| {
                inline for (exclude_type_arr) |ExType| {
                    if (IncType == ExType) {
                        // illegal query, you are doing something wrong :)
                        @compileError(@typeName(IncType) ++ " is used as an include type, and as a exclude type");
                    }
                }
            }

            const IterType = iterator.FromTypes(
                entity_query == .include_entity,
                &query_result_names,
                &include_outer_type_arr,
                include_bitmask,
                exclude_bitmask,
                OpaqueArchetype,
                Container.BinaryTree,
            );

            return struct {
                comptime secret_field: meta.ArgType = .query,

                pub const Iter = IterType;

                pub fn submit(storage: Storage) Iter {
                    const zone = ztracy.ZoneNC(@src(), "Query submit", Color.storage);
                    defer zone.End();

                    return Iter.init(storage.container.archetypes.items, storage.container.tree);
                }
            };
        }

        fn indexOfSharedType(comptime Shared: type) comptime_int {
            const shared_storage_fields = @typeInfo(SharedStateStorage).Struct.fields;
            inline for (shared_storage_fields, 0..) |field, i| {
                if (field.type == Shared) {
                    return i;
                }
            }
            @compileError(@typeName(Shared) ++ " is not a shared state");
        }
    };
}

const Testing = @import("Testing.zig");
const testing = std.testing;

const StorageStub = CreateStorage(Testing.AllComponentsTuple, .{});

// TODO: we cant use tuples here because of https://github.com/ziglang/zig/issues/12963
const AEntityType = Testing.Archetype.A;
const BEntityType = Testing.Archetype.B;
const AbEntityType = Testing.Archetype.AB;
const AcEntityType = Testing.Archetype.AC;
const BcEntityType = Testing.Archetype.BC;
const AbcEntityType = Testing.Archetype.ABC;

test "init() + deinit() is idempotent" {
    var storage = try StorageStub.init(testing.allocator, .{});
    defer storage.deinit();

    const initial_state = AEntityType{
        .a = Testing.Component.A{},
    };
    const entity0 = try storage.createEntity(initial_state);
    try testing.expectEqual(entity0.id, 0);
    const entity1 = try storage.createEntity(initial_state);
    try testing.expectEqual(entity1.id, 1);
}

test "createEntity() can create empty entities" {
    var storage = try StorageStub.init(testing.allocator, .{});
    defer storage.deinit();

    const entity = try storage.createEntity(.{});
    try testing.expectEqual(false, storage.hasComponent(entity, Testing.Component.A));

    const a = Testing.Component.A{ .value = 123 };
    {
        try storage.setComponent(entity, a);
        try testing.expectEqual(a.value, (try storage.getComponent(entity, Testing.Component.A)).value);
    }

    const b = Testing.Component.B{ .value = 8 };
    {
        try storage.setComponent(entity, b);
        try testing.expectEqual(b.value, (try storage.getComponent(entity, Testing.Component.B)).value);
        try testing.expectEqual(a.value, (try storage.getComponent(entity, Testing.Component.A)).value);
    }
}

test "setComponent() component moves entity to correct archetype" {
    var storage = try StorageStub.init(testing.allocator, .{});
    defer storage.deinit();

    const entity1 = blk: {
        const initial_state = AEntityType{
            .a = Testing.Component.A{},
        };
        break :blk try storage.createEntity(initial_state);
    };

    const a = Testing.Component.A{ .value = 123 };
    try storage.setComponent(entity1, a);

    const b = Testing.Component.B{ .value = 42 };
    try storage.setComponent(entity1, b);

    const stored_a = try storage.getComponent(entity1, Testing.Component.A);
    try testing.expectEqual(a, stored_a);
    const stored_b = try storage.getComponent(entity1, Testing.Component.B);
    try testing.expectEqual(b, stored_b);

    try testing.expectEqual(@as(usize, 1), storage.container.entity_references.items.len);
}

test "setComponent() update entities component state" {
    var storage = try StorageStub.init(testing.allocator, .{});
    defer storage.deinit();

    const initial_state = AbEntityType{
        .a = Testing.Component.A{},
        .b = Testing.Component.B{},
    };
    const entity = try storage.createEntity(initial_state);

    const a = Testing.Component.A{ .value = 123 };
    try storage.setComponent(entity, a);

    const stored_a = try storage.getComponent(entity, Testing.Component.A);
    try testing.expectEqual(a, stored_a);
}

test "setComponent() with empty component moves entity" {
    var storage = try StorageStub.init(testing.allocator, .{});
    defer storage.deinit();

    const initial_state = AbEntityType{
        .a = Testing.Component.A{},
        .b = Testing.Component.B{},
    };
    const entity = try storage.createEntity(initial_state);

    const c = Testing.Component.C{};
    try storage.setComponent(entity, c);

    try testing.expectEqual(true, storage.hasComponent(entity, Testing.Component.C));
}

test "removeComponent() removes the component as expected" {
    var storage = try StorageStub.init(testing.allocator, .{});
    defer storage.deinit();

    const initial_state = BcEntityType{
        .b = Testing.Component.B{},
        .c = Testing.Component.C{},
    };
    const entity = try storage.createEntity(initial_state);

    try storage.setComponent(entity, Testing.Component.A{});
    try testing.expectEqual(true, storage.hasComponent(entity, Testing.Component.A));

    try storage.removeComponent(entity, Testing.Component.A);
    try testing.expectEqual(false, storage.hasComponent(entity, Testing.Component.A));

    try testing.expectEqual(true, storage.hasComponent(entity, Testing.Component.B));

    try storage.removeComponent(entity, Testing.Component.B);
    try testing.expectEqual(false, storage.hasComponent(entity, Testing.Component.B));
}

test "removeComponent() removes all components from entity" {
    var storage = try StorageStub.init(testing.allocator, .{});
    defer storage.deinit();

    const initial_state = AEntityType{
        .a = Testing.Component.A{},
    };
    const entity = try storage.createEntity(initial_state);

    try storage.removeComponent(entity, Testing.Component.A);
    try testing.expectEqual(false, storage.hasComponent(entity, Testing.Component.A));
}

test "hasComponent() responds as expected" {
    var storage = try StorageStub.init(testing.allocator, .{});
    defer storage.deinit();

    const initial_state = AcEntityType{
        .a = Testing.Component.A{},
        .c = Testing.Component.C{},
    };
    const entity = try storage.createEntity(initial_state);

    try testing.expectEqual(true, storage.hasComponent(entity, Testing.Component.A));
    try testing.expectEqual(false, storage.hasComponent(entity, Testing.Component.B));
}

test "getComponent() retrieve component value" {
    var storage = try StorageStub.init(testing.allocator, .{});
    defer storage.deinit();

    var initial_state = AEntityType{
        .a = Testing.Component.A{ .value = 0 },
    };
    _ = try storage.createEntity(initial_state);

    initial_state.a = Testing.Component.A{ .value = 1 };
    _ = try storage.createEntity(initial_state);

    initial_state.a = Testing.Component.A{ .value = 2 };
    _ = try storage.createEntity(initial_state);

    const entity_initial_state = AEntityType{
        .a = Testing.Component.A{ .value = 123 },
    };
    const entity = try storage.createEntity(entity_initial_state);

    initial_state.a = Testing.Component.A{ .value = 3 };
    _ = try storage.createEntity(initial_state);
    initial_state.a = Testing.Component.A{ .value = 4 };
    _ = try storage.createEntity(initial_state);

    try testing.expectEqual(entity_initial_state.a, try storage.getComponent(entity, Testing.Component.A));
}

test "getComponent() can mutate component value with ptr" {
    var storage = try StorageStub.init(testing.allocator, .{});
    defer storage.deinit();

    const initial_state = AEntityType{
        .a = Testing.Component.A{ .value = 0 },
    };
    const entity = try storage.createEntity(initial_state);

    var a_ptr = try storage.getComponent(entity, *Testing.Component.A);
    try testing.expectEqual(initial_state.a, a_ptr.*);

    const mutate_a_value = Testing.Component.A{ .value = 42 };

    // mutate a value ptr
    a_ptr.* = mutate_a_value;

    try testing.expectEqual(mutate_a_value, try storage.getComponent(entity, Testing.Component.A));
}

test "clearRetainingCapacity() allow storage reuse" {
    var storage = try StorageStub.init(testing.allocator, .{});
    defer storage.deinit();

    var first_entity: Entity = undefined;

    const entity_initial_state = AEntityType{
        .a = Testing.Component.A{ .value = 123 },
    };
    var entity: Entity = undefined;

    for (0..100) |i| {
        storage.clearRetainingCapacity();

        var initial_state = AEntityType{
            .a = Testing.Component.A{ .value = 0 },
        };
        _ = try storage.createEntity(initial_state);
        initial_state.a = Testing.Component.A{ .value = 1 };
        _ = try storage.createEntity(initial_state);
        initial_state.a = Testing.Component.A{ .value = 2 };
        _ = try storage.createEntity(initial_state);

        if (i == 0) {
            first_entity = try storage.createEntity(entity_initial_state);
        } else {
            entity = try storage.createEntity(entity_initial_state);
        }

        initial_state.a = Testing.Component.A{ .value = 3 };
        _ = try storage.createEntity(initial_state);
        initial_state.a = Testing.Component.A{ .value = 4 };
        _ = try storage.createEntity(initial_state);
    }

    try testing.expectEqual(first_entity, entity);
    const entity_a = try storage.getComponent(entity, Testing.Component.A);
    try testing.expectEqual(entity_initial_state.a, entity_a);
}

test "getSharedState retrieve state" {
    var storage = try CreateStorage(
        Testing.AllComponentsTuple,
        .{ Testing.Component.A, Testing.Component.B },
    ).init(testing.allocator, .{
        Testing.Component.A{ .value = 4 },
        Testing.Component.B{ .value = 2 },
    });
    defer storage.deinit();

    try testing.expectEqual(@as(u32, 4), storage.getSharedStateInnerType(Testing.Component.A).value);
    try testing.expectEqual(@as(u8, 2), storage.getSharedStateInnerType(Testing.Component.B).value);
}

test "setSharedState retrieve state" {
    var storage = try CreateStorage(
        Testing.AllComponentsTuple,
        .{ Testing.Component.A, Testing.Component.B },
    ).init(testing.allocator, .{
        Testing.Component.A{ .value = 0 },
        Testing.Component.B{ .value = 0 },
    });
    defer storage.deinit();

    const new_shared_a = Testing.Component.A{ .value = 42 };
    storage.setSharedState(new_shared_a);

    try testing.expectEqual(
        new_shared_a,
        @as(*Testing.Component.A, @ptrCast(storage.getSharedStatePtrWithSharedStateType(*meta.SharedState(Testing.Component.A)))).*,
    );
}

test "query with single include type works" {
    var storage = try StorageStub.init(std.testing.allocator, .{});
    defer storage.deinit();

    for (0..100) |index| {
        _ = try storage.createEntity(AbEntityType{
            .a = .{ .value = @as(u32, @intCast(index)) },
            .b = .{ .value = @as(u8, @intCast(index)) },
        });
    }

    {
        var index: usize = 0;
        var a_iter = StorageStub.Query(
            .exclude_entity,
            .{query.include("a", Testing.Component.A)},
            .{},
        ).submit(storage);

        while (a_iter.next()) |item| {
            try std.testing.expectEqual(Testing.Component.A{
                .value = @as(u32, @intCast(index)),
            }, item.a);

            index += 1;
        }
    }
}

test "query with multiple include type works" {
    var storage = try StorageStub.init(std.testing.allocator, .{});
    defer storage.deinit();

    for (0..100) |index| {
        _ = try storage.createEntity(AbEntityType{
            .a = .{ .value = @as(u32, @intCast(index)) },
            .b = .{ .value = @as(u8, @intCast(index)) },
        });
    }

    {
        var a_b_iter = StorageStub.Query(.exclude_entity, .{
            query.include("a", Testing.Component.A),
            query.include("b", Testing.Component.B),
        }, .{}).submit(storage);

        var index: usize = 0;
        while (a_b_iter.next()) |item| {
            try std.testing.expectEqual(Testing.Component.A{
                .value = @as(u32, @intCast(index)),
            }, item.a);

            try std.testing.expectEqual(Testing.Component.B{
                .value = @as(u8, @intCast(index)),
            }, item.b);

            index += 1;
        }
    }
}

test "query with single ptr include type works" {
    var storage = try StorageStub.init(std.testing.allocator, .{});
    defer storage.deinit();

    for (0..100) |index| {
        _ = try storage.createEntity(AbEntityType{
            .a = .{ .value = @as(u32, @intCast(index)) },
            .b = .{ .value = @as(u8, @intCast(index)) },
        });
    }

    {
        var index: usize = 0;
        var a_iter = StorageStub.Query(
            .exclude_entity,
            .{query.include("a_ptr", *Testing.Component.A)},
            .{},
        ).submit(storage);

        while (a_iter.next()) |item| {
            item.a_ptr.value += 1;
            index += 1;
        }
    }

    {
        var index: usize = 1;
        var a_iter = StorageStub.Query(
            .exclude_entity,
            .{query.include("a", Testing.Component.A)},
            .{},
        ).submit(storage);

        while (a_iter.next()) |item| {
            try std.testing.expectEqual(Testing.Component.A{
                .value = @as(u32, @intCast(index)),
            }, item.a);

            index += 1;
        }
    }
}

test "query with single include type and single exclude works" {
    var storage = try StorageStub.init(std.testing.allocator, .{});
    defer storage.deinit();

    for (0..100) |index| {
        _ = try storage.createEntity(AbEntityType{
            .a = .{ .value = @as(u32, @intCast(index)) },
            .b = .{ .value = @as(u8, @intCast(index)) },
        });
    }

    for (100..200) |index| {
        _ = try storage.createEntity(AEntityType{
            .a = .{ .value = @as(u32, @intCast(index)) },
        });
    }

    {
        var iter = StorageStub.Query(
            .exclude_entity,
            .{query.include("a", Testing.Component.A)},
            .{Testing.Component.B},
        ).submit(storage);

        var index: usize = 100;
        while (iter.next()) |item| {
            try std.testing.expectEqual(Testing.Component.A{
                .value = @as(u32, @intCast(index)),
            }, item.a);

            index += 1;
        }
    }
}

test "query with single include type and multiple exclude works" {
    var storage = try StorageStub.init(std.testing.allocator, .{});
    defer storage.deinit();

    for (0..100) |index| {
        _ = try storage.createEntity(AbEntityType{
            .a = .{ .value = @as(u32, @intCast(index)) },
            .b = .{ .value = @as(u8, @intCast(index)) },
        });
    }

    for (100..200) |index| {
        _ = try storage.createEntity(AbcEntityType{
            .a = .{ .value = @as(u32, @intCast(index)) },
            .b = .{ .value = @as(u8, @intCast(index)) },
            .c = .{},
        });
    }

    for (200..300) |index| {
        _ = try storage.createEntity(AEntityType{
            .a = .{ .value = @as(u32, @intCast(index)) },
        });
    }

    {
        var iter = StorageStub.Query(
            .exclude_entity,
            .{query.include("a", Testing.Component.A)},
            .{ Testing.Component.B, Testing.Component.C },
        ).submit(storage);

        var index: usize = 200;
        while (iter.next()) |item| {
            try std.testing.expectEqual(Testing.Component.A{
                .value = @as(u32, @intCast(index)),
            }, item.a);

            index += 1;
        }
    }
}

test "query with entity only works" {
    var storage = try StorageStub.init(std.testing.allocator, .{});
    defer storage.deinit();

    var entities: [200]Entity = undefined;
    for (entities[0..100], 0..) |*entity, index| {
        entity.* = try storage.createEntity(AEntityType{
            .a = .{ .value = @as(u32, @intCast(index)) },
        });
    }
    for (entities[100..200], 100..) |*entity, index| {
        entity.* = try storage.createEntity(AbEntityType{
            .a = .{ .value = @as(u32, @intCast(index)) },
            .b = .{ .value = @as(u8, @intCast(index)) },
        });
    }

    {
        var iter = StorageStub.Query(
            .include_entity,
            .{query.include("a", Testing.Component.A)},
            .{},
        ).submit(storage);

        var index: usize = 0;
        while (iter.next()) |item| {
            try std.testing.expectEqual(entities[index], item.entity);
            index += 1;
        }
    }
}

test "query with entity and include and exclude only works" {
    var storage = try StorageStub.init(std.testing.allocator, .{});
    defer storage.deinit();

    var entities: [200]Entity = undefined;
    for (entities[0..100], 0..) |*entity, index| {
        entity.* = try storage.createEntity(AEntityType{
            .a = .{ .value = @as(u32, @intCast(index)) },
        });
    }
    for (entities[100..200], 100..) |*entity, index| {
        entity.* = try storage.createEntity(AbEntityType{
            .a = .{ .value = @as(u32, @intCast(index)) },
            .b = .{ .value = @as(u8, @intCast(index)) },
        });
    }

    {
        var iter = StorageStub.Query(
            .include_entity,
            .{query.include("a", Testing.Component.A)},
            .{Testing.Component.B},
        ).submit(storage);

        var index: usize = 0;
        while (iter.next()) |item| {
            try std.testing.expectEqual(entities[index], item.entity);
            try std.testing.expectEqual(Testing.Component.A{
                .value = @as(u32, @intCast(index)),
            }, item.a);
            index += 1;
        }
    }
}

// this reproducer never had an issue filed, so no issue number
test "reproducer: component data is mangled by adding additional components to entity" {
    // until issue https://github.com/Avokadoen/ecez/issues/91 is resolved we must make sure to match type names
    const Editor = struct {
        pub const InstanceHandle = packed struct {
            a: u16,
            b: u32,
            c: u16,
        };
    };
    const RenderContext = struct {
        pub const ObjectMetadata = struct {
            a: Entity,
            b: u8,
            c: [64]u8,
        };
    };

    const RepStorage = CreateStorage(.{ Editor.InstanceHandle, RenderContext.ObjectMetadata }, .{});

    var storage = try RepStorage.init(testing.allocator, .{});
    defer storage.deinit();

    const entity = try storage.createEntity(.{});
    const obj = RenderContext.ObjectMetadata{ .a = entity, .b = 0, .c = undefined };
    try storage.setComponent(entity, obj);

    try testing.expectEqual(
        obj,
        try storage.getComponent(entity, RenderContext.ObjectMetadata),
    );

    const instance = Editor.InstanceHandle{ .a = 1, .b = 2, .c = 3 };
    try storage.setComponent(entity, instance);

    try testing.expectEqual(
        obj,
        try storage.getComponent(entity, RenderContext.ObjectMetadata),
    );
    try testing.expectEqual(
        instance,
        try storage.getComponent(entity, Editor.InstanceHandle),
    );
}

// this reproducer never had an issue filed, so no issue number
test "reproducer: component data is mangled by having more than one entity" {
    // until issue https://github.com/Avokadoen/ecez/issues/91 is resolved we must make sure to match type names
    const Editor = struct {
        pub const InstanceHandle = packed struct {
            a: u16,
            b: u32,
            c: u16,
        };
    };
    const RenderContext = struct {
        pub const ObjectMetadata = struct {
            a: Entity,
            b: u8,
            c: [64]u8,
        };
    };

    const RepStorage = CreateStorage(.{ Editor.InstanceHandle, RenderContext.ObjectMetadata }, .{});

    var storage = try RepStorage.init(testing.allocator, .{});
    defer storage.deinit();

    {
        const entity = try storage.createEntity(.{});
        const obj = RenderContext.ObjectMetadata{ .a = entity, .b = 5, .c = undefined };
        try storage.setComponent(entity, obj);
        const instance = Editor.InstanceHandle{ .a = 1, .b = 2, .c = 3 };
        try storage.setComponent(entity, instance);

        const entity_obj = try storage.getComponent(entity, RenderContext.ObjectMetadata);
        try testing.expectEqual(
            obj.a,
            entity_obj.a,
        );
        try testing.expectEqual(
            obj.b,
            entity_obj.b,
        );
        try testing.expectEqual(
            instance,
            try storage.getComponent(entity, Editor.InstanceHandle),
        );
    }
    {
        const entity = try storage.createEntity(.{});
        const obj = RenderContext.ObjectMetadata{ .a = entity, .b = 2, .c = undefined };
        try storage.setComponent(entity, obj);
        const instance = Editor.InstanceHandle{ .a = 1, .b = 1, .c = 1 };
        try storage.setComponent(entity, instance);

        const entity_obj = try storage.getComponent(entity, RenderContext.ObjectMetadata);
        try testing.expectEqual(
            obj.a,
            entity_obj.a,
        );
        try testing.expectEqual(
            obj.b,
            entity_obj.b,
        );
        try testing.expectEqual(
            instance,
            try storage.getComponent(entity, Editor.InstanceHandle),
        );
    }
}

// this reproducer never had an issue filed, so no issue number
test "reproducer: Removing component cause storage to become in invalid state" {
    const InstanceHandle = packed struct {
        a: u16,
        b: u32,
        c: u16,
    };
    const Transform = struct {
        mat: [4]@Vector(4, f32),
    };
    const Position = struct {
        vec: @Vector(4, f32),
    };
    const Rotation = struct {
        quat: @Vector(4, f32),
    };
    const Scale = struct {
        vec: @Vector(4, f32),
    };
    const ObjectMetadata = struct {
        a: Entity,
        b: u8,
        c: [64]u8,
    };

    const RepStorage = CreateStorage(.{
        ObjectMetadata,
        Transform,
        Position,
        Rotation,
        Scale,
        InstanceHandle,
    }, .{});

    var storage = try RepStorage.init(testing.allocator, .{});
    defer storage.deinit();

    var instance_handle = InstanceHandle{ .a = 3, .b = 3, .c = 3 };
    var transform = Transform{ .mat = .{
        [4]f32{ 3, 3, 3, 3 },
        [4]f32{ 3, 3, 3, 3 },
        [4]f32{ 3, 3, 3, 3 },
        [4]f32{ 3, 3, 3, 3 },
    } };
    var position = Position{ .vec = [4]f32{ 3, 3, 3, 3 } };
    var rotation = Rotation{ .quat = [4]f32{ 3, 3, 3, 3 } };
    var scale = Scale{ .vec = [4]f32{ 3, 3, 3, 3 } };
    var obj = ObjectMetadata{ .a = Entity{ .id = 3 }, .b = 3, .c = undefined };

    _ = try storage.createEntity(.{
        instance_handle,
        transform,
        position,
        rotation,
        scale,
        obj,
    });
    const entity = try storage.createEntity(.{
        instance_handle,
        transform,
        position,
        rotation,
        scale,
        obj,
    });
    _ = try storage.createEntity(.{
        instance_handle,
        transform,
        position,
        rotation,
        scale,
        obj,
    });

    try testing.expectEqual(instance_handle, try storage.getComponent(entity, InstanceHandle));
    try testing.expectEqual(transform, try storage.getComponent(entity, Transform));
    try testing.expectEqual(position, try storage.getComponent(entity, Position));
    try testing.expectEqual(rotation, try storage.getComponent(entity, Rotation));
    try testing.expectEqual(scale, try storage.getComponent(entity, Scale));

    _ = try storage.removeComponent(entity, Position);

    try testing.expectEqual(instance_handle, try storage.getComponent(entity, InstanceHandle));
    try testing.expectEqual(transform, try storage.getComponent(entity, Transform));
    try testing.expectEqual(rotation, try storage.getComponent(entity, Rotation));
    try testing.expectEqual(scale, try storage.getComponent(entity, Scale));
}