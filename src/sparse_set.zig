const std = @import("std");
const Allocator = std.mem.Allocator;

// TODO: sparse set is not thread safe
pub fn SparseSet(comptime SparseT: type, comptime DenseT: type) type {
    return struct {
        pub const sparse_not_set = std.math.maxInt(SparseT);

        const Set = @This();

        // TODO: make 1 bit per entity (tradeof with o(1))
        sparse_len: usize = 0,
        // Len of the slice is "capacity"
        sparse: []SparseT = &[0]SparseT{},

        // TODO: even though the same pattern exist in std arraylist, I am not comfortable with stack addr to realloc
        dense_len: usize = 0,
        // Len of slice is "capacity"
        dense: []DenseT = &[0]DenseT{},

        pub fn deinit(self: *Set, allocator: Allocator) void {
            if (@sizeOf(DenseT) > 0) {
                allocator.free(self.dense);
            }

            allocator.free(self.sparse);

            self.dense = undefined;
            self.sparse = undefined;
            self.dense_len = undefined;
        }

        pub fn growSparse(self: *Set, allocator: Allocator, min_size: usize) error{OutOfMemory}!void {
            self.sparse_len = @max(self.sparse_len, min_size);

            if (self.sparse.len >= min_size) {
                return;
            }

            const new_len = growSize(self.sparse.len, min_size);
            const old_len = self.sparse.len;

            // Grow sparse, realloc will resize if possible internaly
            {
                self.sparse = try allocator.realloc(self.sparse, new_len);
                @memset(self.sparse[old_len..new_len], sparse_not_set);
            }
        }

        pub fn growDense(self: *Set, allocator: Allocator, min_size: usize) error{OutOfMemory}!void {
            if (self.dense.len >= min_size) {
                return;
            }

            const new_len = growSize(self.dense.len, min_size);
            self.dense = try allocator.realloc(self.dense, new_len);
        }

        pub fn set(self: *Set, allocator: Allocator, sparse: SparseT, item: DenseT) error{OutOfMemory}!void {
            std.debug.assert(self.sparse.len > sparse);

            // Check if we have sparse already has a item
            {
                const entry = self.sparse[sparse];
                if (entry != sparse_not_set) {
                    if (@sizeOf(DenseT) > 0) {
                        self.dense[entry] = item;
                    }
                    return;
                }
            }

            {
                // Check if dense has sufficient capcacity
                if (@sizeOf(DenseT) > 0) {
                    if (self.dense.len <= self.dense_len) {
                        // Grow dense, realloc will resize if possible internaly
                        const new_len = growSize(self.dense.len, self.dense.len + 1);
                        self.dense = try allocator.realloc(self.dense, new_len);
                    }
                }

                // Add new item and register index
                const entry = self.dense_len;
                self.sparse[sparse] = @intCast(entry);

                self.dense_len += 1;

                if (@sizeOf(DenseT) > 0) {
                    self.dense[entry] = item;
                }
            }
        }

        pub inline fn isSet(self: Set, sparse: SparseT) bool {
            if (self.sparse.len <= sparse) {
                return false;
            }

            return self.sparse[sparse] != sparse_not_set;
        }

        // True if sparse was set, false otherwise
        pub fn unset(self: *Set, sparse: SparseT) bool {
            if (self.sparse.len <= sparse) {
                return false;
            }

            const entry = self.sparse[sparse];
            if (entry == sparse_not_set) {
                return false;
            }

            self.sparse[sparse] = sparse_not_set;
            if (@sizeOf(DenseT) > 0) {
                for (self.sparse[sparse..]) |*sparse_entry| {
                    if (sparse_entry.* == sparse_not_set) continue;

                    sparse_entry.* -= 1;
                }

                const shift_dense = self.dense[entry..];
                if (shift_dense.len > 0) {
                    std.mem.rotate(DenseT, shift_dense, 1);
                }
            }

            self.dense_len -= 1;
            return true;
        }

        pub fn get(self: Set, sparse: SparseT) ?*DenseT {
            if (sparse >= self.sparse_len) {
                return null;
            }

            const entry = self.sparse[sparse];
            if (entry == sparse_not_set) {
                return null;
            }

            if (@sizeOf(DenseT) > 0) {
                return &self.dense[entry];
            } else {
                var zero_size = DenseT{};
                return &zero_size;
            }
        }

        pub fn clearRetainingCapacity(self: *Set) void {
            @memset(self.sparse, sparse_not_set);
            self.sparse_len = 0;
            self.dense_len = 0;
        }

        // "Borrowed" from std.ArrayList :)
        inline fn growSize(current_len: usize, min_size: usize) usize {
            var new = current_len;
            while (true) {
                new +|= new / 2 + 8;
                if (new >= min_size)
                    return new;
            }
        }
    };
}

const TestSparseSet = SparseSet(u32, u32);

test "SparseSet growSparse grows set" {
    var sparse_set = TestSparseSet{};
    defer sparse_set.deinit(std.testing.allocator);

    try sparse_set.growSparse(std.testing.allocator, 16);
    try std.testing.expect(16 <= sparse_set.sparse.len);

    for (sparse_set.sparse) |sparse| {
        try std.testing.expectEqual(TestSparseSet.sparse_not_set, sparse);
    }

    try sparse_set.growSparse(std.testing.allocator, 1024);
    try std.testing.expect(1024 <= sparse_set.sparse.len);

    for (sparse_set.sparse) |sparse| {
        try std.testing.expectEqual(TestSparseSet.sparse_not_set, sparse);
    }
}

test "SparseSet set populates dense" {
    var sparse_set = TestSparseSet{};
    defer sparse_set.deinit(std.testing.allocator);

    try sparse_set.growSparse(std.testing.allocator, 16);

    try sparse_set.set(std.testing.allocator, 3, 5);
    try std.testing.expectEqual(1, sparse_set.dense_len);
    try std.testing.expectEqual(5, sparse_set.dense[0]);

    var sparse = [_]u32{TestSparseSet.sparse_not_set} ** 16;
    sparse[3] = 0;
    for (sparse, sparse_set.sparse[0..16]) |expected_entry, actual_entry| {
        try std.testing.expectEqual(expected_entry, actual_entry);
    }

    try sparse_set.set(std.testing.allocator, 3, 8);
    try std.testing.expectEqual(1, sparse_set.dense_len);
    try std.testing.expectEqual(8, sparse_set.dense[0]);

    try sparse_set.set(std.testing.allocator, 6, 3);
    try std.testing.expectEqual(2, sparse_set.dense_len);
    try std.testing.expectEqual(3, sparse_set.dense[1]);
    sparse[6] = 1;

    try sparse_set.set(std.testing.allocator, 15, 15);
    try std.testing.expectEqual(3, sparse_set.dense_len);
    try std.testing.expectEqual(15, sparse_set.dense[2]);
    sparse[15] = 2;

    for (sparse, sparse_set.sparse[0..16]) |expected_entry, actual_entry| {
        try std.testing.expectEqual(expected_entry, actual_entry);
    }
}

test "SparseSet unset removes elements" {
    var sparse_set = TestSparseSet{};
    defer sparse_set.deinit(std.testing.allocator);

    try sparse_set.growSparse(std.testing.allocator, 16);

    try sparse_set.set(std.testing.allocator, 3, 5);
    try sparse_set.set(std.testing.allocator, 3, 8);
    try sparse_set.set(std.testing.allocator, 6, 3);
    try sparse_set.set(std.testing.allocator, 15, 15);

    try std.testing.expect(sparse_set.unset(6));
    try std.testing.expect(sparse_set.unset(6) == false);

    var sparse = [_]u32{TestSparseSet.sparse_not_set} ** 16;
    sparse[3] = 0;
    sparse[15] = 1;
    for (sparse, sparse_set.sparse[0..16]) |expected_entry, actual_entry| {
        try std.testing.expectEqual(expected_entry, actual_entry);
    }

    const dense = [_]u32{ 8, 15 };
    for (dense, sparse_set.dense[0..sparse_set.dense_len]) |expected_dense, actual_dense| {
        try std.testing.expectEqual(expected_dense, actual_dense);
    }
}

test "SparseSet get retrieves element" {
    var sparse_set = TestSparseSet{};
    defer sparse_set.deinit(std.testing.allocator);

    try sparse_set.growSparse(std.testing.allocator, 16);

    const Entry = struct {
        sparse: u32,
        dense: u32,
    };
    const entries = [_]Entry{
        .{ .sparse = 3, .dense = 5 },
        .{ .sparse = 6, .dense = 3 },
        .{ .sparse = 15, .dense = 15 },
    };

    // assign entries and check what we stored
    for (entries) |entry| {
        try sparse_set.set(std.testing.allocator, entry.sparse, entry.dense);
        try std.testing.expectEqual(entry.dense, sparse_set.get(entry.sparse).?.*);
    }

    // check all stored entries
    for (entries) |entry| {
        try std.testing.expectEqual(entry.dense, sparse_set.get(entry.sparse).?.*);
    }

    // check empty entries
    try std.testing.expectEqual(@as(?*u32, null), sparse_set.get(4));
    try std.testing.expectEqual(@as(?*u32, null), sparse_set.get(14));
}

test "SparseSet isSet identifies set and unset elements" {
    var sparse_set = TestSparseSet{};
    defer sparse_set.deinit(std.testing.allocator);

    try sparse_set.growSparse(std.testing.allocator, 16);

    const Entry = struct {
        sparse: u32,
        dense: u32,
    };
    const entries = [_]Entry{
        .{ .sparse = 3, .dense = 5 },
        .{ .sparse = 6, .dense = 3 },
        .{ .sparse = 15, .dense = 15 },
    };

    // assign entries and check what we stored
    for (entries) |entry| {
        try std.testing.expectEqual(false, sparse_set.isSet(entry.sparse));
        try sparse_set.set(std.testing.allocator, entry.sparse, entry.dense);
        try std.testing.expect(sparse_set.isSet(entry.sparse));
    }
}

test "SparseSet clearRetainingCapacity clears" {
    var sparse_set = TestSparseSet{};
    defer sparse_set.deinit(std.testing.allocator);

    try sparse_set.growSparse(std.testing.allocator, 16);

    try sparse_set.set(std.testing.allocator, 3, 5);
    try sparse_set.set(std.testing.allocator, 6, 3);
    try sparse_set.set(std.testing.allocator, 15, 15);

    sparse_set.clearRetainingCapacity();

    const sparse = [_]u32{TestSparseSet.sparse_not_set} ** 16;
    for (sparse, sparse_set.sparse[0..16]) |expected_entry, actual_entry| {
        try std.testing.expectEqual(expected_entry, actual_entry);
    }

    try std.testing.expectEqual(0, sparse_set.dense_len);
}

test "SparseSet with zero sized type only has sparse" {
    var sparse_set = SparseSet(u32, struct {}){};
    defer sparse_set.deinit(std.testing.allocator);

    try sparse_set.growSparse(std.testing.allocator, 16);

    try sparse_set.set(std.testing.allocator, 3, .{});
    try sparse_set.set(std.testing.allocator, 3, .{});
    try sparse_set.set(std.testing.allocator, 6, .{});
    _ = sparse_set.unset(6);
    try sparse_set.set(std.testing.allocator, 15, .{});

    sparse_set.clearRetainingCapacity();

    const sparse = [_]u32{TestSparseSet.sparse_not_set} ** 16;
    for (sparse, sparse_set.sparse[0..16]) |expected_entry, actual_entry| {
        try std.testing.expectEqual(expected_entry, actual_entry);
    }

    try std.testing.expectEqual(0, sparse_set.dense_len);
}
