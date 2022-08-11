const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

// const ztracy = @import("ztracy");

const archetype = @import("archetype.zig");
const Entity = @import("entity_type.zig").Entity;
const query = @import("query.zig");
const Color = @import("misc.zig").Color;

/// an index in the archetype_paths array
pub const ArchetypeRef = usize;
/// Archetable contains the path to the correct archetype given a archetype ref
pub const Archetable = std.ArrayList([]const usize);

pub fn FromTypeArray(comptime submitted_components: []const type) type {
    const components = query.sortTypes(submitted_components);

    return struct {
        const ArcheTree = @This();

        allocator: Allocator,
        root_node: Node,
        // maps entity with index to correct archetype path
        entity_references: std.ArrayList(ArchetypeRef),
        archetype_paths: std.ArrayList(ArchetypePath),
        archetable: Archetable,

        /// initialize the arche type tree
        /// This tree models archetypes into a query friendly structure.
        /// Example:
        /// ```txt
        ///     if we have a game with 3 components, a archetype tree might look like this:
        ///     Root (No components) (1)
        ///     │
        ///     ├─ Position (2)
        ///     │  ├─ Velocity (3)
        ///     │  │  ├─ Health (4)
        ///     │
        ///     ├─ Velocity (5)
        ///     │
        ///     ├─ Health (6)
        /// ```
        /// The archetype in node 4 will be all entities which has a Position, Velocity and Health component.
        /// Node 3 will be all entities that have been assigned a Position and Velocity, but not a Health component.
        /// Node 5 represent all entities that only has velcotiy, etc ...
        ///
        /// An important node when it comes to this structure is that components are order independent.
        /// Order independent means that an entity with a Position and Velocity component is of the same archetype
        /// as an entity with a Velocity and Position component.
        pub fn init(allocator: Allocator) !ArcheTree {
            var root_node = try Node.init(&[0]type{}, allocator);
            errdefer root_node.deinit(&[0]type{}, allocator);

            var archetable = Archetable.init(allocator);
            errdefer archetable.deinit();
            try archetable.append(&[0]usize{});

            const entity_references = std.ArrayList(ArchetypeRef).init(allocator);
            errdefer entity_references.deinit();

            const archetype_paths = std.ArrayList(ArchetypePath).init(allocator);
            errdefer archetype_paths.deinit();
            try archetype_paths.append(ArchetypePath.init(&[0]usize{}));

            return ArcheTree{
                .allocator = allocator,
                .root_node = root_node,
                .archetable = archetable,
                .entity_references = entity_references,
                .archetype_paths = archetype_paths,
            };
        }

        /// deinitialize the arche type tree, freeing allocated memory
        pub fn deinit(self: *ArcheTree) void {
            self.root_node.deinit(&[0]type{}, self.allocator);
            self.archetable.deinit();
            self.entity_references.deinit();
            self.archetype_paths.deinit();
        }

        // TODO: start component type
        /// create a new entity that will exist in the archetree and a single archetype
        pub fn createEntity(self: *ArcheTree) !Entity {
            const entity = Entity{ .id = self.entity_references.items.len };
            const archetype_ref = 0;
            try self.entity_references.append(archetype_ref);

            const Root = archetype.FromTypesArray(&[0]type{});
            const root_arche = @ptrCast(*Root, @alignCast(@alignOf(Root), self.root_node.arche));
            try root_arche.registerEntity(entity, .{});

            return entity;
        }

        pub fn setComponent(self: *ArcheTree, entity: Entity, component: anytype) void {
            const path_index = self.entity_references.items[entity.id];
            const entity_archetype_path = self.archetype_paths.items[path_index];
        }

        const Node = struct {
            arche: *anyopaque,
            children: []?Node,

            pub fn init(comptime types: []const type, allocator: Allocator) !Node {
                const children = try allocator.alloc(?Node, components.len + 1 - types.len);

                const Archetype = archetype.FromTypesArray(types);
                var arche = try allocator.create(Archetype);
                errdefer allocator.destroy(arche);

                arche.* = Archetype.init(allocator);
                errdefer arche.deinit();

                return Node{
                    .arche = @ptrCast(*anyopaque, arche),
                    .children = children,
                };
            }

            pub fn deinit(
                self: *Node,
                comptime types: []const type,
                allocator: Allocator,
            ) void {
                const Archetype = archetype.FromTypesArray(types);
                var arche = @ptrCast(*Archetype, @alignCast(@alignOf(Archetype), self.arche));
                arche.deinit();
                allocator.destroy(arche);

                defer allocator.free(self.children);

                const appended_types_len = types.len + 1;
                comptime var appended_types: [appended_types_len]type = undefined;
                inline for (types) |T, i| {
                    appended_types[i] = T;
                }

                // we sort types and you can't have duplicate types so we do not append types already
                // included in the types slice
                inline for (components[types.len..]) |T, i| {
                    appended_types[types.len] = T;
                    if (self.children[i]) |*child| {
                        child.deinit(&appended_types, allocator);
                    }
                }
            }
        };

        // A way of storing the path to a given archetype
        const ArchetypePath = struct {
            index_sequence: [components.len]usize,

            fn init(comptime types: []const type) ArchetypePath {
                var indices: [components.len]usize = undefined;
                inline for (types) |T, i| {
                    inline for (components) |Component, j| {
                        if (T == Component) {
                            indices[i] = j;
                        }
                    }
                }

                return ArchetypePath{
                    .index_sequence = indices,
                };
            }

            inline fn len(self: ArchetypePath) usize {
                return types.len;
            }
        };
    };
}

test "deinit() traverse to root and clean allocated memory" {
    const A = struct { a: usize };
    const B = struct { b: usize };
    const C = struct {};

    const Tree = FromTypeArray(&[_]type{ A, B, C });
    var tree = try Tree.init(testing.allocator);

    tree.deinit();
}

test "createEntity() create an empty entity" {
    const Tree = FromTypeArray(&[0]type{});
    var tree = try Tree.init(testing.allocator);
    defer tree.deinit();

    const entity0 = try tree.createEntity();
    const entity1 = try tree.createEntity();

    try testing.expectEqual(@as(usize, 0), entity0.id);
    try testing.expectEqual(@as(usize, 1), entity1.id);

    // expect entity reference to point to root archetype
    try testing.expectEqual(@as(usize, 0), tree.entity_references.items[0]);
    try testing.expectEqual(@as(usize, 0), tree.entity_references.items[1]);
}
