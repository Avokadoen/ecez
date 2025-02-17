const CreateStorage = @import("storage.zig").CreateStorage;
const Entity = @import("entity_type.zig").Entity;

// Query + QueryAny
pub const query_type_count = 2;

pub fn QueryAndQueryAny(comptime Storage: type, comptime ResultItem: type, comptime include_types: anytype, comptime exclude_types: anytype) [2]type {
    return [_]type{
        Storage.Query(ResultItem, include_types, exclude_types),
        Storage.QueryAny(ResultItem, include_types, exclude_types),
    };
}

pub const Component = struct {
    pub const A = struct { value: u32 = 2 };
    pub const B = struct { value: u8 = 4 };
    pub const C = struct {};
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
};

pub const AllComponentsTuple = .{
    Component.A,
    Component.B,
    Component.C,
};

pub const StorageStub = CreateStorage(AllComponentsTuple);

pub const Queries = struct {
    pub const Entities = StorageStub.Query(
        struct {
            entity: Entity,
        },
        .{},
        .{},
    );

    pub const ReadA = QueryAndQueryAny(
        StorageStub,
        struct {
            a: Component.A,
        },
        .{},
        .{},
    );

    pub const ReadAConstPtr = QueryAndQueryAny(
        StorageStub,
        struct {
            a: *const Component.A,
        },
        .{},
        .{},
    );

    pub const ReadB = QueryAndQueryAny(
        StorageStub,
        struct {
            b: Component.B,
        },
        .{},
        .{},
    );

    pub const ReadAReadB = QueryAndQueryAny(
        StorageStub,
        struct {
            a: Component.A,
            b: Component.B,
        },
        .{},
        .{},
    );

    pub const ReadAReadBIncC = QueryAndQueryAny(
        StorageStub,
        struct {
            a: Component.A,
            b: Component.B,
        },
        .{Component.C},
        .{},
    );

    pub const ReadAExclB = QueryAndQueryAny(
        StorageStub,
        struct {
            a: Component.A,
        },
        .{},
        .{Component.B},
    );

    pub const ReadAReadBExclC = QueryAndQueryAny(
        StorageStub,
        struct {
            a: Component.A,
            b: Component.B,
        },
        .{},
        .{Component.C},
    );

    pub const WriteA = QueryAndQueryAny(
        StorageStub,
        struct {
            a: *Component.A,
        },
        .{},
        .{},
    );

    pub const WriteB = QueryAndQueryAny(
        StorageStub,
        struct {
            b: *Component.B,
        },
        .{},
        .{},
    );

    pub const WriteAReadB = QueryAndQueryAny(
        StorageStub,
        struct {
            a: *Component.A,
            b: Component.B,
        },
        .{},
        .{},
    );
};
