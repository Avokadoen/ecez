const std = @import("std");
const Allocator = std.mem.Allocator;
const NodeList = std.ArrayList(Node);

pub const Node = struct {
    pub const left = 0;
    pub const right = 1;

    data_index: ?u32,
    child: [2]?u32,

    pub fn empty() Node {
        return Node{
            .data_index = null,
            .child = [_]?u32{null} ** 2,
        };
    }
};
pub fn FromConfig(comptime max_depth: u32, comptime BitMask: type) type {
    const bit_count = @typeInfo(BitMask.Bits).Int.bits;

    return struct {
        const BinaryTree = @This();

        node_list: NodeList,

        pub fn init(
            allocator: Allocator,
            initial_capacity: usize,
        ) error{OutOfMemory}!BinaryTree {
            var list = try NodeList.initCapacity(allocator, initial_capacity);
            list.appendAssumeCapacity(Node.empty());

            return BinaryTree{
                .node_list = list,
            };
        }

        pub fn deinit(self: BinaryTree) void {
            self.node_list.deinit();
        }

        // TODO: state machine to track if we have hit a missing tree branch which means we should just keep instantiating nodes
        /// append a new node at destination by creating the intermediate nodes as well
        pub fn appendChain(self: *BinaryTree, data_index: u32, destination: BitMask.Bits) error{OutOfMemory}!void {
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
                    try self.node_list.append(Node.empty());
                    self.node_list.items[current_index].child[child_index] = @intCast(u32, index);
                    break :step_blk index;
                };
            }

            self.node_list.items[current_index].data_index = data_index;
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
        pub fn iterate(self: BinaryTree, include_bits: BitMask.Bits, exclude_bits: BitMask.Bits, iter_cursor: *IterCursor) ?u32 {
            _ = exclude_bits;
            _ = include_bits;
            std.debug.print("\n\n", .{});
            for (self.node_list.items, 0..) |item, index| {
                std.debug.print("[{d}]: {any}\n", .{ index, item });
            }

            std.debug.print("{any}\n", .{iter_cursor.*});

            var current_node_index: ?u32 = iter_cursor.stack.pop();
            std.debug.print("[{any}]starting at, depth {d}\n", .{ current_node_index, iter_cursor.depth - 1 });
            iter_cursor.depth -= 1;

            while (true) {
                if (current_node_index) |index| {
                    const current_node = self.node_list.items[index];

                    current_node_index = current_node.child[Node.left];
                    std.debug.print("[{any}]left\n", .{current_node_index});

                    iter_cursor.stack.push(index);
                    iter_cursor.depth += if (index > 0) 1 else 0;
                } else if (iter_cursor.stack.is_empty() == false) {
                    const current_index = iter_cursor.stack.pop();
                    iter_cursor.bitmask &= ~(@as(BitMask.Bits, 1) << (iter_cursor.depth - 1));
                    iter_cursor.depth -= 1;

                    const right_child_index = self.node_list.items[current_index].child[Node.right];
                    if (right_child_index) |right_index| {
                        if (self.node_list.items[right_index].data_index) |data_index| {
                            std.debug.print("[{}] right\n {any}", .{ right_index, self.node_list.items[right_index] });
                            iter_cursor.bitmask |= (@as(BitMask.Bits, 1) << iter_cursor.depth);
                            iter_cursor.stack.push(right_index);
                            iter_cursor.depth += 1;
                            return data_index;
                        }
                    }

                    current_node_index = right_child_index;
                    iter_cursor.depth += if (current_index > 0) 1 else 0;
                    std.debug.print("[{any}]right\n", .{current_node_index});
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

    const expected_data_indices = [_]u32{
        Testing.Bits.C,
        Testing.Bits.B,
        Testing.Bits.B | Testing.Bits.C,
        Testing.Bits.A,
        Testing.Bits.A | Testing.Bits.C,
        Testing.Bits.A | Testing.Bits.B,
        Testing.Bits.All,
    };
    var iter = TestTree.IterCursor{
        .depth = 1,
        .bitmask = 0,
        .stack = .{
            .len = 1,
            .buffer = [_]u32{0} ** (Testing.AllComponentsArr.len + 1),
        },
    };
    inline for (expected_data_indices) |expected| {
        const data_index = tree.iterate(0, 0, &iter);
        try testing.expectEqual(expected, data_index.?);
    }

    try testing.expectEqual(@as(?u32, null), tree.iterate(0, 0, &iter));
}

// test "iterate with include and empty exclude mask iterate all" {
//     var tree = TestTree.init(testing.allocator);

//     for (1..2 ^ Testing.AllComponentsArr.len) |mock_data_index| {
//         const bitmask = @intCast(TestMask.Bits, mock_data_index);
//         try tree.appendChain(@intCast(u32, mock_data_index), bitmask);
//     }

//     var iter = TestTree.IterCursor{
//         .depth = 0,
//         .bitmask = 0,
//         .stack = .{
//             .len = 1,
//             .buffer = [_]u32{0} ** Testing.AllComponentsArr.len,
//         },
//     };
//     for (1..2 ^ Testing.AllComponentsArr.len) |mock_data_index| {
//         const node = tree.iterate(0, 0, &iter);
//         try testing.expectEqual(@intCast(u32, mock_data_index), node.?.data_index.?);
//     }
// }
