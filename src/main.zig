const entity_type = @import("entity_type.zig");
const scheduler = @import("scheduler.zig");

/// Ecez's entity type. Use this to apply changes to an entity that exist in a given storage.
pub const Entity = entity_type.Entity;

/// Use this function to create the ecs storage
pub const CreateStorage = @import("storage.zig").CreateStorage;

/// Use this function to create a system scheduler
pub const CreateScheduler = scheduler.CreateScheduler;

/// Events are a set of systems that should execute when triggered.
/// Mark an event by name and systems to execute
pub const Event = scheduler.Event;

/// Ezby can be used to serialize and deserialize storages
pub const ezby = @import("ezby.zig");

test {
    _ = @import("dependency_chain.zig");
    _ = @import("ezby.zig");
    _ = @import("scheduler.zig");
    _ = @import("sparse_set.zig");
    _ = @import("storage.zig");
}
