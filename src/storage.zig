const std = @import("std");
const Allocator = std.mem.Allocator;

const ztracy = @import("ztracy");

const zjobs = @import("zjobs");
const JobQueue = zjobs.JobQueue(.{});
const JobId = zjobs.JobId;
const Color = @import("misc.zig").Color;

const meta = @import("meta.zig");
const archetype_container = @import("archetype_container.zig");
const opaque_archetype = @import("opaque_archetype.zig");
const Entity = @import("entity_type.zig").Entity;
const iterator = @import("iterator.zig");

pub fn CreateStorage(
    comptime components: anytype,
    comptime shared_state_types: anytype,
) type {
    // a flat array of the type of each field in the components tuple
    const component_type_array = verify_and_extract_field_types_blk: {
        const components_info = @typeInfo(@TypeOf(components));
        if (components_info != .Struct) {
            @compileError("components was not a tuple of types");
        }

        var field_types: [components_info.Struct.fields.len]type = undefined;
        for (&field_types, components_info.Struct.fields, 0..) |*field_type, field, component_index| {
            if (@typeInfo(field.type) != .Type) {
                @compileError("components must be a struct of types, field '" ++ field.name ++ "' was " ++ @typeName(field.type));
            }

            if (@typeInfo(components[component_index]) != .Struct) {
                @compileError("component types must be a struct, field '" ++ field.name ++ "' was '" ++ @typeName(components[component_index]));
            }
            field_type.* = components[component_index];
        }
        break :verify_and_extract_field_types_blk field_types;
    };

    return struct {
        pub const ComponentMask = meta.BitMaskFromComponents(&component_type_array);
        pub const Container = archetype_container.FromComponents(&component_type_array, ComponentMask);
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

                switch (shared_info) {
                    .Struct => |struct_info| {
                        // copy all data except the added magic field
                        inline for (struct_info.fields) |field| {
                            @field(actual_shared_state[i], field.name) = @field(shared_state[index], field.name);
                        }
                    },
                    .Pointer => |_| {
                        actual_shared_state[i].ptr = shared_state[index];
                    },
                    else => unreachable,
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

            // validate the entity state before submitting the data to the container
            comptime {
                const state_type_info = @typeInfo(@TypeOf(entity_state));
                if (state_type_info != .Struct) {
                    @compileError(@src().fn_name ++ " expect entity_state to be struct/tuple of components");
                }

                var field_types: [state_type_info.Struct.fields.len]type = undefined;
                inline for (&field_types, state_type_info.Struct.fields) |*field_type, field| {
                    field_type.* = field.type;
                }

                validateComponentOrderAndValidity(&field_types);
            }

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

        /// Reassign a component value owned by entity
        /// Parameters:
        ///     - entity:               the entity that should be assigned the component value
        ///     - struct_of_components: the new component values
        pub fn setComponents(self: *Storage, entity: Entity, struct_of_components: anytype) error{ EntityMissing, OutOfMemory }!void {
            const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.storage);
            defer zone.End();

            // validate the entity state before submitting the data to the container
            comptime {
                const state_type_info = @typeInfo(@TypeOf(struct_of_components));
                if (state_type_info != .Struct) {
                    @compileError(@src().fn_name ++ " expect struct_of_components to be struct/tuple of components");
                }

                var field_types: [state_type_info.Struct.fields.len]type = undefined;
                inline for (&field_types, state_type_info.Struct.fields) |*field_type, field| {
                    field_type.* = field.type;
                }

                validateComponentOrderAndValidity(&field_types);
            }

            const new_archetype_created = try self.container.setComponents(entity, struct_of_components);
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

        /// Query components which can be iterated upon.
        /// Parameters:
        ///     - ResultItem:    All the components you would like to iterate over in a single struct.
        ///                      Each component in the struct will belong to the same entity.
        ///                      A field does not have to be a component if it is of type Entity and it's the first
        ///                      field.
        ///     - exclude_types: All the components that should be excluded from the query result
        ///
        /// Example:
        /// ```
        /// var a_iter = Storage.Query(struct{ entity: Entity, a: A }, .{B}).submit(storage, std.testing.allocator);
        /// defer a_iter.deinit();
        ///
        /// while (a_iter.next()) |item| {
        ///    std.debug.print("{any}", .{item.entity});
        ///    std.debug.print("{any}", .{item.a});
        /// }
        /// ```
        pub fn Query(comptime ResultItem: type, comptime exclude_types: anytype) type {
            const include_type_info = @typeInfo(ResultItem);
            if (include_type_info != .Struct) {
                @compileError("query result_item must be a struct of components");
            }

            const exclude_type_info = @typeInfo(@TypeOf(exclude_types));
            if (exclude_type_info != .Struct) {
                @compileError("query exclude types must be a tuple of types");
            }

            comptime var item_component_count = 0;
            comptime var query_has_entity = false;

            const include_fields = include_type_info.Struct.fields;
            {
                for (include_fields) |field| {
                    if (field.type == Entity) {
                        if (item_component_count != 0) {
                            @compileError("entity must be the first field in a query to be valid");
                        }

                        query_has_entity = true;
                        continue;
                    }

                    item_component_count += 1;
                }
            }

            const after_entity_index = if (query_has_entity) 1 else 0;
            comptime var include_inner_type_arr: [include_type_info.Struct.fields.len - after_entity_index]type = undefined;
            inline for (
                &include_inner_type_arr,
                include_type_info.Struct.fields[after_entity_index..],
            ) |
                *inner_type,
                result_field,
            | {
                inner_type.* = blk: {
                    const field_info = @typeInfo(result_field.type);
                    if (field_info != .Pointer) {
                        break :blk result_field.type;
                    }

                    break :blk field_info.Pointer.child;
                };

                var type_is_component: bool = false;
                inline for (component_type_array) |Component| {
                    if (inner_type.* == Component) {
                        type_is_component = true;
                        break;
                    }
                }

                if (type_is_component == false) {
                    @compileError("query include types field " ++ result_field.name ++ " is not a registered Storage component");
                }
            }

            // validate that the components are in a legal order
            validateComponentOrderAndValidity(&include_inner_type_arr);

            var exclude_type_arr: [exclude_type_info.Struct.fields.len]type = undefined;
            inline for (&exclude_type_arr, exclude_type_info.Struct.fields, 0..) |*exclude_type, field, index| {
                if (field.type != type) {
                    @compileError("query include types field " ++ field.name ++ "must be a component type, was " ++ @typeName(field.type));
                }

                exclude_type.* = exclude_types[index];

                var type_is_component = false;
                for (component_type_array) |Component| {
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
                ResultItem,
                query_has_entity,
                include_bitmask,
                exclude_bitmask,
                OpaqueArchetype,
                Container.BinaryTree,
            );

            return struct {
                comptime secret_field: meta.ArgType = .query,

                pub const Iter = IterType;

                pub fn submit(storage: *Storage) Iter {
                    const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.storage);
                    defer zone.End();
                    return Iter.init(storage.container.archetypes.items, storage.container.tree);
                }
            };
        }

        /// Used by ezby to insert loaded bytes directly into an archetype
        pub inline fn setAndGetArchetypeIndexWithBitmap(self: *Storage, bitmap: ComponentMask.Bits) error{OutOfMemory}!usize {
            const zone = ztracy.ZoneNC(@src(), @src().fn_name, Color.storage);
            defer zone.End();

            return self.container.setAndGetArchetypeIndexWithBitmap(bitmap);
        }

        /// Check if array of component types is ordered the same as the registered components and
        /// if they actually are registered in this storage
        pub inline fn validateComponentOrderAndValidity(comptime other_components: []const type) void {
            meta.comptimeOnlyFn();

            // valid if empty
            if (other_components.len == 0) {
                return;
            }

            // find first index
            var previous_component_index = initial_component_index_blk: {
                inline for (component_type_array, 0..) |Component, comp_index| {
                    if (other_components[0] == Component) {
                        break :initial_component_index_blk comp_index;
                    }
                }
                @compileError("type '" ++ @typeName(other_components[0]) ++ "' is not a registered component type");
            };

            // no more work to do as we validated first component already
            if (other_components.len == 1) {
                return;
            }

            inline for (other_components[1..], 0..) |OtherComponent, prev_other_index| {
                inline for (component_type_array, 0..) |Component, comp_index| {
                    if (OtherComponent == Component) {
                        if (previous_component_index > comp_index) {
                            const error_message = std.fmt.comptimePrint(
                                "Components must be submitted in order they were registered in storage, '{s}' should come *before* '{s}'",
                                .{
                                    @typeName(OtherComponent),
                                    @typeName(other_components[prev_other_index]),
                                },
                            );
                            @compileError(error_message);
                        }
                    }
                }
            }
        }

        fn indexOfSharedType(comptime Shared: type) comptime_int {
            meta.comptimeOnlyFn();

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

test "setComponents() can reassign multiple components" {
    var storage = try StorageStub.init(testing.allocator, .{});
    defer storage.deinit();

    const initial_state = AbEntityType{
        .a = Testing.Component.A{ .value = 0 },
        .b = Testing.Component.B{ .value = 0 },
    };
    const entity = try storage.createEntity(initial_state);

    const new_a = Testing.Component.A{ .value = 1 };
    const new_b = Testing.Component.B{ .value = 2 };
    try storage.setComponents(entity, Testing.Archetype.AB{
        .a = new_a,
        .b = new_b,
    });

    const stored_a = try storage.getComponent(entity, Testing.Component.A);
    try testing.expectEqual(new_a, stored_a);

    const stored_b = try storage.getComponent(entity, Testing.Component.B);
    try testing.expectEqual(new_b, stored_b);
}

test "setComponents() can add new components to entity" {
    var storage = try StorageStub.init(testing.allocator, .{});
    defer storage.deinit();

    const entity = try storage.createEntity(.{});

    const new_a = Testing.Component.A{ .value = 1 };
    const new_b = Testing.Component.B{ .value = 2 };
    try storage.setComponents(entity, Testing.Archetype.AB{
        .a = new_a,
        .b = new_b,
    });

    const stored_a = try storage.getComponent(entity, Testing.Component.A);
    try testing.expectEqual(new_a, stored_a);

    const stored_b = try storage.getComponent(entity, Testing.Component.B);
    try testing.expectEqual(new_b, stored_b);
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

test "shared state can be pointer type" {
    var a = Testing.Component.A{ .value = 0 };

    var storage = try CreateStorage(
        Testing.AllComponentsTuple,
        .{*Testing.Component.A},
    ).init(testing.allocator, .{
        &a,
    });
    defer storage.deinit();

    {
        var a_ptr = storage.getSharedStateInnerType(*Testing.Component.A).ptr;
        a_ptr.value = 69;
    }

    try testing.expectEqual(@as(u32, 69), a.value);
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
            struct { a: Testing.Component.A },
            .{},
        ).submit(&storage);

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
        var a_b_iter = StorageStub.Query(
            struct {
                a: Testing.Component.A,
                b: Testing.Component.B,
            },
            .{},
        ).submit(&storage);

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
            struct { a_ptr: *Testing.Component.A },
            .{},
        ).submit(&storage);

        while (a_iter.next()) |item| {
            item.a_ptr.value += 1;
            index += 1;
        }
    }

    {
        var index: usize = 1;
        var a_iter = StorageStub.Query(
            struct { a: Testing.Component.A },
            .{},
        ).submit(&storage);

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
            struct { a: Testing.Component.A },
            .{Testing.Component.B},
        ).submit(&storage);

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
            struct { a: Testing.Component.A },
            .{ Testing.Component.B, Testing.Component.C },
        ).submit(&storage);

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
            struct {
                entity: Entity,
                a: Testing.Component.A,
            },
            .{},
        ).submit(&storage);

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
            struct {
                entity: Entity,
                a: Testing.Component.A,
            },
            .{Testing.Component.B},
        ).submit(&storage);

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
        obj,
        transform,
        position,
        rotation,
        scale,
        instance_handle,
    });
    const entity = try storage.createEntity(.{
        obj,
        transform,
        position,
        rotation,
        scale,
        instance_handle,
    });
    _ = try storage.createEntity(.{
        obj,
        transform,
        position,
        rotation,
        scale,
        instance_handle,
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

test "reproducer: MineSweeper index out of bound caused by incorrect mapping of query to internal storage" {
    const transform = struct {
        const Position = struct {
            a: u8 = 0.0,
        };

        const Rotation = struct {
            a: u16 = 0.0,
        };

        const Scale = struct {
            a: u32 = 0,
        };

        const WorldTransform = struct {
            a: u64 = 0,
        };
    };

    const Parent = struct {
        a: u128 = 0,
    };
    const Children = struct {
        a: u256 = 0,
    };

    const Storage = CreateStorage(.{
        transform.Position,
        transform.Rotation,
        transform.Scale,
        transform.WorldTransform,
        Parent,
        Children,
    }, .{});

    const QueryItem = struct {
        position: transform.Position,
        rotation: transform.Rotation,
        scale: transform.Scale,
        world_transform: *transform.WorldTransform,
        children: Children,
    };
    const Query = Storage.Query(
        QueryItem,
        // exclude type
        .{Parent},
    );
    var storage = try Storage.init(testing.allocator, .{});
    defer storage.deinit();

    const Node = struct {
        p: transform.Position = .{},
        r: transform.Rotation = .{},
        s: transform.Scale = .{},
        w: transform.WorldTransform = .{},
        c: Children = .{},
    };
    _ = try storage.createEntity(Node{});

    var iter = Query.submit(&storage);

    try testing.expect(iter.next() != null);
}
