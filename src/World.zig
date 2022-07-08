const std = @import("std");
const Allocator = std.mem.Allocator;

const testing = std.testing;

const SystemMetadata = @import("SystemMetadata.zig");
const ArcheTree = @import("ArcheTree.zig");
const Archetype = @import("Archetype.zig");
const Entity = @import("entity_type.zig").Entity;
const EntityRef = @import("entity_type.zig").EntityRef;
const query = @import("query.zig");

// TODO: configurable
pub const max_systems = 1024;

/// Create a ecs instance. Systems are initially included into the World.
/// Parameters:
///     - systems: a tuple consisting of each system used by the world each frame
pub fn CreateWorld(comptime systems: anytype) type {
    const SystemsType = @TypeOf(systems);
    const systems_info = @typeInfo(SystemsType);
    if (systems_info != .Struct) {
        @compileError("Expected tuple or struct argument, found " ++ @typeName(SystemsType) ++ "\nSuggestion: put your system(s) in a tuple: .{my_system, another_system}");
    }

    const fields_info = systems_info.Struct.fields;
    if (fields_info.len > max_systems) {
        @compileError("max system count is currently configured to 2024, got " ++ fields_info.len);
    }

    // TODO: care when implementing Struct since fields_info.len will no longer be a valid len ..
    const systems_count = fields_info.len;
    comptime var systems_metadata: [systems_count]SystemMetadata = undefined;
    inline for (fields_info) |field_info, i| {
        switch (@typeInfo(field_info.field_type)) {
            .Struct => @compileError("unimplemented"),
            .Fn => |func| {
                // TODO: care when implementing Struct since i will no longer be a valid index ..
                systems_metadata[i] = SystemMetadata.init(func);
            },
            else => @compileError("Expected function or struct, found " ++ @typeName(field_info.field_type)),
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
        pub fn entityBuilder(self: *World) EntityBuilder {
            return EntityBuilder.init(self.allocator);
        }

        /// initialize an entity using data supplied to a builder.
        /// The world struct takes ownership of the builder after this
        /// This means that the builder memory is invalidated afterwards
        pub fn fromEntityBuilder(self: *World, builder: *EntityBuilder) !Entity {
            const get_result = try self.archetree.getArchetypeAndIndexRuntime(
                builder.type_sizes[0..builder.type_count],
                builder.type_hashes[0..builder.type_count],
            );

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

            try get_result.archetype.registerEntity(entity, components);

            return entity;
        }

        /// Assign a component to an entity
        pub fn setComponent(self: *World, entity: Entity, comptime T: type, component: T) !void {
            const current_archetype = self.archetree.entityRefArchetype(self.entity_references.items[entity.id]);
            if (current_archetype.hasComponent(T)) {
                try current_archetype.setComponent(entity, T, component);
            }

            var type_sizes: [Archetype.max_types]usize = undefined;
            std.mem.copy(usize, type_sizes[0..], current_archetype.type_sizes[0..current_archetype.type_count]);
            type_sizes[current_archetype.type_count] = @sizeOf(T);

            var type_hashes: [Archetype.max_types]u64 = undefined;
            std.mem.copy(u64, type_hashes[0..], current_archetype.type_hashes[0..current_archetype.type_count]);
            type_hashes[current_archetype.type_count] = query.hashType(T);

            // get the new entity archetype
            const get_result = try self.archetree.getArchetypeAndIndexRuntime(
                type_sizes[0 .. current_archetype.type_count + 1],
                type_hashes[0 .. current_archetype.type_count + 1],
            );

            try current_archetype.moveEntity(entity, get_result.archetype);
            try get_result.archetype.setComponent(entity, T, component);

            // update the entity reference
            self.entity_references.items[entity.id].tree_node_index = get_result.node_index;
        }

        pub fn removeComponent(self: *World, entity: Entity, comptime T: type) !void {
            const current_archetype = self.archetree.entityRefArchetype(self.entity_references.items[entity.id]);
            const remove_type_index = try current_archetype.componentIndex(comptime query.hashType(T));

            var type_sizes: [Archetype.max_types]usize = undefined;
            std.mem.copy(usize, type_sizes[0..], current_archetype.type_sizes[0..remove_type_index]);
            var type_hashes: [Archetype.max_types]u64 = undefined;
            std.mem.copy(u64, type_hashes[0..], current_archetype.type_hashes[0..remove_type_index]);

            // if remove element is not the last element, swap element with last element and shift array left
            if (remove_type_index < current_archetype.type_count - 1) {
                std.mem.copy(
                    u64,
                    type_hashes[remove_type_index..],
                    current_archetype.type_hashes[remove_type_index + 1 .. current_archetype.type_count],
                );
                std.mem.copy(
                    usize,
                    type_sizes[remove_type_index..],
                    current_archetype.type_sizes[remove_type_index + 1 .. current_archetype.type_count],
                );
            }

            // get the new entity archetype
            const get_result = try self.archetree.getArchetypeAndIndexRuntime(
                type_sizes[0 .. current_archetype.type_count - 1],
                type_hashes[0 .. current_archetype.type_count - 1],
            );

            try current_archetype.moveEntity(entity, get_result.archetype);

            // update the entity reference
            self.entity_references.items[entity.id].tree_node_index = get_result.node_index;
        }

        pub fn dispatch(self: *World) !void {
            inline for (systems_metadata) |system_metadata, system_index| {
                // TODO: cache archetypes until tree changes (new nodes generated)
                const system_types = comptime system_metadata.queryArgTypes();
                var archetypes = try self.archetree.getTypeSubsets(self.allocator, &system_types);
                defer self.allocator.free(archetypes);
                for (archetypes) |archetype| {
                    const components = try archetype.getComponentStorages(system_types.len, system_types);
                    var i: usize = 0;
                    while (i < components[0].len) : (i += 1) {
                        var component: std.meta.Tuple(&system_types) = undefined;
                        inline for (system_types) |_, j| {
                            component[j] = components[j][i];
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
    type_count: usize,
    type_hashes: [Archetype.max_types]u64,
    type_sizes: [Archetype.max_types]usize,

    allocator: Allocator,
    component_data: std.ArrayList([]u8),

    /// Initialize a EntityBuilder, should only be called from World.zig
    pub fn init(allocator: Allocator) EntityBuilder {
        return EntityBuilder{
            .type_count = 0,
            .type_hashes = undefined,
            .type_sizes = undefined,
            .allocator = allocator,
            .component_data = std.ArrayList([]u8).init(allocator),
        };
    }

    /// Add component to entity
    pub fn addComponent(self: *EntityBuilder, comptime T: type, component: T) !void {
        const type_hash = query.hashType(T);
        const type_size = @sizeOf(T);

        const component_bytes = blk: {
            const bytes = std.mem.asBytes(&component);
            break :blk try self.allocator.dupe(u8, bytes);
        };
        errdefer self.allocator.free(component_bytes);

        var type_index: ?usize = null;
        for (self.type_hashes[0..self.type_count]) |hash, i| {
            if (type_hash < hash) {
                type_index = i;
                break;
            }
        }

        try self.component_data.resize(self.component_data.items.len + 1);
        self.type_hashes[self.type_count] = type_hash;
        self.type_sizes[self.type_count] = type_size;
        self.component_data.items[self.type_count] = component_bytes;
        self.type_count += 1;

        // if we should move component order
        if (type_index) |index| {
            std.mem.rotate(u64, self.type_hashes[index..self.type_count], self.type_count - index - 1);
            std.mem.rotate(usize, self.type_sizes[index..self.type_count], self.type_count - index - 1);
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
    const A = struct {
        some_value: u32,
    };
    const B = struct { some_value: u8 };

    var world = try StateWorld.init(testing.allocator);
    defer world.deinit();

    const entity1 = try world.createEntity();
    // entity is now a void entity (no components)

    const a = A{ .some_value = 123 };
    try world.setComponent(entity1, A, a);
    // entity is now of archetype (A)

    const b = B{ .some_value = 42 };
    try world.setComponent(entity1, B, b);
    // entity is now of archetype (A B)

    const entity_archetype = try world.archetree.getArchetype(&[_]type{ A, B });
    const stored_a = try entity_archetype.getComponent(entity1, A);
    try testing.expectEqual(a, stored_a);
    const stored_b = try entity_archetype.getComponent(entity1, B);
    try testing.expectEqual(b, stored_b);
}

test "removeComponent() component moves entity to correct archetype" {
    const A = struct {};
    const B = struct { some_value: u8 };

    var world = try StateWorld.init(testing.allocator);
    defer world.deinit();

    const entity1 = try world.createEntity();
    // entity is now a void entity (no components)

    const a = A{};
    try world.setComponent(entity1, A, a);
    // entity is now of archetype (A)

    const b = B{ .some_value = 42 };
    try world.setComponent(entity1, B, b);
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
    var builder = world.entityBuilder();
    try builder.addComponent(A, .{});
    try builder.addComponent(B, .{ .some_value = 42 });
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

    var builder = EntityBuilder.init(testing.allocator);
    defer {
        for (builder.component_data.items) |component_bytes| {
            builder.allocator.free(component_bytes);
        }
        builder.component_data.deinit();
    }
    inline for (types) |T, i| {
        try builder.addComponent(T, T{ .i = i });
    }

    try testing.expectEqual(builder.type_count, types.len);
    inline for (query.sortTypes(&types)) |T, i| {
        try testing.expectEqual(builder.type_hashes[i], query.hashType(T));
        try testing.expectEqual(builder.type_sizes[i], @sizeOf(T));
        try testing.expectEqual(builder.component_data.items[i].len, @sizeOf(T));
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

    const entity1 = try world.createEntity();
    try world.setComponent(entity1, A, A{ .str = "hello world!" });
    try world.setComponent(entity1, B, B{ .some_value = 42 });

    try testing.expectError(error.SomethingWentVeryWrong, world.dispatch());
}
