const std = @import("std");
const Allocator = std.mem.Allocator;
const IArchetype = @import("IArchetype.zig");
const query = @import("query.zig");

// TODO: reduce system_count by checking which has identitcal arguments
/// Create a cache which utilize a bitmask to check for incoherence
pub fn ArchetypeCache(comptime system_count: comptime_int, comptime components: []const type) type {
    const BitMask = @Type(std.builtin.Type{ .Int = .{
        .signedness = .unsigned,
        .bits = components.len,
    } });

    const InitializeMask = @Type(std.builtin.Type{ .Int = .{
        .signedness = .unsigned,
        .bits = system_count,
    } });

    return struct {
        const Self = @This();

        mask: BitMask,
        initialized_mask: InitializeMask,
        cache: [system_count][]IArchetype,

        pub inline fn init() Self {
            return Self{
                // set all bits to 1 (incoherent)
                .mask = ~@as(BitMask, 0),
                // nothing is initialized
                .initialized_mask = @as(InitializeMask, 0),
                // nothing is cached yet
                .cache = undefined,
            };
        }

        pub inline fn deinit(self: Self, allocator: Allocator) void {
            comptime var i = 0;
            inline while (i < system_count) : (i += 1) {
                if ((self.initialized_mask & (1 << i)) != 0) {
                    allocator.free(self.cache[i]);
                }
            }
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
                var mask: BitMask = 0;
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

        pub inline fn setIncoherentBitWithTypeHashes(self: *Self, type_hashes: []const u64) void {
            outer: for (type_hashes) |hash| {
                inline for (components) |Component, i| {
                    if (hash == query.hashType(Component)) {
                        self.mask |= (1 << i);
                        continue :outer;
                    }
                }
                unreachable;
            }
        }

        pub inline fn setAllCoherent(self: *Self) void {
            self.mask = 0;
        }

        pub inline fn assignCacheEntry(self: *Self, allocator: Allocator, comptime system_index: comptime_int, archetypes: []IArchetype) void {
            if ((self.initialized_mask & (1 << system_index)) != 0) {
                allocator.free(self.cache[system_index]);
            }

            self.initialized_mask |= (1 << system_index);
            self.cache[system_index] = archetypes;
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
    const cache = ArchetypeCache(0, &Testing.AllComponentsArr).init();

    // this will break if we update Testing.AllComponentsArr
    try testing.expectEqual(@as(u3, 0b111), cache.mask);
}

test "reset set mask bits to 0" {
    var cache = ArchetypeCache(0, &Testing.AllComponentsArr).init();
    cache.setAllCoherent();
    try testing.expectEqual(@as(u3, 0b000), cache.mask);
}

test "setIncoherentBit assigns a given bit to the mask" {
    var cache = ArchetypeCache(0, &Testing.AllComponentsArr).init();

    cache.setAllCoherent();
    cache.setIncoherentBit(Testing.Component.A);
    try testing.expectEqual(@as(u3, 0b001), cache.mask);

    cache.setAllCoherent();
    cache.setIncoherentBit(Testing.Component.B);
    try testing.expectEqual(@as(u3, 0b010), cache.mask);

    cache.setAllCoherent();
    cache.setIncoherentBit(Testing.Component.C);
    try testing.expectEqual(@as(u3, 0b100), cache.mask);

    cache.setIncoherentBit(Testing.Component.A);
    try testing.expectEqual(@as(u3, 0b101), cache.mask);

    cache.setIncoherentBit(Testing.Component.B);
    try testing.expectEqual(@as(u3, 0b111), cache.mask);
}

test "setIncoherentBitWithTypeHashes assigns given bits to the mask" {
    var cache = ArchetypeCache(0, &Testing.AllComponentsArr).init();
    cache.setAllCoherent();
    cache.setIncoherentBitWithTypeHashes(&[_]u64{ query.hashType(Testing.Component.A), query.hashType(Testing.Component.C) });
    try testing.expectEqual(@as(u3, 0b101), cache.mask);
}

test "isCoherent returns true when type is coherent" {
    var cache = ArchetypeCache(0, &Testing.AllComponentsArr).init();
    cache.setAllCoherent();

    try testing.expectEqual(true, cache.isCoherent(&Testing.AllComponentsArr));

    cache.setIncoherentBit(Testing.Component.B);
    try testing.expectEqual(true, cache.isCoherent(&[_]type{ Testing.Component.A, Testing.Component.C }));
}

test "isCoherent returns false when type is incoherent" {
    var cache = ArchetypeCache(0, &Testing.AllComponentsArr).init();

    try testing.expectEqual(false, cache.isCoherent(&Testing.AllComponentsArr));

    cache.setAllCoherent();
    cache.setIncoherentBit(Testing.Component.A);
    cache.setIncoherentBit(Testing.Component.C);
    try testing.expectEqual(false, cache.isCoherent(&[_]type{ Testing.Component.A, Testing.Component.C }));
}
