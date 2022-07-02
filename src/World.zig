// const std = @import("std");
// const Allocator = std.mem.Allocator;

// const testing = std.testing;

// const ArcheTree = @import("ArcheTree.zig");
// const Archetype = @import("Archetype.zig");
// const Entity = @import("entity_type.zig").Entity;
// const EntityRef = @import("entity_type.zig").EntityRef;
// const query = @import("query.zig");

// // TODO: Bump allocate data (instead of calling append)
// // TODO: Thread safety
// const World = @This();
// allocator: Allocator,

// // maps entity id with indices of the storage
// entity_references: std.ArrayList(EntityRef),
// archetree: ArcheTree,

// pub fn init(allocator: Allocator) !World {
//     const archetree = try ArcheTree.init(allocator);
//     errdefer archetree.deinit();

//     return World{
//         .allocator = allocator,
//         .entity_references = std.ArrayList(EntityRef).init(allocator),
//         .archetree = archetree,
//     };
// }

// pub fn deinit(self: *World) void {
//     self.entity_references.deinit();
//     self.archetree.deinit();
// }

// /// Create an empty entity and returns the entity handle.
// /// Consider using buildEntity for a faster entity construction if you have
// /// compile-time entity component types
// pub fn createEntity(self: *World) !Entity {
//     const entity = Entity{ .id = @intCast(u32, self.entity_references.items.len) };
//     var archetype = self.archetree.voidType();
//     const empty: []const []const u8 = &.{};
//     try archetype.registerEntity(entity, empty);
//     try self.entity_references.append(EntityRef{
//         .tree_node_index = 0,
//     });
//     return entity;
// }

// pub fn buildEntity(self: *World) !void {
//     _ = self;
//     return error.Unimplemented;
// }

// pub fn setComponent(self: *World, entity: Entity, comptime T: type, component: T) !void {
//     const current_archetype = self.archetree.entityRefArchetype(self.entity_references.items[entity.id]);
//     if (current_archetype.hasComponent(T)) {
//         try current_archetype.setComponent(entity, T, component);
//     }

//     // const hash_arr: [Archetype.max_types]u64 = undefined;
//     // std.mem.copy(u64, hash_arr[0..], current_archetype.type_hashes[0..current_archetype.type_count]);
//     // hash_arr[current_archetype.type_hashes.len] = comptime query.hashType(T);
//     // var type_hashes = hash_arr[0 .. current_archetype.type_hashes.len + 1];
//     // std.sort.sort(u64, type_hashes, {}, std.sort.desc(u64));

//     // // const hash_arr: [Archetype.max_types]u64 = undefined;
//     // // std.mem.copy(u64, hash_arr[0..], current_archetype.type_hashes[0..current_archetype.type_count]);
//     // // hash_arr[current_archetype.type_hashes.len] = comptime query.hashType(T);
//     // // var type_hashes = hash_arr[0 .. current_archetype.type_hashes.len + 1];
//     // // std.sort.sort(u64, type_hashes, {}, std.sort.desc(u64));

//     // const new_archetype = self.archetree.getArchetypeFromHash(type_hashes);
//     // _ = new_archetype;
//     return error.Unimplemented;
// }

// test "create() entity works" {
//     var world = try World.init(testing.allocator);
//     defer world.deinit();

//     const entity0 = try world.createEntity();
//     try testing.expectEqual(entity0.id, 0);
//     const entity1 = try world.createEntity();
//     try testing.expectEqual(entity1.id, 1);
// }

// test "add() component works" {
//     const A = struct {
//         some_value: u32,
//     };
//     const B = struct { some_value: u8 };

//     var world = try World.init(testing.allocator);
//     defer world.deinit();

//     {
//         const entity1 = try world.createEntity();
//         const a = A{ .some_value = 123 };
//         try world.setComponent(entity1, A, a);

//         // const opaque_as = world.components.get(@typeName(A)) orelse return error.MissingComponentA;
//         // const as = @bitCast(std.ArrayList(Componentify(A)), opaque_as);
//         // try testing.expectEqual(as.items[0].some_value, a.some_value);
//         // try testing.expectEqual(as.items[0].id, entity1.id);
//     }

//     {
//         const entity2 = try world.createEntity();
//         const b = B{ .some_value = 2 };
//         try world.setComponent(entity2, B, b);

//         // const opaque_bs = world.components.get(@typeName(B)) orelse return error.MissingComponentB;
//         // const bs = @bitCast(std.ArrayList(Componentify(B)), opaque_bs);
//         // try testing.expectEqual(bs.items[0].some_value, b.some_value);
//         // try testing.expectEqual(bs.items[0].id, entity2.id);
//     }
// }
