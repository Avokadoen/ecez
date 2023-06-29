// TODO: submit to repo
const world = @import("world.zig");
pub const WorldBuilder = world.WorldBuilder;

const entity_type = @import("entity_type.zig");
pub const Entity = entity_type.Entity;
pub const EntityId = entity_type.EntityId;
pub const EntityRef = entity_type.EntityRef;

const meta = @import("meta.zig");
pub const DependOn = meta.DependOn;
pub const SharedState = meta.SharedState;
pub const EventArgument = meta.EventArgument;
pub const Event = meta.Event;

pub const query = @import("query.zig");
pub const tracy_alloc = @import("tracy_alloc.zig");
pub const misc = @import("misc.zig");

test {
    _ = @import("archetype_container.zig");
    _ = @import("binary_tree.zig");
    _ = @import("iterator.zig");
    _ = @import("opaque_archetype.zig");
    _ = @import("query.zig");
    _ = @import("world.zig");
    _ = @import("meta.zig");
}
