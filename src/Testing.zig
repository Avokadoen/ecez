const meta = @import("meta.zig");

pub const Component = struct {
    pub const A = struct { value: u32 = 2 };
    pub const B = struct { value: u8 = 4 };
    pub const C = struct {};
};

pub const Archetype = struct {
    pub const A = struct {
        a: Component.A = .{},
    };
    pub const B = struct {
        b: Component.B = .{},
    };
    pub const C = struct {
        c: Component.C = .{},
    };
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

// TODO: remove me
pub const AllArchetypesArr = [_]type{
    Archetype.A,
    Archetype.AB,
    Archetype.AC,
    Archetype.ABC,
};

// TODO: remove me
pub const AllArchetypesTuple = .{
    Archetype.A,
    Archetype.AB,
    Archetype.AC,
    Archetype.ABC,
};

pub const ComponentBitmask = meta.BitMaskFromComponents(&AllComponentsArr);
pub const Bits = struct {
    pub const None = @as(ComponentBitmask.Bits, 0b000);
    pub const A = @as(ComponentBitmask.Bits, 0b001);
    pub const B = @as(ComponentBitmask.Bits, 0b010);
    pub const C = @as(ComponentBitmask.Bits, 0b100);
    pub const All = @as(ComponentBitmask.Bits, 0b111);
};
