const std = @import("std");
const Allocator = std.mem.Allocator;
const EntityId = @import("entity_type.zig").EntityId;

pub const Sparse = struct {
    pub fn CompToSparseType(comptime Component: type) type {
        return if (@sizeOf(Component) > 0) Full else Tag;
    }

    pub const not_set = std.math.maxInt(EntityId);

    /// TagSparse set is the type used when there is a "0 sized" component
    pub const Tag = struct {
        pub const Byte = u8;

        pub const empty = Tag{
            .sparse_len = 0,
            .sparse_bits = &.{},
        };

        sparse_len: u32,
        // Len of the slice is "capacity"
        sparse_bits: []EntityId,

        pub fn deinit(self: *Tag, allocator: Allocator) void {
            allocator.free(self.sparse_bits);
            self.sparse_len = undefined;
            self.sparse_bits = undefined;
        }

        pub fn grow(self: *Tag, allocator: Allocator, min_size: u32) error{OutOfMemory}!void {
            const word_count = std.math.divCeil(u32, min_size, @bitSizeOf(EntityId)) catch unreachable;
            self.sparse_len = @max(self.sparse_len, word_count);
            if (self.sparse_bits.len >= word_count) {
                return;
            }

            const new_len = growSize(self.sparse_bits.len, word_count);
            const old_len = self.sparse_bits.len;

            // Grow sparse, realloc will resize if possible
            {
                self.sparse_bits = try allocator.realloc(self.sparse_bits, new_len);
                @memset(self.sparse_bits[old_len..new_len], not_set);
            }
        }

        pub fn setAssumeCapacity(self: *Tag, sparse_slot: EntityId) void {
            const slot_index = @divFloor(sparse_slot, @bitSizeOf(EntityId));
            const slot_bit: u5 = @intCast(@rem(sparse_slot, @bitSizeOf(EntityId)));
            self.sparse_bits[slot_index] &= ~(@as(EntityId, 1) << slot_bit);
        }

        pub fn unset(self: *Tag, sparse_slot: EntityId) void {
            if (self.sparse_bits.len * @bitSizeOf(EntityId) <= sparse_slot) {
                return;
            }

            const slot_index = @divFloor(sparse_slot, @bitSizeOf(EntityId));
            const slot_bit: u5 = @intCast(@rem(sparse_slot, @bitSizeOf(EntityId)));
            self.sparse_bits[slot_index] |= @as(EntityId, 1) << slot_bit;
        }

        pub fn isSet(self: Tag, sparse_slot: EntityId) bool {
            if (self.sparse_bits.len * @bitSizeOf(EntityId) <= sparse_slot) {
                return false;
            }

            const slot_index = @divFloor(sparse_slot, @bitSizeOf(EntityId));
            const slot_bit: u5 = @intCast(@rem(sparse_slot, @bitSizeOf(EntityId)));
            return (self.sparse_bits[slot_index] & (@as(EntityId, 1) << slot_bit)) == 0;
        }

        pub fn clearRetainingCapacity(self: *Tag) void {
            @memset(self.sparse_bits, not_set);
            self.sparse_len = 0;
        }
    };

    pub const Full = struct {
        const SparseSet = @This();

        pub const empty = Full{
            .sparse_len = 0,
            .sparse = &.{},
        };

        sparse_len: u32,
        // Len of the slice is "capacity"
        sparse: []EntityId,

        pub fn deinit(self: *SparseSet, allocator: Allocator) void {
            allocator.free(self.sparse);
            self.sparse = undefined;
            self.sparse_len = undefined;
        }

        pub fn grow(self: *SparseSet, allocator: Allocator, min_size: u32) error{OutOfMemory}!void {
            self.sparse_len = @max(self.sparse_len, min_size);
            if (self.sparse.len >= min_size) {
                return;
            }

            const new_len = growSize(self.sparse.len, min_size);
            const old_len = self.sparse.len;

            // Grow sparse, realloc will resize if possible
            {
                self.sparse = try allocator.realloc(self.sparse, new_len);
                @memset(self.sparse[old_len..new_len], not_set);
            }
        }

        pub inline fn setAssumeCapacity(self: *SparseSet, sparse_slot: EntityId, entry: EntityId) void {
            self.sparse[sparse_slot] = entry;
        }

        pub fn isSet(self: SparseSet, sparse_slot: EntityId) bool {
            if (self.sparse.len <= sparse_slot) {
                return false;
            }

            return self.sparse[sparse_slot] != not_set;
        }

        pub fn clearRetainingCapacity(self: *SparseSet) void {
            @memset(self.sparse[0..self.sparse_len], Sparse.not_set);
            self.sparse_len = 0;
        }
    };
};

pub fn Dense(comptime DenseT: type) type {
    return struct {
        pub const DenseType = DenseT;

        const Set = @This();

        pub const empty = Set{
            .dense_len = 0,
            .dense = &.{},
            .sparse_index = &.{},
        };

        dense_len: u32,
        // Len of slice is "capacity"
        dense: []DenseT,
        sparse_index: []u32,

        pub fn deinit(self: *Set, allocator: Allocator) void {
            if (@sizeOf(DenseT) > 0) {
                allocator.free(self.dense);
                allocator.free(self.sparse_index);
            }

            self.dense_len = undefined;
            self.dense = undefined;
            self.sparse_index = undefined;
        }

        pub fn grow(self: *Set, allocator: Allocator, min_size: usize) error{OutOfMemory}!void {
            if (@sizeOf(DenseType) == 0) {
                return;
            }

            if (self.dense.len >= min_size) {
                return;
            }

            const new_len = growSize(self.dense.len, min_size);
            self.dense = try allocator.realloc(self.dense, new_len);
            self.sparse_index = try allocator.realloc(self.sparse_index, new_len);
        }

        pub fn clearRetainingCapacity(self: *Set) void {
            self.dense_len = 0;
        }
    };
}

pub fn setAssumeCapacity(
    sparse: *Sparse.Full,
    dense: anytype,
    sparse_slot: EntityId,
    dense_item: anytype,
) void {
    std.debug.assert(sparse.sparse_len > sparse_slot);
    std.debug.assert(dense.dense_len < dense.dense.len);

    // Check if sparse already has an item
    {
        const entry = sparse.sparse[sparse_slot];
        if (entry != Sparse.not_set) {
            dense.dense[entry] = dense_item;
            dense.sparse_index[entry] = sparse_slot;
            return;
        }
    }

    // Add new item and register index
    {
        const entry = dense.dense_len;
        sparse.setAssumeCapacity(sparse_slot, entry);
        dense.dense_len += 1;

        dense.dense[entry] = dense_item;
        dense.sparse_index[entry] = sparse_slot;
    }
}

// True if sparse was set, false otherwise
pub fn unset(
    sparse: *Sparse.Full,
    dense: anytype,
    sparse_slot: EntityId,
) bool {
    if (sparse.sparse.len <= sparse_slot) {
        return false;
    }

    const entry = sparse.sparse[sparse_slot];
    if (entry == Sparse.not_set) {
        return false;
    }

    // swap remove
    const swapped_sparse_entry = dense.sparse_index[dense.dense_len - 1];
    sparse.sparse[swapped_sparse_entry] = entry;

    dense.dense[entry] = dense.dense[dense.dense_len - 1];
    dense.sparse_index[entry] = swapped_sparse_entry;

    sparse.sparse[sparse_slot] = Sparse.not_set;
    dense.dense_len -= 1;
    return true;
}

pub fn get(
    sparse: *const Sparse.Full,
    dense: anytype,
    sparse_slot: EntityId,
) ?*GetDenseStorage(@TypeOf(dense)).DenseType {
    if (sparse_slot >= sparse.sparse_len) {
        return null;
    }

    const entry = sparse.sparse[sparse_slot];
    if (entry == Sparse.not_set) {
        return null;
    }

    return &dense.dense[entry];
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

fn GetDenseStorage(comptime DensePtr: type) type {
    const dense_ptr_info = @typeInfo(DensePtr).pointer;
    return dense_ptr_info.child;
}

const TestDenseSet = Dense(u32);

test "SparseSet growSparse grows set" {
    var sparse_set: Sparse.Full = .empty;
    defer sparse_set.deinit(std.testing.allocator);

    var dense_set: TestDenseSet = .empty;
    defer dense_set.deinit(std.testing.allocator);

    try sparse_set.grow(std.testing.allocator, 16);
    try std.testing.expect(16 <= sparse_set.sparse.len);

    for (sparse_set.sparse) |sparse| {
        try std.testing.expectEqual(Sparse.not_set, sparse);
    }

    try sparse_set.grow(std.testing.allocator, 1024);
    try std.testing.expect(sparse_set.sparse.len >= 1024);

    for (sparse_set.sparse) |sparse| {
        try std.testing.expectEqual(Sparse.not_set, sparse);
    }
}

test "SparseSet set populates dense" {
    var sparse_set: Sparse.Full = .empty;
    defer sparse_set.deinit(std.testing.allocator);

    var dense_set: TestDenseSet = .empty;
    defer dense_set.deinit(std.testing.allocator);

    try sparse_set.grow(std.testing.allocator, 16);
    try dense_set.grow(std.testing.allocator, dense_set.dense_len + 4);

    setAssumeCapacity(&sparse_set, &dense_set, 3, @as(u32, 5));
    try std.testing.expectEqual(1, dense_set.dense_len);
    try std.testing.expectEqual(5, dense_set.dense[0]);

    var sparse = [_]EntityId{Sparse.not_set} ** 16;
    sparse[3] = 0;
    for (sparse, sparse_set.sparse[0..16]) |expected_entry, actual_entry| {
        try std.testing.expectEqual(expected_entry, actual_entry);
    }

    setAssumeCapacity(&sparse_set, &dense_set, 3, @as(u32, 8));
    try std.testing.expectEqual(1, dense_set.dense_len);
    try std.testing.expectEqual(8, dense_set.dense[0]);

    setAssumeCapacity(&sparse_set, &dense_set, 6, @as(u32, 3));
    try std.testing.expectEqual(2, dense_set.dense_len);
    try std.testing.expectEqual(3, dense_set.dense[1]);
    sparse[6] = 1;

    setAssumeCapacity(&sparse_set, &dense_set, 15, @as(u32, 15));
    try std.testing.expectEqual(3, dense_set.dense_len);
    try std.testing.expectEqual(15, dense_set.dense[2]);
    sparse[15] = 2;

    for (sparse, sparse_set.sparse[0..16]) |expected_entry, actual_entry| {
        try std.testing.expectEqual(expected_entry, actual_entry);
    }
}

test "SparseSet unset removes elements" {
    var sparse_set: Sparse.Full = .empty;
    defer sparse_set.deinit(std.testing.allocator);

    var dense_set: TestDenseSet = .empty;
    defer dense_set.deinit(std.testing.allocator);

    try sparse_set.grow(std.testing.allocator, 16);
    try dense_set.grow(std.testing.allocator, dense_set.dense_len + 4);

    setAssumeCapacity(&sparse_set, &dense_set, 3, @as(u32, 5));
    setAssumeCapacity(&sparse_set, &dense_set, 3, @as(u32, 8));
    setAssumeCapacity(&sparse_set, &dense_set, 6, @as(u32, 3));
    setAssumeCapacity(&sparse_set, &dense_set, 15, @as(u32, 15));

    try std.testing.expect(unset(&sparse_set, &dense_set, 6));
    try std.testing.expect(unset(&sparse_set, &dense_set, 6) == false);

    var sparse = [_]EntityId{Sparse.not_set} ** 16;
    sparse[3] = 0;
    sparse[15] = 1;
    for (sparse, sparse_set.sparse[0..16]) |expected_entry, actual_entry| {
        try std.testing.expectEqual(expected_entry, actual_entry);
    }

    const dense = [_]u32{ 8, 15 };
    for (dense, dense_set.dense[0..dense_set.dense_len]) |expected_dense, actual_dense| {
        try std.testing.expectEqual(expected_dense, actual_dense);
    }
}

test "SparseSet get retrieves element" {
    var sparse_set: Sparse.Full = .empty;
    defer sparse_set.deinit(std.testing.allocator);

    var dense_set: TestDenseSet = .empty;
    defer dense_set.deinit(std.testing.allocator);

    try sparse_set.grow(std.testing.allocator, 16);
    try dense_set.grow(std.testing.allocator, dense_set.dense_len + 3);

    const Entry = struct {
        sparse: EntityId,
        dense: u32,
    };
    const entries = [_]Entry{
        .{ .sparse = 3, .dense = 5 },
        .{ .sparse = 6, .dense = 3 },
        .{ .sparse = 15, .dense = 15 },
    };

    // assign entries and check what we stored
    for (entries) |entry| {
        setAssumeCapacity(&sparse_set, &dense_set, entry.sparse, entry.dense);
        try std.testing.expectEqual(entry.dense, get(&sparse_set, &dense_set, entry.sparse).?.*);
    }

    // check all stored entries
    for (entries) |entry| {
        try std.testing.expectEqual(entry.dense, get(&sparse_set, &dense_set, entry.sparse).?.*);
    }

    // check empty entries
    try std.testing.expectEqual(@as(?*u32, null), get(&sparse_set, &dense_set, 4));
    try std.testing.expectEqual(@as(?*u32, null), get(&sparse_set, &dense_set, 14));
}

test "SparseSet isSet identifies set and unset elements" {
    var sparse_set: Sparse.Full = .empty;
    defer sparse_set.deinit(std.testing.allocator);

    var dense_set: TestDenseSet = .empty;
    defer dense_set.deinit(std.testing.allocator);

    try sparse_set.grow(std.testing.allocator, 16);
    try dense_set.grow(std.testing.allocator, dense_set.dense_len + 3);

    const Entry = struct {
        sparse: EntityId,
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
        setAssumeCapacity(&sparse_set, &dense_set, entry.sparse, entry.dense);
        try std.testing.expect(sparse_set.isSet(entry.sparse));
    }
}

test "SparseSet clearRetainingCapacity clears" {
    var sparse_set: Sparse.Full = .empty;
    defer sparse_set.deinit(std.testing.allocator);

    var dense_set: TestDenseSet = .empty;
    defer dense_set.deinit(std.testing.allocator);

    try sparse_set.grow(std.testing.allocator, 16);
    try dense_set.grow(std.testing.allocator, dense_set.dense_len + 3);

    setAssumeCapacity(&sparse_set, &dense_set, 3, 5);
    setAssumeCapacity(&sparse_set, &dense_set, 6, 3);
    setAssumeCapacity(&sparse_set, &dense_set, 15, 15);

    sparse_set.clearRetainingCapacity();
    dense_set.clearRetainingCapacity();

    const sparse = [_]EntityId{Sparse.not_set} ** 16;
    for (sparse, sparse_set.sparse[0..16]) |expected_entry, actual_entry| {
        try std.testing.expectEqual(expected_entry, actual_entry);
    }

    try std.testing.expectEqual(0, dense_set.dense_len);
}
