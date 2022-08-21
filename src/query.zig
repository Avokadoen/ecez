const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

pub const Query = struct {
    /// How many elements can exist in the desired types array, and how many
    /// elements can exist in the exclude types array
    const max_query_elements = 32;

    include_types: []const type,
    exclude_types: []const type,

    pub const QueryBuilder = struct {
        include_types_len: comptime_int,
        include_types: [max_query_elements]type,
        exclude_types_len: comptime_int,
        exclude_types: [max_query_elements]type,

        pub fn init() QueryBuilder {
            return QueryBuilder{
                .include_types_len = 0,
                .include_types = undefined,
                .exclude_types_len = 0,
                .exclude_types = undefined,
            };
        }

        /// Add a new component to look for.
        /// *Component can be a pointer type* to allow result to be mutated
        pub fn with(comptime self: *QueryBuilder, comptime Component: type) *QueryBuilder {
            if (self.include_types_len >= max_query_elements - 1) {
                @compileError("insufficient query capacity");
            }
            const info = @typeInfo(Component);
            switch (info) {
                .Struct => {}, // ok
                .Pointer => {}, // ok
                else => @compileError("illegal component type " ++ @typeName(Component) ++ " added to query"),
            }
            self.include_types[self.include_types_len] = Component;
            self.include_types_len += 1;
            return self;
        }

        /// Filter archetypes that include the given component
        /// Component can **not** be a pointer type
        pub fn without(comptime self: *QueryBuilder, comptime Component: type) *QueryBuilder {
            if (self.exclude_types_len >= max_query_elements - 1) {
                @compileError("insufficient query capacity");
            }
            const info = @typeInfo(Component);
            switch (info) {
                .Struct => {}, // ok
                else => @compileError("illegal component type " ++ @typeName(Component) ++ " added to query"),
            }
            self.exclude_types[self.exclude_types_len] = Component;
            self.exclude_types_len += 1;
            return self;
        }

        pub fn build(comptime self: QueryBuilder) Query {
            return Query{
                .include_types = self.include_types[0..self.include_types_len],
                .exclude_types = self.exclude_types[0..self.exclude_types_len],
            };
        }
    };
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
