const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const hashfn: fn (str: []const u8) u64 = std.hash.Fnv1a_64.hash;

pub fn sortTypes(comptime Ts: []const type) [Ts.len]type {
    const TypeSortElem = struct {
        original_index: usize,
        hash: u64,
    };
    const lessThan = struct {
        fn func(context: void, lhs: TypeSortElem, rhs: TypeSortElem) bool {
            _ = context;
            return lhs.hash < rhs.hash;
        }
    }.func;
    var sort_target: [Ts.len]TypeSortElem = undefined;
    inline for (Ts) |T, i| {
        sort_target[i] = TypeSortElem{
            .original_index = i,
            .hash = hashType(T),
        };
    }
    comptime std.sort.sort(TypeSortElem, sort_target[0..], {}, lessThan);
    var types: [Ts.len]type = undefined;
    for (sort_target) |s, i| {
        types[i] = Ts[s.original_index];
    }
    return types;
}

pub fn typeQuery(comptime Ts: []const type) [Ts.len]u64 {
    const Types = comptime sortTypes(Ts);
    var type_hashes: [Types.len]u64 = undefined;
    inline for (Types) |T, index| {
        type_hashes[index] = hashType(T);
    }
    return type_hashes;
}

pub fn hashType(comptime T: type) u64 {
    const type_name = @typeName(T);
    return hashfn(type_name[0..]);
}

pub const Runtime = struct {
    const SortElem = struct {
        type_size: usize,
        type_hash: u64,

        fn lessThan(context: void, lhs: SortElem, rhs: SortElem) bool {
            _ = context;
            return lhs.type_hash < rhs.type_hash;
        }
    };

    allocator: Allocator,
    len: usize,
    type_sizes: []const usize,
    type_hashes: []const u64,
    own_memory: bool,

    // TODO: this should not allocate >:(
    pub fn fromSlicesAndType(allocator: Allocator, type_sizes: []const usize, type_hashes: []const u64, comptime AppendedType: type) !Runtime {
        std.debug.assert(type_sizes.len == type_hashes.len);

        const void_and_appended_type_len = 2;
        const len = type_hashes.len + void_and_appended_type_len;
        var sort_elements = try allocator.alloc(SortElem, len - 1);
        defer allocator.free(sort_elements);

        for (type_sizes) |size, i| {
            sort_elements[i] = .{
                .type_size = size,
                .type_hash = type_hashes[i],
            };
        }
        // insert the new type
        sort_elements[sort_elements.len - 1] = .{
            .type_size = @sizeOf(AppendedType),
            .type_hash = hashType(AppendedType),
        };
        std.sort.sort(SortElem, sort_elements, {}, SortElem.lessThan);

        var sorted_type_sizes = try allocator.alloc(usize, len);
        errdefer allocator.free(sorted_type_sizes);
        var sorted_type_hashes = try allocator.alloc(u64, len);
        errdefer allocator.free(sorted_type_hashes);

        // insert void type
        sorted_type_sizes[0] = 0;
        sorted_type_hashes[0] = 0;
        // insert the rest of the types
        for (sort_elements) |elem, i| {
            sorted_type_sizes[i + 1] = elem.type_size;
            sorted_type_hashes[i + 1] = elem.type_hash;
        }

        return Runtime{
            .allocator = allocator,
            .len = len,
            .type_sizes = sorted_type_sizes,
            .type_hashes = sorted_type_hashes,
            .own_memory = true,
        };
    }

    // create a Runtime query by from existing slice
    pub fn fromSlices(allocator: Allocator, type_sizes: []const usize, type_hashes: []const u64) !Runtime {
        std.debug.assert(type_sizes.len == type_hashes.len);

        const void_type_len = 1;
        const len = type_hashes.len + void_type_len;
        var sort_elements = try allocator.alloc(SortElem, len - 1);
        defer allocator.free(sort_elements);

        for (type_sizes) |size, i| {
            sort_elements[i] = .{
                .type_size = size,
                .type_hash = type_hashes[i],
            };
        }
        std.sort.sort(SortElem, sort_elements, {}, SortElem.lessThan);

        var sorted_type_sizes = try allocator.alloc(usize, len);
        errdefer allocator.free(sorted_type_sizes);
        var sorted_type_hashes = try allocator.alloc(u64, len);
        errdefer allocator.free(sorted_type_hashes);

        // insert void type
        sorted_type_sizes[0] = 0;
        sorted_type_hashes[0] = 0;
        // insert the rest of the types
        for (sort_elements) |elem, i| {
            sorted_type_sizes[i + 1] = elem.type_size;
            sorted_type_hashes[i + 1] = elem.type_hash;
        }

        return Runtime{
            .allocator = allocator,
            .len = len,
            .type_sizes = sorted_type_sizes,
            .type_hashes = sorted_type_hashes,
            .own_memory = true,
        };
    }

    // create a Runtime query by from existing slice
    pub fn fromSliceSlices(
        allocator: Allocator,
        type_sizes: []const []const usize,
        type_hashes: []const []const u64,
    ) !Runtime {
        std.debug.assert(type_sizes.len == type_hashes.len);

        var type_size_len: usize = 0;
        var type_hash_len: usize = 0;
        {
            var i: usize = 0;
            while (i < type_sizes.len) : (i += 1) {
                type_size_len += type_sizes[i].len;
                type_hash_len += type_hashes[i].len;
            }
        }
        std.debug.assert(type_size_len == type_hash_len);

        const void_type_len = 1;
        const len = type_hash_len + void_type_len;
        var sort_elements = try allocator.alloc(SortElem, len - 1);
        defer allocator.free(sort_elements);

        var pos: usize = 0;
        for (type_sizes) |sizes, i| {
            for (sizes) |size, j| {
                sort_elements[pos] = .{
                    .type_size = size,
                    .type_hash = type_hashes[i][j],
                };
                pos += 1;
            }
        }
        std.sort.sort(SortElem, sort_elements, {}, SortElem.lessThan);

        var sorted_type_sizes = try allocator.alloc(usize, len);
        errdefer allocator.free(sorted_type_sizes);
        var sorted_type_hashes = try allocator.alloc(u64, len);
        errdefer allocator.free(sorted_type_hashes);

        // insert void type
        sorted_type_sizes[0] = 0;
        sorted_type_hashes[0] = 0;
        // insert the rest of the types
        for (sort_elements) |elem, i| {
            sorted_type_sizes[i + 1] = elem.type_size;
            sorted_type_hashes[i + 1] = elem.type_hash;
        }

        return Runtime{
            .allocator = allocator,
            .len = len,
            .type_sizes = sorted_type_sizes,
            .type_hashes = sorted_type_hashes,
            .own_memory = true,
        };
    }

    /// Init query by taking ownership of existing sorted slices
    pub fn fromOwnedSlices(allocator: Allocator, type_sizes: []const usize, type_hashes: []const u64) Runtime {
        std.debug.assert(type_sizes.len == type_hashes.len);
        return Runtime{
            .allocator = allocator,
            .len = type_sizes.len,
            .type_sizes = type_sizes,
            .type_hashes = type_hashes,
            .own_memory = true,
        };
    }

    /// signal the query that it does no longer manage it's own memory
    pub fn takeOwnership(self: *Runtime) void {
        self.own_memory = false;
    }

    pub fn deinit(self: Runtime) void {
        if (self.own_memory == false) return;

        self.allocator.free(self.type_hashes);
        self.allocator.free(self.type_sizes);
    }
};

test "Runtime fromSliceSlices() joins slices" {
    const sizes = [_][]const usize{ &.{1}, &.{2}, &.{3}, &.{4} };
    const hashes = [_][]const u64{ &.{4}, &.{3}, &.{1}, &.{2} };

    const r = try Runtime.fromSliceSlices(testing.allocator, sizes[0..], hashes[0..]);
    defer r.deinit();

    // ignore void type
    try testing.expectEqual(r.len - 1, sizes.len);

    const expected_index_order = [_]usize{ 2, 3, 1, 0 };
    const expected_sizes = [_]usize{ 1, 2, 3, 4 };
    const expected_hashes = [_]u64{ 4, 3, 1, 2 };
    for (expected_index_order) |order, i| {
        try testing.expectEqual(expected_sizes[order], r.type_sizes[i + 1]);
        try testing.expectEqual(expected_hashes[order], r.type_hashes[i + 1]);
    }
}

test "Runtime fromSlicesAndType() sort hashes and sizes" {
    const sizes = [_]usize{ 1, 2, 3, 4 };
    const hashes = [_]u64{ 4, 3, 1, 2 };
    const r = try Runtime.fromSlicesAndType(testing.allocator, sizes[0..], hashes[0..], u64);
    defer r.deinit();

    // ignore void type
    try testing.expectEqual(r.len - 1, sizes.len + 1);
    const expected_index_order = [_]usize{ 2, 3, 1, 0, 4 };
    const expected_sizes = sizes ++ [_]usize{@sizeOf(u64)};
    const expected_hashes = hashes ++ [_]u64{hashType(u64)};
    for (expected_index_order) |order, i| {
        try testing.expectEqual(expected_sizes[order], r.type_sizes[i + 1]);
        try testing.expectEqual(expected_hashes[order], r.type_hashes[i + 1]);
    }
}

test "Runtime fromSlices() sort hashes and sizes" {
    const sizes = [_]usize{ 1, 2, 3, 4 };
    const hashes = [_]u64{ 4, 3, 1, 2 };
    const r = try Runtime.fromSlices(testing.allocator, sizes[0..], hashes[0..]);
    defer r.deinit();

    // ignore void type
    try testing.expect(r.len - 1 == sizes.len);
    const expected_index_order = [_]usize{ 2, 3, 1, 0 };
    for (expected_index_order) |order, i| {
        try testing.expectEqual(sizes[order], r.type_sizes[i + 1]);
        try testing.expectEqual(hashes[order], r.type_hashes[i + 1]);
    }
}

test "Runtime takeOwnership() revokes Runtime deinit functionality" {
    const sizes = [_]usize{ 1, 2, 3, 4 };
    const hashes = [_]u64{ 4, 3, 1, 2 };
    var r = try Runtime.fromSlices(testing.allocator, sizes[0..], hashes[0..]);

    // r does no longer own internal slices
    r.takeOwnership();

    r.deinit();
    r.deinit();
    r.deinit();

    testing.allocator.free(r.type_sizes);
    testing.allocator.free(r.type_hashes);
    try testing.expectEqual(false, r.own_memory);
}

test "sortTypes() sorts" {
    const A = struct {};
    const B = struct {};
    const C = struct {};
    const types1 = [_]type{ A, B, C };
    const types2 = [_]type{ C, A, B };

    const sorted_types1 = comptime sortTypes(&types1);
    const sorted_types2 = comptime sortTypes(&types2);

    inline for (sorted_types1) |T, i| {
        try testing.expectEqual(@typeName(T), @typeName(sorted_types2[i]));
    }
}

test "typeQuery() is order independent" {
    const A = struct {};
    const B = struct {};
    const C = struct {};
    const types1 = [_]type{ A, B, C };
    const types2 = [_]type{ C, A, B };

    const q_types1 = typeQuery(&types1);
    const q_types2 = typeQuery(&types2);

    for (q_types1) |q, i| {
        try testing.expectEqual(q, q_types2[i]);
    }
}
