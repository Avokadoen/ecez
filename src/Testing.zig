const CreateStorage = @import("storage.zig").CreateStorage;
const Entity = @import("entity_type.zig").Entity;
const query = @import("query.zig");

// Query + QueryAny
pub const query_type_count = 2;

pub fn QueryAndQueryAny(comptime ResultItem: type, comptime include_types: anytype, comptime exclude_types: anytype) [2]type {
    return [_]type{
        query.Query(ResultItem, include_types, exclude_types),
        query.QueryAny(ResultItem, include_types, exclude_types),
    };
}

pub const Component = struct {
    pub const A = struct { value: u32 = 2 };
    pub const B = struct { value: u8 = 4 };
    pub const C = struct {};
    pub const D = enum {
        zero,
        one,
        two,
    };
    pub const E = union(D) {
        zero: u0,
        one: u8,
        two: u32,
    };
    pub const F = struct {};
};

pub const Structure = struct {
    pub const AB = struct {
        a: Component.A = .{},
        b: Component.B = .{},
    };
    pub const AC = struct {
        a: Component.A = .{},
        c: Component.C = .{},
    };
    pub const BC = struct {
        b: Component.B = .{},
        c: Component.C = .{},
    };
    pub const ABC = struct {
        a: Component.A = .{},
        b: Component.B = .{},
        c: Component.C = .{},
    };
};

pub const AllComponentsArr = [_]type{
    Component.A,
    Component.B,
    Component.C,
    Component.D,
    Component.E,
    Component.F,
};

pub const StorageStub = CreateStorage(&AllComponentsArr);

pub const Queries = struct {
    pub const Entities = query.Query(
        struct {
            entity: Entity,
        },
        .{},
        .{},
    );

    pub const ReadA = QueryAndQueryAny(
        struct {
            a: Component.A,
        },
        .{},
        .{},
    );

    pub const ReadAConstPtr = QueryAndQueryAny(
        struct {
            a: *const Component.A,
        },
        .{},
        .{},
    );

    pub const ReadB = QueryAndQueryAny(
        struct {
            entity: Entity,
            b: Component.B,
        },
        .{},
        .{},
    );

    pub const ReadC = QueryAndQueryAny(
        struct {
            entity: Entity,
        },
        .{Component.C},
        .{},
    );

    pub const ReadAReadB = QueryAndQueryAny(
        struct {
            a: Component.A,
            b: Component.B,
        },
        .{},
        .{},
    );

    pub const ReadAReadBIncC = QueryAndQueryAny(
        struct {
            a: Component.A,
            b: Component.B,
        },
        .{Component.C},
        .{},
    );

    pub const ReadAExclB = QueryAndQueryAny(
        struct {
            a: Component.A,
        },
        .{},
        .{Component.B},
    );

    pub const ReadAReadBExclC = QueryAndQueryAny(
        struct {
            a: Component.A,
            b: Component.B,
        },
        .{},
        .{Component.C},
    );

    pub const WriteA = QueryAndQueryAny(
        struct {
            a: *Component.A,
        },
        .{},
        .{},
    );

    pub const WriteB = QueryAndQueryAny(
        struct {
            b: *Component.B,
        },
        .{},
        .{},
    );

    pub const WriteD = QueryAndQueryAny(
        struct {
            d: *Component.D,
        },
        .{},
        .{},
    );

    pub const WriteAReadB = QueryAndQueryAny(
        struct {
            a: *Component.A,
            b: Component.B,
        },
        .{},
        .{},
    );

    pub const WriteAReadBIncC = QueryAndQueryAny(
        struct {
            entity: Entity,
            a: *Component.A,
            b: Component.B,
        },
        .{Component.C},
        .{},
    );
};
