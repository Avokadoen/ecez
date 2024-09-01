// const entity_type = @import("entity_type.zig");
// const meta = @import("meta.zig");

// pub const Entity = entity_type.Entity;
// pub const EntityId = entity_type.EntityId;
// pub const EntityRef = entity_type.EntityRef;

// /// Use this function to create the ecs storage
// pub const CreateStorage = @import("storage.zig").CreateStorage;

// /// Use this function to create a system scheduler
// pub const CreateScheduler = @import("scheduler.zig").CreateScheduler;

// /// A function can return this type in order to exit system execution early
// pub const ReturnCommand = meta.ReturnCommand;

// /// Special argument that tells the system how many times the system has been invoced before in current dispatch
// pub const InvocationCount = meta.InvocationCount;

// /// Mark a system as depending on another system in the same event
// pub const DependOn = meta.DependOn;

// /// Mark an event by name, systems to execute and any unique event data the systems need
// pub const Event = meta.Event;

// /// A function to tag individual component types in a tuple as excluded from the system dispatch.
// pub const ExcludeEntityWith = meta.ExcludeEntitiesWith;

// /// Ezby can be used to serialize and deserialize storages
// pub const ezby = @import("ezby.zig");

test {
    _ = @import("dependency_chain.zig");
    _ = @import("sparse_set.zig");
    // _ = @import("scheduler.zig");
    // _ = @import("ezby.zig");
    _ = @import("storage.zig");
}
