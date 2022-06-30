const std = @import("std");
const testing = std.testing;

const hashfn: fn (str: []const u8) u64 = std.hash.Fnv1a_64.hash;
const max_types = @import("Archetype.zig").max_types;

pub fn sortTypes(comptime Ts: []const type) [Ts.len]type {
    const lessThan = struct {
        fn func(context: void, comptime lhs: type, comptime rhs: type) bool {
            _ = context;
            return hashType(lhs) < hashType(rhs);
        }
    }.func;
    var types: [Ts.len]type = undefined;
    std.mem.copy(type, types[0..], Ts);
    std.sort.sort(type, types[0..], {}, lessThan);
    return types;
}

pub fn typeQuery(comptime Ts: []const type) [Ts.len]u64 {
    const Types = sortTypes(Ts);
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
    type_count: usize,
    type_sizes: [max_types]usize,
    type_hashes: [max_types]u64,

    pub fn init(type_sizes: []const usize, type_hashes: []const u64) Runtime {
        std.debug.assert(type_sizes.len == type_hashes.len);

        const SortElem = struct {
            type_size: usize,
            type_hash: u64,
        };
        const lessThan = struct {
            fn func(context: void, comptime lhs: SortElem, comptime rhs: SortElem) bool {
                _ = context;
                return hashType(lhs.type_hash) < hashType(rhs.type_hash);
            }
        }.func;

        var sort_elements: [max_types]SortElem = undefined;
        for (type_sizes) |size, i| {
            sort_elements[i] = .{
                .type_size = size,
                .type_hash = type_hashes[i],
            };
        }
        std.sort.sort(SortElem, sort_elements[0..type_sizes.len], .{}, lessThan);

        var sorted_type_sizes: [max_types]usize = undefined;
        var sorted_type_hashes: [max_types]u64 = undefined;
        for (sort_elements[0..type_sizes.len]) |elem, i| {
            sorted_type_sizes[i] = elem.type_size;
            sorted_type_hashes[i] = elem.type_hash;
        }

        return Runtime{
            .type_count = type_sizes.len,
            .type_sizes = sorted_type_sizes,
            .type_hashes = sorted_type_hashes,
        };
    }
};

test "Runtime init() sort hashes and sizes" {
    const sizes = [_]usize{ 1, 2, 3, 4 };
    const hashes = [_]u64{ 4, 3, 1, 2 };
    const r = Runtime.init(sizes[0..], hashes[0..]);

    try testing.expect(r.type_count == sizes.len);
    const expected_order = [_]usize{ 3, 2, 0, 1 };
    for (expected_order) |order, i| {
        try testing.expectEqual(r.type_sizes[i], sizes[order]);
        try testing.expectEqual(r.type_hashes[i], hashes[order]);
    }
}
