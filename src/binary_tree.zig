const std = @import("std");
const Allocator = std.mem.Allocator;

const ztracy = @import("ztracy");
const tree_color = @import("misc.zig").Color.tree;

pub fn FromConfig(comptime max_depth: u32, comptime BitMask: type) type {
    const bit_count = @typeInfo(BitMask.Bits).Int.bits;

    return struct {
        pub const Node = struct {
            pub const left = 0;
            pub const right = 1;

            data_index: ?u32,
            bit_pos: BitMask.Shift,
            child: [2]?u32,

            pub fn root() Node {
                return Node{
                    .data_index = null,
                    .bit_pos = 0,
                    .child = [_]?u32{null} ** 2,
                };
            }

            pub fn empty(bit_pos: usize) Node {
                return Node{
                    .data_index = null,
                    .bit_pos = @intCast(BitMask.Shift, bit_pos),
                    .child = [_]?u32{null} ** 2,
                };
            }
        };
        const NodeList = std.ArrayList(Node);

        const BinaryTree = @This();

        node_list: NodeList,

        pub fn init(allocator: Allocator, initial_capacity: usize) error{OutOfMemory}!BinaryTree {
            const zone = ztracy.ZoneNC(@src(), @src().fn_name, tree_color);
            defer zone.End();

            var list = try NodeList.initCapacity(allocator, initial_capacity);
            list.appendAssumeCapacity(Node.root());

            return BinaryTree{
                .node_list = list,
            };
        }

        pub fn deinit(self: BinaryTree) void {
            const zone = ztracy.ZoneNC(@src(), @src().fn_name, tree_color);
            defer zone.End();

            self.node_list.deinit();
        }

        // TODO: state machine to track if we have hit a missing tree branch which means we should just keep instantiating nodes
        /// append a new node at destination by creating the intermediate nodes as well
        pub fn appendChain(self: *BinaryTree, data_index: u32, destination: BitMask.Bits) error{OutOfMemory}!void {
            const zone = ztracy.ZoneNC(@src(), @src().fn_name, tree_color);
            defer zone.End();

            std.debug.assert(destination > 0);

            var current_index: usize = 0;

            const step_count = bit_count - @clz(destination);
            for (0..step_count) |step| {
                const shift = @intCast(BitMask.Shift, step);

                const child_index: usize = if (((destination >> shift) & 1) == 1) Node.right else Node.left;

                current_index = step_blk: {
                    if (self.node_list.items[current_index].child[child_index]) |index| {
                        break :step_blk index;
                    }

                    const index = self.node_list.items.len;
                    try self.node_list.append(Node.empty(step));
                    self.node_list.items[current_index].child[child_index] = @intCast(u32, index);
                    break :step_blk index;
                };
            }

            self.node_list.items[current_index].data_index = data_index;
        }

        pub const IterStack = struct {
            len: usize,
            buffer: [max_depth]u32,

            pub inline fn push(self: *IterStack, node_index: u32) void {
                std.debug.assert(self.len < max_depth);
                self.buffer[self.len] = node_index;
                self.len += 1;
            }

            pub inline fn pop(self: *IterStack) u32 {
                std.debug.assert(self.len > 0);
                self.len -= 1;
                return self.buffer[self.len];
            }

            pub inline fn is_empty(self: IterStack) bool {
                return self.len == 0;
            }
        };
        pub const IterCursor = struct {
            bitmask: BitMask.Bits,
            stack: IterStack,

            /// Initialize a cursor that will begin from the root of the binary tree
            pub fn fromRoot() IterCursor {
                return IterCursor{
                    .bitmask = 0,
                    .stack = .{
                        .len = 1,
                        .buffer = [_]u32{0} ** (Testing.AllComponentsArr.len + 1),
                    },
                };
            }
        };
        /// Iterate the tree, iter_stack *must* have atleast one element.
        pub fn iterate(self: BinaryTree, include_bits: BitMask.Bits, exclude_bits: BitMask.Bits, iter_cursor: *IterCursor) ?u32 {
            const zone = ztracy.ZoneNC(@src(), @src().fn_name, tree_color);
            defer zone.End();

            if (iter_cursor.stack.is_empty()) {
                return null;
            }

            // grab the initial node index
            var current_node_index: ?u32 = iter_cursor.stack.pop();
            while (true) {
                // if our current node index has a value
                if (current_node_index) |index| {
                    // put the value on the stack
                    iter_cursor.stack.push(index);
                    // default to next being null
                    current_node_index = null;

                    // grab current node
                    const current_node = self.node_list.items[index];
                    if (current_node.child[Node.left]) |left_index| {
                        // if there is a left node in current node
                        const left_node = self.node_list.items[left_index];
                        // check if the include filter includes the left branch of the current node
                        if ((include_bits & (@as(BitMask.Bits, 1) << left_node.bit_pos)) == 0) {
                            // proceed by setting next to left if it was queried
                            current_node_index = current_node.child[Node.left];
                        }
                    }
                    // current was null, but we have nodes in stack
                } else if (iter_cursor.stack.is_empty() == false) {
                    const current_index = iter_cursor.stack.pop();
                    const current_node = self.node_list.items[current_index];

                    const current_bit = @as(BitMask.Bits, 1) << current_node.bit_pos;
                    // unset out all prevously set significant bits that are no longer set
                    iter_cursor.bitmask &= current_bit | current_bit - 1;

                    current_node_index = traverse_blk: {
                        const right_child_index = self.node_list.items[current_index].child[Node.right];
                        if (right_child_index) |right_index| {
                            const right_node = self.node_list.items[right_index];
                            const next_bit = @as(BitMask.Bits, 1) << right_node.bit_pos;

                            // if current noder has right child that is excluded by query then ignore it
                            if (exclude_bits & next_bit != 0) {
                                break :traverse_blk null;
                            }

                            // store next bit in cursor
                            iter_cursor.bitmask |= next_bit;
                            // if cursor has all bits queried
                            if (include_bits & iter_cursor.bitmask == include_bits) {
                                // and the next has a data index
                                if (self.node_list.items[right_index].data_index) |data_index| {
                                    // store our iter position for next iteration
                                    iter_cursor.stack.push(right_index);
                                    // return the data index to the caller
                                    return data_index;
                                }
                            }
                        }
                        break :traverse_blk right_child_index;
                    };
                } else {
                    break;
                }
            }

            return null;
        }
    };
}

const testing = std.testing;
const Testing = @import("Testing.zig");
const meta = @import("meta.zig");
const TestMask = meta.BitMaskFromComponents(&Testing.AllComponentsArr);
const TestTree = FromConfig(Testing.AllComponentsArr.len + 1, TestMask);

test "iterate with empty include and exclude mask iterate all" {
    const all_combination_count = std.math.pow(u32, 2, Testing.AllComponentsArr.len);
    var tree = try TestTree.init(testing.allocator, all_combination_count);
    defer tree.deinit();

    for (1..all_combination_count) |mock_data_index| {
        const bitmask = @intCast(TestMask.Bits, mock_data_index);
        tree.appendChain(@intCast(u32, mock_data_index), bitmask) catch unreachable;
    }

    var iter = TestTree.IterCursor.fromRoot();
    inline for ([_]u32{
        Testing.Bits.C,
        Testing.Bits.B,
        Testing.Bits.B | Testing.Bits.C,
        Testing.Bits.A,
        Testing.Bits.A | Testing.Bits.C,
        Testing.Bits.A | Testing.Bits.B,
        Testing.Bits.All,
    }) |expected| {
        const data_index = tree.iterate(0, 0, &iter);
        try testing.expectEqual(expected, data_index.?);
        try testing.expectEqual(@intCast(TestMask.Bits, expected), iter.bitmask);
    }

    try testing.expectEqual(@as(?u32, null), tree.iterate(0, 0, &iter));
    try testing.expectEqual(@as(?u32, null), tree.iterate(0, 0, &iter));
    try testing.expectEqual(@as(?u32, null), tree.iterate(0, 0, &iter));
}

test "iterate with include bit(s), but empty exclude mask iterate all expected" {
    const all_combination_count = std.math.pow(u32, 2, Testing.AllComponentsArr.len);
    var tree = try TestTree.init(testing.allocator, all_combination_count);
    defer tree.deinit();

    for (1..all_combination_count) |mock_data_index| {
        const bitmask = @intCast(TestMask.Bits, mock_data_index);
        tree.appendChain(@intCast(u32, mock_data_index), bitmask) catch unreachable;
    }

    {
        var iter = TestTree.IterCursor.fromRoot();
        inline for ([_]u32{
            Testing.Bits.A,
            Testing.Bits.A | Testing.Bits.C,
            Testing.Bits.A | Testing.Bits.B,
            Testing.Bits.All,
        }) |expected| {
            const data_index = tree.iterate(Testing.Bits.A, 0, &iter);
            try testing.expectEqual(expected, data_index.?);
            try testing.expectEqual(@intCast(TestMask.Bits, expected), iter.bitmask);
        }

        try testing.expectEqual(@as(?u32, null), tree.iterate(Testing.Bits.A, 0, &iter));
    }

    {
        var iter = TestTree.IterCursor.fromRoot();
        inline for ([_]u32{
            Testing.Bits.B,
            Testing.Bits.B | Testing.Bits.C,
            Testing.Bits.A | Testing.Bits.B,
            Testing.Bits.All,
        }) |expected| {
            const data_index = tree.iterate(Testing.Bits.B, 0, &iter);
            try testing.expectEqual(expected, data_index.?);
            try testing.expectEqual(@intCast(TestMask.Bits, expected), iter.bitmask);
        }

        try testing.expectEqual(@as(?u32, null), tree.iterate(Testing.Bits.B, 0, &iter));
    }

    {
        var iter = TestTree.IterCursor.fromRoot();
        inline for ([_]u32{
            Testing.Bits.C,
            Testing.Bits.B | Testing.Bits.C,
            Testing.Bits.A | Testing.Bits.C,
            Testing.Bits.All,
        }) |expected| {
            const data_index = tree.iterate(Testing.Bits.C, 0, &iter);
            try testing.expectEqual(expected, data_index.?);
            try testing.expectEqual(@intCast(TestMask.Bits, expected), iter.bitmask);
        }

        try testing.expectEqual(@as(?u32, null), tree.iterate(Testing.Bits.C, 0, &iter));
    }

    {
        var iter = TestTree.IterCursor.fromRoot();
        inline for ([_]u32{
            Testing.Bits.A | Testing.Bits.B,
            Testing.Bits.All,
        }) |expected| {
            const data_index = tree.iterate(Testing.Bits.A | Testing.Bits.B, 0, &iter);
            try testing.expectEqual(expected, data_index.?);
            try testing.expectEqual(@intCast(TestMask.Bits, expected), iter.bitmask);
        }

        try testing.expectEqual(@as(?u32, null), tree.iterate(Testing.Bits.A | Testing.Bits.B, 0, &iter));
    }

    {
        var iter = TestTree.IterCursor.fromRoot();
        inline for ([_]u32{
            Testing.Bits.A | Testing.Bits.C,
            Testing.Bits.All,
        }) |expected| {
            const data_index = tree.iterate(Testing.Bits.A | Testing.Bits.C, 0, &iter);
            try testing.expectEqual(expected, data_index.?);
            try testing.expectEqual(@intCast(TestMask.Bits, expected), iter.bitmask);
        }

        try testing.expectEqual(@as(?u32, null), tree.iterate(Testing.Bits.A | Testing.Bits.C, 0, &iter));
    }

    {
        var iter = TestTree.IterCursor.fromRoot();
        inline for ([_]u32{
            Testing.Bits.B | Testing.Bits.C,
            Testing.Bits.All,
        }) |expected| {
            const data_index = tree.iterate(Testing.Bits.B | Testing.Bits.C, 0, &iter);
            try testing.expectEqual(expected, data_index.?);
            try testing.expectEqual(@intCast(TestMask.Bits, expected), iter.bitmask);
        }

        try testing.expectEqual(@as(?u32, null), tree.iterate(Testing.Bits.B | Testing.Bits.C, 0, &iter));
    }

    {
        var iter = TestTree.IterCursor.fromRoot();
        inline for ([_]u32{
            Testing.Bits.All,
        }) |expected| {
            const data_index = tree.iterate(Testing.Bits.All, 0, &iter);
            try testing.expectEqual(expected, data_index.?);
            try testing.expectEqual(@intCast(TestMask.Bits, expected), iter.bitmask);
        }

        try testing.expectEqual(@as(?u32, null), tree.iterate(Testing.Bits.All, 0, &iter));
    }
}

test "iterate with empty include bits, but exclude mask bit(s) iterate all expected" {
    const all_combination_count = std.math.pow(u32, 2, Testing.AllComponentsArr.len);
    var tree = try TestTree.init(testing.allocator, all_combination_count);
    defer tree.deinit();

    for (1..all_combination_count) |mock_data_index| {
        const bitmask = @intCast(TestMask.Bits, mock_data_index);
        tree.appendChain(@intCast(u32, mock_data_index), bitmask) catch unreachable;
    }

    {
        var iter = TestTree.IterCursor.fromRoot();
        inline for ([_]u32{
            Testing.Bits.C,
            Testing.Bits.B,
            Testing.Bits.B | Testing.Bits.C,
        }) |expected| {
            const data_index = tree.iterate(0, Testing.Bits.A, &iter);
            try testing.expectEqual(expected, data_index.?);
            try testing.expectEqual(@intCast(TestMask.Bits, expected), iter.bitmask);
        }

        try testing.expectEqual(@as(?u32, null), tree.iterate(0, Testing.Bits.A, &iter));
    }

    {
        var iter = TestTree.IterCursor.fromRoot();
        inline for ([_]u32{
            Testing.Bits.C,
            Testing.Bits.A,
            Testing.Bits.A | Testing.Bits.C,
        }) |expected| {
            const data_index = tree.iterate(0, Testing.Bits.B, &iter);
            try testing.expectEqual(expected, data_index.?);
            try testing.expectEqual(@intCast(TestMask.Bits, expected), iter.bitmask);
        }

        try testing.expectEqual(@as(?u32, null), tree.iterate(0, Testing.Bits.B, &iter));
    }

    {
        var iter = TestTree.IterCursor.fromRoot();
        inline for ([_]u32{
            Testing.Bits.B,
            Testing.Bits.A,
            Testing.Bits.A | Testing.Bits.B,
        }) |expected| {
            const data_index = tree.iterate(0, Testing.Bits.C, &iter);
            try testing.expectEqual(expected, data_index.?);
            try testing.expectEqual(@intCast(TestMask.Bits, expected), iter.bitmask);
        }

        try testing.expectEqual(@as(?u32, null), tree.iterate(0, Testing.Bits.C, &iter));
    }

    {
        var iter = TestTree.IterCursor.fromRoot();
        const data_index = tree.iterate(0, Testing.Bits.A | Testing.Bits.B, &iter);
        try testing.expectEqual(Testing.Bits.C, iter.bitmask);
        try testing.expectEqual(@as(u32, Testing.Bits.C), data_index.?);

        try testing.expectEqual(@as(?u32, null), tree.iterate(0, Testing.Bits.A | Testing.Bits.B, &iter));
    }

    {
        var iter = TestTree.IterCursor.fromRoot();
        const data_index = tree.iterate(0, Testing.Bits.A | Testing.Bits.C, &iter);
        try testing.expectEqual(Testing.Bits.B, iter.bitmask);
        try testing.expectEqual(@as(u32, Testing.Bits.B), data_index.?);

        try testing.expectEqual(@as(?u32, null), tree.iterate(0, Testing.Bits.A | Testing.Bits.C, &iter));
    }

    {
        var iter = TestTree.IterCursor.fromRoot();
        const data_index = tree.iterate(0, Testing.Bits.B | Testing.Bits.C, &iter);
        try testing.expectEqual(Testing.Bits.A, iter.bitmask);
        try testing.expectEqual(@as(u32, Testing.Bits.A), data_index.?);

        try testing.expectEqual(@as(?u32, null), tree.iterate(0, Testing.Bits.B | Testing.Bits.C, &iter));
    }

    {
        var iter = TestTree.IterCursor.fromRoot();
        try testing.expectEqual(@as(?u32, null), tree.iterate(0, Testing.Bits.All, &iter));
    }
}

test "iterate with include A exlude B iterate all expected" {
    const all_combination_count = std.math.pow(u32, 2, Testing.AllComponentsArr.len);
    var tree = try TestTree.init(testing.allocator, all_combination_count);
    defer tree.deinit();

    for (1..all_combination_count) |mock_data_index| {
        const bitmask = @intCast(TestMask.Bits, mock_data_index);
        tree.appendChain(@intCast(u32, mock_data_index), bitmask) catch unreachable;
    }

    {
        var iter = TestTree.IterCursor.fromRoot();
        inline for ([_]u32{
            Testing.Bits.A,
            Testing.Bits.A | Testing.Bits.C,
        }) |expected| {
            const data_index = tree.iterate(Testing.Bits.A, Testing.Bits.B, &iter);
            try testing.expectEqual(expected, data_index.?);
            try testing.expectEqual(@intCast(TestMask.Bits, expected), iter.bitmask);
        }

        try testing.expectEqual(@as(?u32, null), tree.iterate(Testing.Bits.A, Testing.Bits.B, &iter));
    }
}
