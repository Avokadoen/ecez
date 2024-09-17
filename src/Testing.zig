const CreateStorage = @import("storage.zig").CreateStorage;
const Entity = @import("entity_type.zig").Entity;

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
    pub const Entities = StorageStub.Query(struct {
        entity: Entity,
    }, .{});

    pub const ReadA = StorageStub.Query(struct {
        a: Component.A,
    }, .{});

    pub const ReadB = StorageStub.Query(struct {
        b: Component.B,
    }, .{});

    pub const ReadAReadB = StorageStub.Query(struct {
        a: Component.A,
        b: Component.B,
    }, .{});

    pub const WriteA = StorageStub.Query(struct {
        a: *Component.A,
    }, .{});

    pub const WriteB = StorageStub.Query(struct {
        b: *Component.B,
    }, .{});

    pub const WriteAReadB = StorageStub.Query(struct {
        a: *Component.A,
        b: Component.B,
    }, .{});
};
