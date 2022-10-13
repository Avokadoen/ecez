const std = @import("std");
const testing = std.testing;

pub const WorldBuilder = @import("world.zig").WorldBuilder;

const meta = @import("meta.zig");
pub const DependOn = meta.DependOn;
pub const SharedState = meta.SharedState;
pub const EventArgument = meta.EventArgument;
pub const Event = meta.Event;

pub const Query = @import("query.zig").Query;
pub const tracy_alloc = @import("tracy_alloc.zig");
pub const misc = @import("misc.zig");

test {
    _ = @import("world.zig");
    _ = @import("archetype_cache.zig");
    _ = @import("archetype_container.zig");
    _ = @import("query.zig");
    _ = @import("iterator.zig");
    _ = @import("OpaqueArchetype.zig");
}
