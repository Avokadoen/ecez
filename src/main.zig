const std = @import("std");
const testing = std.testing;

const world = @import("world.zig");

pub const WorldBuilder = world.WorldBuilder;
pub const SharedState = world.SharedState;
pub const Event = world.Event;

pub const Query = @import("query.zig").Query;
pub const tracy_alloc = @import("tracy_alloc.zig");
pub const misc = @import("misc.zig");

test {
    _ = @import("world.zig");
    _ = @import("archetype.zig");
    _ = @import("archetype_cache.zig");
    _ = @import("archetype_container.zig");
    _ = @import("query.zig");
    _ = @import("iterator.zig");
    _ = @import("OpaqueArchetype.zig");
}
