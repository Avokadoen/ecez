const std = @import("std");
const Allocator = std.mem.Allocator;

const testing = std.testing;

const SystemMetadata = @import("SystemMetadata.zig");
const ArcheTree = @import("ArcheTree.zig");
const Archetype = @import("Archetype.zig");
const Entity = @import("entity_type.zig").Entity;
const EntityRef = @import("entity_type.zig").EntityRef;
const query = @import("query.zig");

/// Create a ecs instance. Systems are initially included into the World.
/// Parameters:
///     - systems: a tuple consisting of each system used by the world each frame
pub fn CreateWorld(comptime systems: anytype) type {
    const SystemsType = @TypeOf(systems);
    const systems_info = @typeInfo(SystemsType);
    if (systems_info != .Struct) {
        @compileError("CreateWorld expected tuple or struct argument, found " ++ @typeName(SystemsType));
    }

    const fields_info = systems_info.Struct.fields;
    @setEvalBranchQuota(10_000);
    comptime var systems_count = 0;
    // start by counting systems registered
    inline for (fields_info) |field_info| {
        switch (@typeInfo(field_info.field_type)) {
            .Fn => systems_count += 1,
            else => {
                const err_msg = std.fmt.comptimePrint("CreateWorld expected function or struct at entry {d}, found {s}", .{
                    systems_count,
                    @typeName(field_info.field_type),
                });
                @compileError(err_msg);
            },
        }
    }
    comptime var systems_metadata: [systems_count]SystemMetadata = undefined;
    {
        comptime var i: usize = 0;
        inline for (fields_info) |field_info| {
            switch (@typeInfo(field_info.field_type)) {
                .Fn => |func| {
                    systems_metadata[i] = SystemMetadata.init(field_info.field_type, func);
                    i += 1;
                },
                else => unreachable,
            }
        }
    }

    return struct {
        // TODO: Bump allocate data (instead of calling append)
        // TODO: Thread safety
        const World = @This();
        allocator: Allocator,

        // maps entity id with indices of the storage
        entity_references: std.ArrayList(EntityRef),
        archetree: ArcheTree,

        pub fn init(allocator: Allocator) !World {
            const archetree = try ArcheTree.init(allocator);
            errdefer archetree.deinit();

            return World{
                .allocator = allocator,
                .entity_references = std.ArrayList(EntityRef).init(allocator),
                .archetree = archetree,
            };
        }

        pub fn deinit(self: *World) void {
            self.entity_references.deinit();
            self.archetree.deinit();
        }

        /// Create an empty entity and returns the entity handle.
        /// Consider using buildEntity for a faster entity construction if you have
        /// compile-time entity component types
        pub fn createEntity(self: *World) !Entity {
            const entity = Entity{ .id = @intCast(u32, self.entity_references.items.len) };
            var archetype = self.archetree.voidType();
            const empty: []const []const u8 = &.{};
            try archetype.registerEntity(entity, empty);
            try self.entity_references.append(EntityRef{
                .tree_node_index = 0,
            });
            return entity;
        }

        /// Get a entity builder. A builder has the advantage of not having to dynamically moved
        /// to different archetypes while being constructure compared with createEntity() + addComponent()
        pub fn entityBuilder(self: *World) !EntityBuilder {
            return EntityBuilder.init(self.allocator);
        }

        /// initialize an entity using data supplied to a builder.
        /// The world struct takes ownership of the builder after this
        /// This means that the builder memory is invalidated afterwards
        pub fn fromEntityBuilder(self: *World, builder: *EntityBuilder) !Entity {
            var type_query = query.Runtime.fromOwnedSlices(
                self.allocator,
                builder.type_sizes.toOwnedSlice(),
                builder.type_hashes.toOwnedSlice(),
            );
            defer type_query.deinit();
            const get_result = try self.archetree.getArchetypeAndIndexRuntime(&type_query);

            const entity = Entity{ .id = @intCast(u32, self.entity_references.items.len) };
            try self.entity_references.append(EntityRef{
                .tree_node_index = get_result.node_index,
            });
            errdefer _ = self.entity_references.pop();

            const components = builder.component_data.toOwnedSlice();
            defer {
                for (components) |component_bytes| {
                    builder.allocator.free(component_bytes);
                }
                builder.allocator.free(components);
            }
            // skip void entry
            try get_result.archetype.registerEntity(entity, components[1..]);

            return entity;
        }

        /// Assign a component to an entity
        pub fn setComponent(self: *World, entity: Entity, component: anytype) !void {
            const T = @TypeOf(component);
            const current_archetype = self.archetree.entityRefArchetype(self.entity_references.items[entity.id]);
            if (current_archetype.hasComponent(T)) {
                try current_archetype.setComponent(entity, T, component);
            }

            var type_query = try query.Runtime.fromSlicesAndType(self.allocator, current_archetype.type_sizes, current_archetype.type_hashes, T);
            defer type_query.deinit();

            // get the new entity archetype
            const get_result = try self.archetree.getArchetypeAndIndexRuntime(&type_query);

            try current_archetype.moveEntity(entity, get_result.archetype);
            try get_result.archetype.setComponent(entity, T, component);

            // update the entity reference
            self.entity_references.items[entity.id].tree_node_index = get_result.node_index;
        }

        pub fn getComponent(self: *World, entity: Entity, comptime T: type) !T {
            const current_archetype = self.archetree.entityRefArchetype(self.entity_references.items[entity.id]);
            return current_archetype.getComponent(entity, T);
        }

        pub fn removeComponent(self: *World, entity: Entity, comptime T: type) !void {
            const current_archetype = self.archetree.entityRefArchetype(self.entity_references.items[entity.id]);
            const remove_type_index = try current_archetype.componentIndex(comptime query.hashType(T));

            // create a type query by filtering out the removed type
            var type_query: query.Runtime = blk: {
                if (remove_type_index == 0) {
                    break :blk try query.Runtime.fromSlices(
                        self.allocator,
                        current_archetype.type_sizes[1..],
                        current_archetype.type_hashes[1..],
                    );
                } else if (remove_type_index == current_archetype.type_count - 1) {
                    break :blk try query.Runtime.fromSlices(
                        self.allocator,
                        current_archetype.type_sizes[0..remove_type_index],
                        current_archetype.type_hashes[0..remove_type_index],
                    );
                }

                break :blk try query.Runtime.fromSliceSlices(
                    self.allocator,
                    &[2][]const usize{
                        current_archetype.type_sizes[0..remove_type_index],
                        current_archetype.type_sizes[remove_type_index + 1 ..],
                    },
                    &[2][]const u64{
                        current_archetype.type_hashes[0..remove_type_index],
                        current_archetype.type_hashes[remove_type_index + 1 ..],
                    },
                );
            };
            defer type_query.deinit();

            // get the new entity archetype
            const get_result = try self.archetree.getArchetypeAndIndexRuntime(&type_query);
            try current_archetype.moveEntity(entity, get_result.archetype);

            // update the entity reference
            self.entity_references.items[entity.id].tree_node_index = get_result.node_index;
        }

        pub fn dispatch(self: *World) !void {
            inline for (systems_metadata) |system_metadata, system_index| {
                const query_types = comptime system_metadata.queryArgTypes();
                const param_types = comptime system_metadata.paramArgTypes();

                var archetypes = try self.archetree.getTypeSubsets(self.allocator, &query_types);
                // TODO: cache archetypes until tree changes (new nodes generated)
                defer self.allocator.free(archetypes);

                for (archetypes) |archetype| {
                    const components = try archetype.getComponentStorages(query_types.len, query_types);
                    var i: usize = 0;
                    while (i < components[components.len - 1]) : (i += 1) {
                        var component: std.meta.Tuple(&param_types) = undefined;
                        inline for (param_types) |Param, j| {
                            if (@sizeOf(Param) > 0) {
                                switch (system_metadata.args[j]) {
                                    .value => component[j] = components[j][i],
                                    .ptr => component[j] = &components[j][i],
                                }
                            } else {
                                switch (system_metadata.args[j]) {
                                    .value => component[j] = Param{},
                                    .ptr => component[j] = &Param{},
                                }
                            }
                        }

                        // call either a failable system, or a normal void system
                        if (comptime system_metadata.canReturnError()) {
                            try failableCallWrapper(systems[system_index], component);
                        } else {
                            callWrapper(systems[system_index], component);
                        }
                    }
                }
            }
        }
    };
}

// Workaround see issue #5170 : https://github.com/ziglang/zig/issues/5170
fn callWrapper(func: anytype, args: anytype) void {
    @call(.{}, func, args);
}

// Workaround see issue #5170 : https://github.com/ziglang/zig/issues/5170
fn failableCallWrapper(func: anytype, args: anytype) !void {
    try @call(.{}, func, args);
}

pub const EntityBuilder = struct {
    allocator: Allocator,
    type_count: usize,
    type_sizes: std.ArrayList(usize),
    type_hashes: std.ArrayList(u64),
    component_data: std.ArrayList([]u8),

    /// Initialize a EntityBuilder, should only be called from World.zig
    pub fn init(allocator: Allocator) !EntityBuilder {
        // init by registering the void type
        const type_count = 1;

        var type_sizes = std.ArrayList(usize).init(allocator);
        errdefer type_sizes.deinit();
        try type_sizes.append(0);

        var type_hashes = std.ArrayList(u64).init(allocator);
        errdefer type_hashes.deinit();
        try type_hashes.append(0);

        var component_data = std.ArrayList([]u8).init(allocator);
        errdefer component_data.deinit();
        try component_data.append(&.{});

        return EntityBuilder{
            .allocator = allocator,
            .type_count = type_count,
            .type_sizes = type_sizes,
            .type_hashes = type_hashes,
            .component_data = component_data,
        };
    }

    /// Add component to entity
    pub fn addComponent(self: *EntityBuilder, component: anytype) !void {
        const T = @TypeOf(component);
        const type_hash = query.hashType(T);
        const type_size = @sizeOf(T);

        var type_index: ?usize = null;
        for (self.type_hashes.items) |hash, i| {
            if (type_hash < hash) {
                type_index = i;
                break;
            }
            if (type_hash == hash) return error.ComponentAlreadyExist;
        }

        const component_bytes = blk: {
            const bytes = std.mem.asBytes(&component);
            break :blk try self.allocator.dupe(u8, bytes);
        };
        errdefer self.allocator.free(component_bytes);

        try self.component_data.resize(self.component_data.items.len + 1);
        errdefer self.component_data.shrinkAndFree(self.component_data.items.len - 1);

        try self.type_hashes.append(type_hash);
        errdefer _ = self.type_hashes.popOrNull();

        try self.type_sizes.append(type_size);
        errdefer _ = self.type_sizes.popOrNull();

        self.component_data.items[self.type_count] = component_bytes;
        self.type_count += 1;
        errdefer self.type_count -= 1;

        // if we should move component order
        if (type_index) |index| {
            std.mem.rotate(u64, self.type_hashes.items[index..self.type_count], self.type_count - index - 1);
            std.mem.rotate(usize, self.type_sizes.items[index..self.type_count], self.type_count - index - 1);
            std.mem.rotate([]u8, self.component_data.items[index..self.type_count], self.type_count - index - 1);
        }
    }
};

// world without systems
const StateWorld = CreateWorld(.{});

test "create() entity works" {
    var world = try StateWorld.init(testing.allocator);
    defer world.deinit();

    const entity0 = try world.createEntity();
    try testing.expectEqual(entity0.id, 0);
    const entity1 = try world.createEntity();
    try testing.expectEqual(entity1.id, 1);
}

test "setComponent() component moves entity to correct archetype" {
    const A = struct { some_value: u32 };
    const B = struct { some_value: u8 };

    var world = try StateWorld.init(testing.allocator);
    defer world.deinit();

    const entity1 = try world.createEntity();
    // entity is now a void entity (no components)

    const a = A{ .some_value = 123 };
    try world.setComponent(entity1, a);
    // entity is now of archetype (A)

    const b = B{ .some_value = 42 };
    try world.setComponent(entity1, b);
    // entity is now of archetype (A B)

    const entity_archetype = try world.archetree.getArchetype(&[_]type{ A, B });
    const stored_a = try entity_archetype.getComponent(entity1, A);
    try testing.expectEqual(a, stored_a);
    const stored_b = try entity_archetype.getComponent(entity1, B);
    try testing.expectEqual(b, stored_b);
}

test "getComponent() retrieve component value" {
    const A = struct { some_value: u32 };

    var world = try StateWorld.init(testing.allocator);
    defer world.deinit();

    try world.setComponent(try world.createEntity(), A{ .some_value = 0 });
    try world.setComponent(try world.createEntity(), A{ .some_value = 1 });
    try world.setComponent(try world.createEntity(), A{ .some_value = 2 });

    const entity = try world.createEntity();
    const a = A{ .some_value = 123 };
    try world.setComponent(entity, a);

    try world.setComponent(try world.createEntity(), A{ .some_value = 3 });
    try world.setComponent(try world.createEntity(), A{ .some_value = 4 });

    try testing.expectEqual(a, try world.getComponent(entity, A));
}

test "removeComponent() component moves entity to correct archetype" {
    const A = struct {};
    const B = struct { some_value: u8 };

    var world = try StateWorld.init(testing.allocator);
    defer world.deinit();

    const entity1 = try world.createEntity();
    // entity is now a void entity (no components)

    const a = A{};
    try world.setComponent(entity1, a);
    // entity is now of archetype (A)

    const b = B{ .some_value = 42 };
    try world.setComponent(entity1, b);
    // entity is now of archetype (A B)

    try world.removeComponent(entity1, A);
    // entity is now of archetype (B)

    const entity_archetype = try world.archetree.getArchetype(&[_]type{B});
    const stored_b = try entity_archetype.getComponent(entity1, B);
    try testing.expectEqual(b, stored_b);
}

test "world build entity using EntityBuilder" {
    const A = struct {};
    const B = struct { some_value: u8 };

    var world = try StateWorld.init(testing.allocator);
    defer world.deinit();

    // build a entity using a builder
    var builder = try world.entityBuilder();
    try builder.addComponent(A{});
    try builder.addComponent(B{ .some_value = 42 });
    const entity = try world.fromEntityBuilder(&builder);

    // get expected archetype
    const entity_archetype = try world.archetree.getArchetype(&[_]type{ A, B });
    const entity_b = try entity_archetype.getComponent(entity, B);
    try testing.expectEqual(B{ .some_value = 42 }, entity_b);
}

test "EntityBuilder addComponent() gradually sort" {
    const A = struct { i: usize };
    const B = struct {
        i: usize,
        @"1": usize = 0,
    };
    const C = struct {
        i: usize,
        @"1": usize = 0,
        @"2": usize = 0,
    };
    const D = struct {
        i: usize,
        @"1": usize = 0,
        @"3": usize = 0,
    };
    const E = struct {
        i: usize,
        @"1": usize = 0,
        @"3": usize = 0,
        @"4": usize = 0,
    };
    const types = [_]type{ A, B, C, D, E };

    var builder = try EntityBuilder.init(testing.allocator);
    defer {
        builder.type_sizes.deinit();
        builder.type_hashes.deinit();
        for (builder.component_data.items) |component_bytes| {
            builder.allocator.free(component_bytes);
        }
        builder.component_data.deinit();
    }
    inline for (types) |T, i| {
        try builder.addComponent(T{ .i = i });
    }

    try testing.expectEqual(builder.type_count, types.len + 1);
    inline for (query.sortTypes(&types)) |T, i| {
        try testing.expectEqual(builder.type_hashes.items[i + 1], query.hashType(T));
        try testing.expectEqual(builder.type_sizes.items[i + 1], @sizeOf(T));
        try testing.expectEqual(builder.component_data.items[i + 1].len, @sizeOf(T));
    }
}

test "systems can fail" {
    const A = struct { str: []const u8 };
    const B = struct { some_value: u8 };

    const SystemStruct = struct {
        fn aSystem(a: A) !void {
            try testing.expectEqual(a, .{ .str = "hello world!" });
        }

        fn bSystem(b: B) !void {
            _ = b;
            return error.SomethingWentVeryWrong;
        }
    };

    var world = try CreateWorld(.{
        SystemStruct.aSystem,
        SystemStruct.bSystem,
    }).init(testing.allocator);
    defer world.deinit();

    const entity = try world.createEntity();
    try world.setComponent(entity, A{ .str = "hello world!" });
    try world.setComponent(entity, B{ .some_value = 42 });

    try testing.expectError(error.SomethingWentVeryWrong, world.dispatch());
}

test "systems can mutate values" {
    const A = struct { position: u8 };
    const B = struct { velocity: u8 };

    const SystemStruct = struct {
        fn moveSystem(a: *A, b: B) void {
            a.position += b.velocity;
        }
    };

    var world = try CreateWorld(.{
        SystemStruct.moveSystem,
    }).init(testing.allocator);
    defer world.deinit();

    const entity = try world.createEntity();
    try world.setComponent(entity, A{ .position = 10 });
    try world.setComponent(entity, B{ .velocity = 9 });

    try world.dispatch();

    try testing.expectEqual(A{ .position = 19 }, try world.getComponent(entity, A));
}
