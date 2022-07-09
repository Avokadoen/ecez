const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const Archetype = @import("Archetype.zig");
const EntityRef = @import("entity_type.zig").EntityRef;
const query = @import("query.zig");

const ArcheTree = @This();
// TODO: Allow API user to configure max children,
const node_max_children = 16;

const Node = struct {
    type_hash: u64,
    child_count: u8,
    children_indices: [node_max_children]usize,
    // depending on if a node is in use or not, it has an archetype
    archetype: ?Archetype,
};

/// In the event of a successful retrieval of Archetype you get a GetArchetypeResult
pub const GetArchetypeResult = struct {
    /// The archetype node index, can be used to update entity references
    node_index: usize,
    archetype: *Archetype,
};

allocator: Allocator,
node_storage: std.ArrayList(Node),

// TODO: redesign API and data structure when issue https://github.com/ziglang/zig/issues/1291 is resolved
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
    var root_archetype = try Archetype.initFromTypes(allocator, &[0]type{});
    errdefer root_archetype.deinit();
    const root_node = Node{
        .type_hash = 0,
        .children_indices = undefined,
        .child_count = 0,
        .archetype = root_archetype, // TODO: null
    };

    var node_storage = try std.ArrayList(Node).initCapacity(allocator, 16);
    errdefer node_storage.deinit();
    node_storage.appendAssumeCapacity(root_node);

    return ArcheTree{
        .allocator = allocator,
        .node_storage = node_storage,
    };
}

pub fn deinit(self: ArcheTree) void {
    for (self.node_storage.items) |*node| {
        if (node.archetype) |*archetype| {
            archetype.deinit();
        }
    }
    self.node_storage.deinit();
}

pub fn voidType(self: ArcheTree) *Archetype {
    return &(self.node_storage.items[0].archetype orelse unreachable);
}

pub fn entityRefArchetype(self: ArcheTree, entity_ref: EntityRef) *Archetype {
    return &(self.node_storage.items[entity_ref.tree_node_index].archetype orelse unreachable);
}

/// Query a specific archtype and get a archetype pointer and the underlying archetype node index
/// In the event that the archetype does not exist yet, the type will be constructed and
/// added to the tree
pub fn getArchetype(self: *ArcheTree, comptime Ts: []const type) !*Archetype {
    const result = try self.getArchetypeAndIndex(Ts);
    return result.archetype;
}

/// Query a specific archtype and get a archetype pointer and the underlying archetype node index
/// In the event that the archetype does not exist yet, the type will be constructed and
/// added to the tree
pub fn getArchetypeAndIndex(self: *ArcheTree, comptime Ts: []const type) !GetArchetypeResult {
    const sorted_types = comptime query.sortTypes(Ts);
    const type_sizes = comptime blk: {
        var sizes: [sorted_types.len]usize = undefined;
        inline for (sorted_types) |T, i| {
            sizes[i] = @sizeOf(T);
        }
        break :blk sizes;
    };
    const type_hashes = comptime blk: {
        var hashes: [sorted_types.len]u64 = undefined;
        inline for (sorted_types) |T, i| {
            hashes[i] = query.hashType(T);
        }
        break :blk hashes;
    };
    var type_query = try query.Runtime.fromSlices(self.allocator, type_sizes[0..], type_hashes[0..]);
    defer type_query.deinit();
    return self.getArchetypeAndIndexRuntime(&type_query);
}

/// Query a specific archtype and get a archetype pointer and the underlying archetype node index
/// In the event that the archetype does not exist yet, the type will be constructed and
/// added to the tree
/// Parameters:
///     - self: the archetree
///     - type_sizes: the size of each type which correlate to the hash at the same index, function copy this data
///     - type_hashes: the hash of each type which correlate to the size at the same index, function copy this data
pub fn getArchetypeAndIndexRuntime(self: *ArcheTree, type_query: *query.Runtime) !GetArchetypeResult {
    const Result = union(enum) {
        none,
        some: struct { index: usize, depth: usize },
    };
    const traverse = struct {
        fn func(slf: *ArcheTree, tquery: query.Runtime, current_node_index: usize, depth: usize) Result {
            const node = slf.node_storage.items[current_node_index];

            // if not on the correct branch
            if (node.type_hash != tquery.type_hashes[depth]) {
                return Result.none;
            }

            // if we are on correct branch and reached the final type
            if (depth == tquery.len - 1) {
                return Result{ .some = .{ .index = current_node_index, .depth = depth } };
            }

            // go down the branch
            for (node.children_indices[0..node.child_count]) |child_node_index| {
                // if type was found further down in branch
                switch (func(slf, tquery, child_node_index, depth + 1)) {
                    .some => |value| return Result{ .some = value },
                    .none => {},
                }
            }

            // insufficient branch
            return Result{ .some = .{ .index = current_node_index, .depth = depth } };
        }
    }.func;

    switch (traverse(self, type_query.*, 0, 0)) {
        .some => |value| {
            const node = &self.node_storage.items[value.index];
            // if we found the node
            if (node.type_hash == type_query.type_hashes[type_query.len - 1]) {
                // if archetype already exist
                if (node.archetype) |*archetype| {
                    return GetArchetypeResult{
                        .node_index = value.index,
                        .archetype = archetype,
                    };
                }
                // create an archetype for the node since it is missing
                node.archetype = try Archetype.initFromQueryRuntime(type_query);
                return GetArchetypeResult{
                    .node_index = value.index,
                    .archetype = &(node.archetype orelse unreachable),
                };
            }

            // start creating new branch in tree
            var current_node = &self.node_storage.items[value.index];
            var new_node_index: usize = undefined;
            var i = value.depth + 1;
            while (i < type_query.len) : (i += 1) {
                std.debug.assert(current_node.child_count < node_max_children - 1);
                new_node_index = self.node_storage.items.len;
                current_node.children_indices[current_node.child_count] = new_node_index;
                current_node.child_count += 1;

                // do not create an archetype if the node is currently only used for queries (inactive)
                // we create an archetype for the final leaf node since this is the archetype requested
                const archetype = if (i < type_query.len - 1) null else try Archetype.initFromQueryRuntime(type_query);
                try self.node_storage.append(Node{
                    .type_hash = type_query.type_hashes[i],
                    .children_indices = undefined,
                    .child_count = 0,
                    .archetype = archetype,
                });
                current_node = &self.node_storage.items[new_node_index];
            }
            return GetArchetypeResult{
                .node_index = new_node_index,
                .archetype = &(current_node.archetype orelse unreachable),
            };
        },
        .none => unreachable,
    }
}

/// Caller owns the returned memory
/// Query all type subsets and get each archetype container relevant.
/// Example:
/// Archetype (A B C D) & Archetype (B D) has a common sub type of (B D)
pub fn getTypeSubsets(self: ArcheTree, allocator: Allocator, comptime Ts: []const type) ![]*Archetype {
    const traverse = struct {
        fn func(slf: ArcheTree, type_hashes: []const u64, hash_index: usize, current_node_index: usize, found_archetypes: *std.ArrayList(*Archetype)) Allocator.Error!void {
            const node = &slf.node_storage.items[current_node_index];
            // if we are in a tree branch that is not relevant to the current query subset
            // this works because we always sort by hash value when constructring branches
            if (node.type_hash > type_hashes[hash_index]) {
                return;
            }

            // if all type_hashes have been matched in current branch
            if (hash_index == type_hashes.len - 1 and node.type_hash == type_hashes[hash_index]) {
                if (node.archetype) |*archetype| {
                    try found_archetypes.append(archetype);
                }
            }

            const new_hash_index = blk: {
                // if current node hash matches the next required hash
                if (hash_index < type_hashes.len - 1 and node.type_hash == type_hashes[hash_index]) {
                    break :blk hash_index + 1;
                }
                break :blk hash_index;
            };

            for (node.children_indices[0..node.child_count]) |child_index| {
                try func(slf, type_hashes, new_hash_index, child_index, found_archetypes);
            }
        }
    }.func;
    const sorted_types = query.sortTypes(Ts);
    const type_hashes = comptime blk: {
        var hashes: [sorted_types.len + 1]u64 = undefined;
        hashes[0] = 0;
        inline for (sorted_types) |T, i| {
            hashes[i + 1] = query.hashType(T);
        }
        break :blk hashes;
    };

    var found_archetypes = std.ArrayList(*Archetype).init(allocator);
    errdefer found_archetypes.deinit();

    try traverse(self, type_hashes[0..], 0, 0, &found_archetypes);
    return found_archetypes.toOwnedSlice();
}

// Note for tests: Types are misleading, a type hash value is used to sort and manage types at runtime, so
//                 some tests might seem odd or wrong without this knowledge

test "init() does not leak on allocation failure" {
    // try std.testing.checkAllAllocationFailures(testing.allocator, init, .{});
    var i: usize = 0;
    const arbitrary_allocations = 5;
    while (i < arbitrary_allocations) : (i += 1) {
        // init Trees and ensure that no leaking occurs by using the testing allocator
        var failing_allocator = testing.FailingAllocator.init(testing.allocator, i);
        var tree = init(failing_allocator.allocator()) catch {
            continue;
        };
        tree.deinit();
    }
}

test "getArchetype() generate unique archetypes" {
    const A = struct {};
    const B = struct {};
    const C = struct {};

    var tree = try ArcheTree.init(testing.allocator);
    defer tree.deinit();

    const archetypes = [_][]const type{
        &[_]type{A},
        &[_]type{B},
        &[_]type{C},
        &[_]type{ A, B },
        &[_]type{ A, B, C },
    };
    var results: [archetypes.len]*Archetype = undefined;
    inline for (archetypes) |archetype, index| {
        results[index] = try tree.getArchetype(archetype);
    }

    // Brute force compare all results to ensure each result is unique
    for (results[0 .. results.len - 1]) |result1, i| {
        for (results[i + 1 ..]) |result2| {
            try testing.expect(result1 != result2);
        }
    }
}

test "getArchetype() create archetype for inactive node" {
    const A = struct {};
    const B = struct {};
    const C = struct {};

    var tree = try ArcheTree.init(testing.allocator);
    defer tree.deinit();

    const archetypes = [_][]const type{
        &[_]type{A},
        &[_]type{B},
        &[_]type{C},
        &[_]type{ A, B, C },
    };
    inline for (archetypes) |archetype| {
        _ = try tree.getArchetype(archetype);
    }

    const sorted_types = query.sortTypes(&[_]type{ A, C });
    // this code will reach a unreachable section if there is a bug here
    const result = try tree.getArchetype(&sorted_types);
    inline for (sorted_types) |T, i| {
        try testing.expectEqual(query.hashType(T), result.type_hashes[i]);
    }
}

test "getArchetype() is order-independent" {
    const A = struct {};
    const B = struct {};
    const C = struct {};

    var tree = try ArcheTree.init(testing.allocator);
    defer tree.deinit();

    const result1 = try tree.getArchetype(&[_]type{ A, B, C });
    const result2 = try tree.getArchetype(&[_]type{ A, C, B });
    const result3 = try tree.getArchetype(&[_]type{ C, A, B });
    try testing.expectEqual(result1, result2);
    try testing.expectEqual(result2, result3);
}

test "getArchetype() does not generate duplicate nodes" {
    const A = struct {};
    const B = struct {};
    const C = struct {};
    const D = struct {};
    const E = struct {};
    const F = struct {};

    var tree = try ArcheTree.init(testing.allocator);
    defer tree.deinit();

    _ = try tree.getArchetype(&[_]type{A});
    _ = try tree.getArchetype(&[_]type{B});
    _ = try tree.getArchetype(&[_]type{C});
    _ = try tree.getArchetype(&[_]type{D});
    _ = try tree.getArchetype(&[_]type{E});
    _ = try tree.getArchetype(&[_]type{F});
    _ = try tree.getArchetype(&[_]type{ A, B, C, D, E, F });
    _ = try tree.getArchetype(&[_]type{ B, C, D });
    _ = try tree.getArchetype(&[_]type{ B, C, E });

    // collect the sum of each branch to identify identical branches
    var type_node_values = try testing.allocator.alloc(u128, tree.node_storage.items.len);
    defer testing.allocator.free(type_node_values);
    for (tree.node_storage.items) |node, i| {
        type_node_values[i] = 0;
        if (node.archetype) |archetype| {
            for (archetype.type_hashes) |hashes| {
                type_node_values[i] += @intCast(u128, hashes);
            }
        }
    }

    for (type_node_values[0 .. type_node_values.len - 1]) |node_value1, i| {
        if (node_value1 == 0) continue;
        for (type_node_values[i + 1 ..]) |node_value2| {
            if (node_value2 == 0) continue;
            try testing.expect(node_value1 != node_value2);
        }
    }
}

test "getTypeSubsets() subset retrieve all matching subset" {
    const A = struct {};
    const B = struct {};
    const C = struct {};
    const D = struct {};
    const E = struct {};
    const F = struct {};

    var tree = try ArcheTree.init(testing.allocator);
    defer tree.deinit();

    // Construct a suffienctly complex archetree
    _ = try tree.getArchetype(&[_]type{A});
    _ = try tree.getArchetype(&[_]type{B});
    _ = try tree.getArchetype(&[_]type{C});
    _ = try tree.getArchetype(&[_]type{D});
    _ = try tree.getArchetype(&[_]type{E});
    _ = try tree.getArchetype(&[_]type{F});

    _ = try tree.getArchetype(&[_]type{ A, B, C, D, E, F });
    {
        const results = try tree.getTypeSubsets(testing.allocator, &[_]type{ B, C });
        defer testing.allocator.free(results);
        try testing.expectEqual(@as(usize, 1), results.len);
    }

    _ = try tree.getArchetype(&[_]type{ B, C, D });
    {
        const results = try tree.getTypeSubsets(testing.allocator, &[_]type{ B, C });
        defer testing.allocator.free(results);
        try testing.expectEqual(@as(usize, 2), results.len);
    }

    _ = try tree.getArchetype(&[_]type{ B, C, E });
    {
        const results = try tree.getTypeSubsets(testing.allocator, &[_]type{ B, C });
        defer testing.allocator.free(results);
        try testing.expectEqual(@as(usize, 3), results.len);
    }
}

test "getArchetypeAndIndex() give the correct node index" {
    const A = struct {};
    const B = struct {};
    const C = struct {};
    const D = struct {};
    const E = struct {};
    const F = struct {};

    var tree = try ArcheTree.init(testing.allocator);
    defer tree.deinit();

    const type_arr = [_]type{ A, B, C, D, E, F };
    var results: [type_arr.len]GetArchetypeResult = undefined;
    inline for (type_arr) |T, i| {
        results[i] = try tree.getArchetypeAndIndex(&[_]type{T});
    }

    // we expect each node index to be its index in the result array + 1
    // the tree has a root node which occupy the 0 index, so the first node should be on index 1
    for (results) |result, i| {
        try testing.expectEqual(result.node_index, i + 1);
    }
}
