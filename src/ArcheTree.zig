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
    children_indices: [node_max_children]usize,
    child_count: u8,
    archetype: Archetype,
};

allocator: Allocator,
node_storage: std.ArrayList(Node),

// TODO: redesign API and data structure when issue https://github.com/ziglang/zig/issues/1291 is resolved
/// This tree models archetypes into a query friendly structure.
/// Example:
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
///
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
        .archetype = root_archetype,
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
        node.archetype.deinit();
    }
    self.node_storage.deinit();
}

pub fn voidType(self: ArcheTree) *Archetype {
    return &self.node_storage.items[0].archetype;
}

pub fn entityRefArchetype(self: ArcheTree, entity_ref: EntityRef) *Archetype {
    return &self.node_storage.items[entity_ref.tree_node_index].archetype;
}

pub const VisitResult = union(enum) {
    step: void,
    found: *Node,
    abort: void,
};
pub fn traverse(
    self: *ArcheTree,
    context: anytype,
    comptime visit: fn (@TypeOf(context), *Node) VisitResult,
    comptime on_step_out: fn (@TypeOf(context), *Node) void,
) ?*Node {
    const Context = @TypeOf(context);
    const step = struct {
        fn func(s: *ArcheTree, c: Context, node: *Node) ?*Node {
            // if the node visit is satisfied, end traversal
            switch (visit(c, node)) {
                VisitResult.step => {},
                VisitResult.found => |find| return find,
                VisitResult.abort => return null,
            }

            for (node.children_indices[0..node.child_count]) |child_index| {
                if (func(s, c, &s.node_storage.items[child_index])) |find| {
                    return find;
                }
                // used to backtrack side-effects on context relative to current node (if needed)
                on_step_out(c, node);
            }

            return null;
        }
    }.func;

    // recursively traverse archetype tree beginning with root node
    return step(self, context, &self.node_storage.items[0]);
}

/// Query a specific archtype and get a archetype pointer
/// In the event that the archetype does not exist yet, the type will be constructed and
/// added to the tree
pub fn getArchetype(self: *ArcheTree, comptime Ts: []const type) !*Archetype {
    const sorted_types = comptime query.sortTypes(Ts);
    var type_sizes: []usize = undefined;
    var type_hashes: []u64 = undefined;
    inline for (sorted_types) |T, i| {
        type_sizes[i] = @sizeOf(T);
        type_hashes[i] = query.hashType(T);
    }
    const type_query = query.Runtime.init(type_sizes, type_hashes);
    var visit_context = VisitContext{
        .hashes = type_query.type_hashes[0..],
        .index = 0,
        .is_root = true,
        .last_visited_node = null,
    };

    // if we find node we are looking, for return archetype
    if (self.traverse(&visit_context, GetArchetypeTravler.visit, GetArchetypeTravler.on_step_out)) |node| {
        return &node.archetype;
    }

    // archetype does not exist yet and has to be constructed
    var i: usize = undefined;
    var current_node = blk: {
        // if partial archetype exist i.e A + B exist, but not A B C
        if (visit_context.last_visited_node) |node| {
            i = visit_context.index - 1;
            break :blk node;
        }
        i = 0;
        break :blk &self.node_storage.items[0];
    };
    errdefer {
        var j: usize = 0;
        while (j < i) : (j += 1) {
            var node = self.node_storage.pop();
            node.archetype.deinit();
        }
    }
    while (i < type_query.type_count) : (i += 1) {
        std.debug.assert(current_node.child_count < node_max_children - 1);
        const new_node_index = self.node_storage.items.len;
        current_node.children_indices[current_node.child_count] = new_node_index;
        current_node.child_count += 1;
        try self.node_storage.append(Node{
            .type_hash = type_query.type_hashes[i],
            .children_indices = undefined,
            .child_count = 0,
            .archetype = try Archetype.initFromMetaData(
                self.allocator,
                type_query.type_sizes[0..i],
                type_query.type_hashes[0..i],
            ),
        });
        current_node = &self.node_storage.items[new_node_index];
    }

    return &current_node.archetype;
}

pub fn getArchetypeRuntime(self: *ArcheTree, type_hashes: []const u64, type_sizes: []const usize) ?*Archetype {
    std.debug.assert(type_hashes.len == type_sizes.len);

    var visit_context = VisitContext{
        .hashes = type_hashes[0..],
        .index = 0,
        .is_root = true,
        .last_visited_node = null,
    };

    // if we find node we are looking, for return archetype
    if (self.traverse(&visit_context, GetArchetypeTravler.visit, GetArchetypeTravler.on_step_out)) |node| {
        return &node.archetype;
    }

    // archetype does not exist yet and has to be constructed
    var i: usize = undefined;
    var current_node = blk: {
        // if partial archetype exist i.e A + B exist, but not A B C
        if (visit_context.last_visited_node) |node| {
            i = visit_context.index - 1;
            break :blk node;
        }
        i = 0;
        break :blk &self.node_storage.items[0];
    };
    errdefer {
        var j: usize = 0;
        while (j < i) : (j += 1) {
            var node = self.node_storage.pop();
            node.archetype.deinit();
        }
    }

    while (i < type_hashes.len) : (i += 1) {
        std.debug.assert(current_node.child_count < node_max_children - 1);
        const new_node_index = self.node_storage.items.len;
        current_node.children_indices[current_node.child_count] = new_node_index;
        current_node.child_count += 1;
        try self.node_storage.append(Node{
            .type_hash = type_hashes[i],
            .children_indices = undefined,
            .child_count = 0,
            .archetype = try Archetype.initFromMetaData(self.allocator, type_sizes[0..i], type_hashes[0..i]),
        });
        current_node = &self.node_storage.items[new_node_index];
    }

    return &current_node.archetype;
}

/// Caller owns the returned memory
/// Query all type subsets and get each archetype container relevant.
/// Example:
/// Archetype (A B C D) & Archetype (B D) & () has a common sub type of (B D)
pub fn getTypeSubsets(self: *ArcheTree, allocator: Allocator, comptime Ts: []type) ![]*Archetype {
    const Types = comptime query.sortTypes(Ts);
    const type_query = comptime query.typeQuery(Types);
    const TravelContext = struct {
        hashes: []const u64 = type_query[0..],
        hash_index: usize = 0,
        archetypes: std.ArrayList(*Archetype),
    };
    var travel_context = TravelContext{
        .archetypes = try std.ArrayList(*Archetype).initCapacity(allocator, 32),
    };
    errdefer travel_context.archetypes.deinit();

    const travler = struct {
        fn visit(context: *TravelContext, node: *Node) VisitResult {
            // if we are in a tree branch that is not relevant to the current query subset
            // this works because we always sort by hash value when constructring queries (event when we insert)
            if (node.type_hash > context.hashes[context.hash_index]) {
                return VisitResult.abort;
            }
            // if current node hash matches the next required hash
            if (context.hash_index < context.hashes.len - 1 and node.type_hash == context.hashes[context.hash_index]) {
                context.hash_index += 1;
            }
            // if all hashes have been matched in current branch
            if (context.hash_index == context.hashes.len - 1) {
                context.archetypes.append(&node.archetype) catch {
                    std.debug.panic("TODO: remove recursion and return this error instead", .{});
                };
            }
            // keep looking for archetypes with subtype
            return VisitResult.step;
        }

        fn on_step_out(context: *TravelContext, node: *Node) void {
            // if node hash matches the current hash
            if (node.type_hash == context.hashes[context.hash_index]) {
                context.hash_index -= 1;
            }
        }
    };

    // find all archetypes we are looking for
    _ = self.traverse(&travel_context, travler.visit, travler.on_step_out);

    return travel_context.archetypes.toOwnedSlice();
}

const VisitContext = struct {
    hashes: []const u64,
    index: usize,
    is_root: bool,
    last_visited_node: ?*Node,
};
const GetArchetypeTravler = struct {
    fn visit(context: *VisitContext, node: *Node) VisitResult {
        defer context.is_root = false;

        if (context.index >= context.hashes.len) return VisitResult.abort;
        if (context.is_root) return VisitResult.step;

        const hash = context.hashes[context.index];
        if (node.type_hash != hash) {
            return VisitResult.abort;
        }
        context.last_visited_node = node;
        context.index += 1;
        if (context.index == context.hashes.len) {
            return VisitResult{ .found = node };
        }
        return VisitResult.step;
    }

    fn on_step_out(context: *VisitContext, node: *Node) void {
        _ = context;
        _ = node;
    }
};

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
    for (results) |result, index| {
        var jndex: usize = 0;
        while (jndex < results.len) : (jndex += 1) {
            if (index == jndex) continue;
            try testing.expect(result != results[jndex]);
        }
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

test "getTypeSubsets() subset retrieve all matching subsets" {
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
    // create 4 relevant types (C D E F)
    _ = try tree.getArchetype(&[_]type{ A, B, C, D, E, F });
    // create 2 more relevant types (C D)
    _ = try tree.getArchetype(&[_]type{ B, C, D });
    // create 1 more relevant types (E)
    _ = try tree.getArchetype(&[_]type{ B, C, E });

    const results = try tree.getTypeSubsets(testing.allocator, &[_]type{ B, C });
    defer testing.allocator.free(results);

    try testing.expectEqual(results.len, 7);
}
