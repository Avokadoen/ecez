const std = @import("std");
const Allocator = std.mem.Allocator;
const query = @import("query.zig");
const OpaqueArchetype = @import("OpaqueArchetype.zig");

// TODO: reduce system_count by checking which has identitcal arguments

/// Create a cache which utilize a bitmask to check for incoherence
pub fn ArchetypeCacheMask(comptime components: []const type) type {
    const BitMask = @Type(std.builtin.Type{ .Int = .{
        .signedness = .unsigned,
        .bits = components.len,
    } });

    return struct {
        const Self = @This();

        mask: BitMask,

        pub inline fn init() Self {
            return Self{
                // set all bits to 1 (incoherent)
                .mask = ~@as(BitMask, 0),
            };
        }

        pub inline fn clear(self: *Self) void {
            // set all bits to 1 (incoherent)
            self.mask = ~@as(BitMask, 0);
        }

        pub fn isCoherent(self: Self, comptime other_components: []const type) bool {
            const other_comp_positions = comptime blk: {
                var positions: [other_components.len]usize = undefined;
                for (other_components, 0..) |OtherComponent, pos_index| {
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

        pub fn setIncoherentBitWithTypeHashes(self: *Self, type_hashes: []const u64) void {
            outer: for (type_hashes) |hash| {
                inline for (components, 0..) |Component, i| {
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

        inline fn offsetOf(comptime OtherComponent: type) comptime_int {
            for (components, 0..) |Component, comp_location| {
                if (OtherComponent == Component) {
                    return comp_location;
                }
            }
            @compileError("requested type " ++ @typeName(OtherComponent) ++ " which is not a component");
        }
    };
}

pub fn ArchetypeCacheStorage(comptime storage_count: comptime_int) type {
    const InitializeMask = @Type(std.builtin.Type{ .Int = .{
        .signedness = .unsigned,
        .bits = storage_count,
    } });

    return struct {
        const Self = @This();

        initialized_mask: InitializeMask,
        cache: [storage_count][]*OpaqueArchetype,

        pub fn init() Self {
            return Self{
                // nothing is initialized
                .initialized_mask = @as(InitializeMask, 0),
                // nothing is cached yet
                .cache = undefined,
            };
        }

        pub fn deinit(self: Self, allocator: Allocator) void {
            inline for (0..storage_count) |cache_index| {
                if ((self.initialized_mask & (1 << cache_index)) != 0) {
                    allocator.free(self.cache[cache_index]);
                }
            }
        }

        pub fn clear(self: *Self, allocator: Allocator) void {
            self.deinit(allocator);
            self.initialized_mask = @as(InitializeMask, 0);
        }

        pub fn assignCacheEntry(self: *Self, allocator: Allocator, comptime system_index: comptime_int, archetypes: []*OpaqueArchetype) void {
            if ((self.initialized_mask & (1 << system_index)) != 0) {
                allocator.free(self.cache[system_index]);
            }

            self.initialized_mask |= (1 << system_index);
            self.cache[system_index] = archetypes;
        }
    };
}

const Testing = @import("Testing.zig");
const testing = std.testing;

test "ArchetypeCacheMask init initialize mask bits to 1" {
    const cache = ArchetypeCacheMask(&Testing.AllComponentsArr).init();

    // this will break if we update Testing.AllComponentsArr
    try testing.expectEqual(@as(u3, 0b111), cache.mask);
}

test "ArchetypeCacheMask reset set mask bits to 0" {
    var cache = ArchetypeCacheMask(&Testing.AllComponentsArr).init();
    cache.setAllCoherent();
    try testing.expectEqual(@as(u3, 0b000), cache.mask);
}

test "ArchetypeCacheMask setIncoherentBit assigns a given bit to the mask" {
    var cache = ArchetypeCacheMask(&Testing.AllComponentsArr).init();

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

test "ArchetypeCacheMask setIncoherentBitWithTypeHashes assigns given bits to the mask" {
    var cache = ArchetypeCacheMask(&Testing.AllComponentsArr).init();
    cache.setAllCoherent();
    cache.setIncoherentBitWithTypeHashes(&[_]u64{ query.hashType(Testing.Component.A), query.hashType(Testing.Component.C) });
    try testing.expectEqual(@as(u3, 0b101), cache.mask);
}

test "ArchetypeCacheMask isCoherent returns true when type is coherent" {
    var cache = ArchetypeCacheMask(&Testing.AllComponentsArr).init();
    cache.setAllCoherent();

    try testing.expectEqual(true, cache.isCoherent(&Testing.AllComponentsArr));

    cache.setIncoherentBit(Testing.Component.B);
    try testing.expectEqual(true, cache.isCoherent(&[_]type{ Testing.Component.A, Testing.Component.C }));
}

test "ArchetypeCacheMask isCoherent returns false when type is incoherent" {
    var cache = ArchetypeCacheMask(&Testing.AllComponentsArr).init();

    try testing.expectEqual(false, cache.isCoherent(&Testing.AllComponentsArr));

    cache.setAllCoherent();
    cache.setIncoherentBit(Testing.Component.A);
    cache.setIncoherentBit(Testing.Component.C);
    try testing.expectEqual(false, cache.isCoherent(&[_]type{ Testing.Component.A, Testing.Component.C }));
}
