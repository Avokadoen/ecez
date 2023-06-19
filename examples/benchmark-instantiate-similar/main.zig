const std = @import("std");
const ecez = @import("ecez");

const Component1 = struct {
    a: u128 = 0,
    c: u64 = 0,
};
const Component2 = struct {
    a: u256 = 0,
};
const Component3 = struct {};
const Component4 = struct {
    a: u32 = 0,
};
const Component5 = struct {
    a: u32 = 0,
};
const Component6 = struct {
    a: u32 = 0,
};
const Component7 = struct {
    a: u128 = 0,
};
const Component8 = struct {
    a: u128 = 0,
};
const Component9 = struct {
    a: u16 = 0,
};
const Component10 = struct {
    a: u16 = 0,
};

pub fn main() anyerror!void {
    var arena_allocator = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena_allocator.deinit();

    const allocator = arena_allocator.allocator();

    var world = try ecez.WorldBuilder().WithComponents(.{
        Component1,
        Component2,
        Component3,
        Component4,
        Component5,
        Component6,
        Component7,
        Component8,
        Component9,
        Component10,
    }).init(allocator, .{});
    defer world.deinit();

    for (0..1_000_000) |_| {
        const Composition = std.meta.Tuple(&[_]type{
            Component1,
            Component2,
            Component3,
            Component4,
            Component5,
            Component6,
            Component7,
            Component8,
            Component9,
            Component10,
        });
        _ = try world.createEntity(Composition{
            Component1{},
            Component2{},
            Component3{},
            Component4{},
            Component5{},
            Component6{},
            Component7{},
            Component8{},
            Component9{},
            Component10{},
        });
    }
}
