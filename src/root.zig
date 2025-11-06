const entity_type = @import("entity_type.zig");
/// Ecez's entity type. Use this to apply changes to an entity that exist in a given storage.
pub const Entity = entity_type.Entity;
/// Ecez's entity id type. Ids is the only member of an Entity
pub const EntityId = entity_type.EntityId;
/// Ezby can be used to serialize and deserialize storages
pub const ezby = @import("ezby.zig");
const query = @import("query.zig");
/// Use this function to create the ecs query type
pub const Query = query.Query;
/// Use this function to create the ecs query any type
pub const QueryAny = query.QueryAny;
const scheduler = @import("scheduler.zig");
/// Use this function to create a system scheduler type
pub const CreateScheduler = scheduler.CreateScheduler;
pub const EventConfig = scheduler.EventConfig;
/// Events are a set of systems that should execute when triggered.
/// Mark an event by name and systems to execute
pub const Event = scheduler.Event;
const storage = @import("storage.zig");
/// Use this function to create the ecs storage type
pub const CreateStorage = storage.CreateStorage;
/// Utility functions to perform compile time reflections on components and storage
/// This may or may not be useful to you
pub const StorageCompileReflect = storage.CompileReflect;

test {
    _ = @import("dependency_chain.zig");
    _ = @import("ezby.zig");
    _ = @import("scheduler.zig");
    _ = @import("sparse_set.zig");
    _ = @import("storage.zig");
}
