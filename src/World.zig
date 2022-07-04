const std = @import("std");
const Allocator = std.mem.Allocator;

const testing = std.testing;

const ArcheTree = @import("ArcheTree.zig");
const Archetype = @import("Archetype.zig");
const Entity = @import("entity_type.zig").Entity;
const EntityRef = @import("entity_type.zig").EntityRef;
const query = @import("query.zig");

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

/// create a entity with known components to avoid unnecessary work done by the API compared
/// with createEntity followed by multiple setComponent
pub fn buildEntity(self: *World) !void {
    _ = self;
    return error.Unimplemented;
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

test "create() entity works" {
    var world = try World.init(testing.allocator);
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

    var world = try World.init(testing.allocator);
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
