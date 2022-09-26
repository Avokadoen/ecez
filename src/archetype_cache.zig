const std = @import("std");
const IArchetype = @import("IArchetype.zig");

/// Create a cache which utilize a bitmask to check for incoherence
pub fn ArchetypeCache(comptime components: []const type) type {
    const BitMaskType = @Type(std.builtin.Type{ .Int = .{
        .signedness = .unsigned,
        .bits = components.len,
    } });

    return struct {
        const Self = @This();

        mask: BitMaskType,
        cache: [components.len][]IArchetype,

        pub inline fn init() Self {
            return Self{
                // set all bits to 1
                .mask = ~@as(BitMaskType, 0),
                // nothing is cached yet
                .cache = undefined,
            };
        }

        pub inline fn isCoherent(self: Self, comptime other_components: []const type) bool {
            const other_comp_positions = comptime blk: {
                var positions: [other_components.len]usize = undefined;
                for (other_components) |OtherComponent, pos_index| {
                    positions[pos_index] = offsetOf(OtherComponent);
                }
                break :blk positions;
            };

            const other_mask = comptime blk: {
                var mask: BitMaskType = 0;
                for (other_comp_positions) |position| {
                    mask |= (1 << position);
                }
                break :blk mask;
            };

            return (self.mask & other_mask) == 0;
        }

        pub inline fn setIncoherentBit(self: *Self, comptime Component: type) void {
            self.mask |= (1 << offsetOf(Component));
        }

        pub inline fn reset(self: *Self) void {
            self.mask = 0;
        }

        inline fn offsetOf(comptime OtherComponent: type) comptime_int {
            for (components) |Component, comp_location| {
                if (OtherComponent == Component) {
                    return comp_location;
                }
            }
            @compileError("requested type " ++ @typeName(OtherComponent) ++ " which is not a component");
        }
    };
}

const Testing = @import("Testing.zig");
const testing = std.testing;

test "init initialize mask bits to 1" {
    const cache = ArchetypeCache(&Testing.AllComponentsArr).init();

    // this will break if we update Testing.AllComponentsArr
    try testing.expectEqual(@as(u3, 0b111), cache.mask);
}

test "reset set mask bits to 0" {
    var cache = ArchetypeCache(&Testing.AllComponentsArr).init();
    cache.reset();
    try testing.expectEqual(@as(u3, 0b000), cache.mask);
}

test "set assigns a given bit to the mask" {
    var cache = ArchetypeCache(&Testing.AllComponentsArr).init();

    cache.reset();
    cache.setIncoherentBit(Testing.Component.A);
    try testing.expectEqual(@as(u3, 0b001), cache.mask);

    cache.reset();
    cache.setIncoherentBit(Testing.Component.B);
    try testing.expectEqual(@as(u3, 0b010), cache.mask);

    cache.reset();
    cache.setIncoherentBit(Testing.Component.C);
    try testing.expectEqual(@as(u3, 0b100), cache.mask);

    cache.setIncoherentBit(Testing.Component.A);
    try testing.expectEqual(@as(u3, 0b101), cache.mask);

    cache.setIncoherentBit(Testing.Component.B);
    try testing.expectEqual(@as(u3, 0b111), cache.mask);
}

test "isCoherent returns true when type is coherent" {
    var cache = ArchetypeCache(&Testing.AllComponentsArr).init();
    cache.reset();

    try testing.expectEqual(true, cache.isCoherent(&Testing.AllComponentsArr));

    cache.setIncoherentBit(Testing.Component.B);
    try testing.expectEqual(true, cache.isCoherent(&[_]type{ Testing.Component.A, Testing.Component.C }));
}

test "isCoherent returns false when type is incoherent" {
    var cache = ArchetypeCache(&Testing.AllComponentsArr).init();

    try testing.expectEqual(false, cache.isCoherent(&Testing.AllComponentsArr));

    cache.reset();
    cache.setIncoherentBit(Testing.Component.A);
    cache.setIncoherentBit(Testing.Component.C);
    try testing.expectEqual(false, cache.isCoherent(&[_]type{ Testing.Component.A, Testing.Component.C }));
}
