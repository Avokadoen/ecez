const std = @import("std");
const Allocator = std.mem.Allocator;
const NodeList = std.ArrayList(Node);

pub const Node = struct {
    node_data_index: ?u32,
    left_index: ?u32,
    right_index: ?u32,

    pub fn empty() Node {
        return Node{
            .node_data_index = null,
            .left_index = null,
            .right_index = null,
        };
    }
};
pub fn FromConfig(comptime max_depth: u32, comptime BitMask: type) type {
    const bit_count = @typeInfo(BitMask.Bits).Int.bits;

    return struct {
        const BinaryTree = @This();

        node_list: NodeList,

        pub fn init(allocator: Allocator) BinaryTree {
            return BinaryTree{
                .node_list = NodeList.init(allocator),
            };
        }

        pub fn deinit(self: BinaryTree) void {
            self.node_list.deinit();
        }

        // TODO: state machine to track if we have hit a missing tree branch which means we should just keep instantiating nodes
        /// append a new node at destination by creating the intermediate nodes as well
        pub fn appendChain(self: *BinaryTree, node_data_index: u32, destination: BitMask.Bits) error{OutOfMemory}!void {
            std.debug.assert(destination > 0);

            var current_node: *Node = &self.node_list.items[0];

            const step_fn = struct {
                pub inline fn step(tree: *BinaryTree, child_index: *?u32) error{OutOfMemory}!*Node {
                    if (child_index.*) |index| {
                        return &tree.node_list.items[index];
                    } else {
                        const index = tree.node_list.items.len;
                        try tree.node_list.append(Node.empty());
                        child_index.* = @intCast(u32, index);
                        return &tree.node_list.items[index];
                    }
                }
            }.step;

            var mask = destination;
            const step_count = bit_count - @clz(destination);
            for (0..step_count) |_| {
                if (mask & 1 == 1) {
                    current_node = try step_fn(self, &current_node.right_index);
                } else {
                    current_node = try step_fn(self, &current_node.left_index);
                }
            }

            current_node.node_data_index = node_data_index;
        }

        pub const IterStack = struct {
            len: usize,
            buffer: [max_depth]u32,

            pub fn push(self: *IterStack, node_index: u32) void {
                std.debug.assert(self.len < max_depth);
                self.buffer[self.len] = node_index;
                self.len += 1;
            }

            pub fn pop(self: *IterStack) u32 {
                std.debug.assert(self.len > 0);
                self.len -= 1;
                return self.buffer[self.len];
            }

            pub fn is_empty(self: IterStack) bool {
                return self.len == 0;
            }
        };
        pub const IterCursor = struct {
            depth: BitMask.Shift,
            bitmask: BitMask.Bits,
            stack: IterStack,
        };
        /// Iterate the tree, iter_stack *must* have atleast one element.
        pub fn iterate(self: BinaryTree, include_bits: BitMask.Bits, exclude_bits: BitMask.Bits, iter_cursor: *IterCursor) ?Node {
            _ = exclude_bits;
            _ = include_bits;

            var current_node_index: ?u32 = iter_cursor.stack.pop();
            while (true) {
                if (current_node_index) |index| {
                    const current_node = self.node_list.items[index];

                    current_node_index = current_node.left_index;
                    iter_cursor.depth += 1;

                    iter_cursor.stack.push(index);
                } else if (iter_cursor.stack.is_empty() == false) {
                    const return_index = iter_cursor.stack.pop();

                    const return_node = self.node_list.items[return_index];
                    if (return_node.right_index) |right_index| {
                        iter_cursor.bitmask |= (@as(BitMask.Bits, 1) << iter_cursor.depth);
                        iter_cursor.depth += 1;
                        iter_cursor.stack.push(right_index);
                    }

                    return self.node_list.items[return_index];
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
const TestTree = FromConfig(Testing.AllComponentsArr.len, TestMask);

test "iterate with empty include and exclude mask iterate all" {
    var tree = TestTree.init(testing.allocator);

    for (1..2 ^ Testing.AllComponentsArr.len) |mock_data_index| {
        const bitmask = @intCast(TestMask.Bits, mock_data_index);
        try tree.appendChain(@intCast(u32, mock_data_index), bitmask);
    }

    var iter = TestTree.IterCursor{
        .depth = 0,
        .bitmask = 0,
        .stack = .{
            .len = 1,
            .buffer = [_]u32{0} ** Testing.AllComponentsArr.len,
        },
    };
    for (1..2 ^ Testing.AllComponentsArr.len) |mock_data_index| {
        const node = tree.iterate(0, 0, &iter);
        try testing.expectEqual(@intCast(u32, mock_data_index), node.?.node_data_index.?);
    }
}
