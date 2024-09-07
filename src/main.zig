const entity_type = @import("entity_type.zig");
const scheduler = @import("scheduler.zig");

pub const Entity = entity_type.Entity;
pub const EntityId = entity_type.EntityId;

/// Use this function to create the ecs storage
pub const CreateStorage = @import("storage.zig").CreateStorage;

/// Use this function to create a system scheduler
pub const CreateScheduler = scheduler.CreateScheduler;

/// Mark an event by name, systems to execute and any unique event data the systems need
pub const Event = scheduler.Event;

/// Ezby can be used to serialize and deserialize storages
pub const ezby = @import("ezby.zig");

test {
    _ = @import("dependency_chain.zig");
    _ = @import("sparse_set.zig");
    _ = @import("scheduler.zig");
    _ = @import("ezby.zig");
    _ = @import("storage.zig");
}
