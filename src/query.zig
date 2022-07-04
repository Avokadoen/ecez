const std = @import("std");
const testing = std.testing;

const hashfn: fn (str: []const u8) u64 = std.hash.Fnv1a_64.hash;
const max_types = @import("Archetype.zig").max_types;

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
            fn func(context: void, lhs: SortElem, rhs: SortElem) bool {
                _ = context;
                return lhs.type_hash < rhs.type_hash;
            }
        }.func;

        var sort_elements: [max_types]SortElem = undefined;
        for (type_sizes) |size, i| {
            sort_elements[i] = .{
                .type_size = size,
                .type_hash = type_hashes[i],
            };
        }
        std.sort.sort(SortElem, sort_elements[0..type_sizes.len], {}, lessThan);

        var sorted_type_sizes: [max_types]usize = undefined;
        var sorted_type_hashes: [max_types]u64 = undefined;
        // insert void type
        sorted_type_sizes[0] = 0;
        sorted_type_hashes[0] = 0;
        // insert the rest of the types
        for (sort_elements[0..type_sizes.len]) |elem, i| {
            sorted_type_sizes[i + 1] = elem.type_size;
            sorted_type_hashes[i + 1] = elem.type_hash;
        }

        return Runtime{
            .type_count = type_sizes.len + 1,
            .type_sizes = sorted_type_sizes,
            .type_hashes = sorted_type_hashes,
        };
    }
};

test "Runtime init() sort hashes and sizes" {
    const sizes = [_]usize{ 1, 2, 3, 4 };
    const hashes = [_]u64{ 4, 3, 1, 2 };
    const r = Runtime.init(sizes[0..], hashes[0..]);

    // ignore void type
    try testing.expect(r.type_count - 1 == sizes.len);
    const expected_index_order = [_]usize{ 2, 3, 1, 0 };
    for (expected_index_order) |order, i| {
        try testing.expectEqual(sizes[order], r.type_sizes[i + 1]);
        try testing.expectEqual(hashes[order], r.type_hashes[i + 1]);
    }
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
