const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const meta = @import("meta.zig");

pub const Query = struct {
    include_types: []const type,
    exclude_types: []const type,

    pub fn init(
        comptime include_types: []const type,
        comptime exclude_types: []const type,
    ) Query {
        return Query{
            .include_types = include_types,
            .exclude_types = exclude_types,
        };
    }
};

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

pub fn hashType(comptime T: type) u64 {
    const type_name = @typeName(T);
    return hashfn(type_name[0..]);
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
        try testing.expect(T == sorted_types2[i]);
    }
}
