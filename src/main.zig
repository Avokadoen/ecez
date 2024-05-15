const entity_type = @import("entity_type.zig");
const meta = @import("meta.zig");

pub const Entity = entity_type.Entity;
pub const EntityId = entity_type.EntityId;
pub const EntityRef = entity_type.EntityRef;

/// Use this function to create the ecs storage
pub const CreateStorage = @import("storage.zig").CreateStorage;

/// Use this function to create a system scheduler
pub const CreateScheduler = @import("scheduler.zig").CreateScheduler;

/// A function can return this type in order to exit system execution early
pub const ReturnCommand = meta.ReturnCommand;

/// Special argument that tells the system how many times the system has been invoced before in current dispatch
pub const InvocationCount = meta.InvocationCount;

/// Mark a system as depending on another system in the same event
pub const DependOn = meta.DependOn;

/// Mark a parameter as a shared state that exist in the storage instance
pub const SharedState = meta.SharedState;

/// Mark an event by name, systems to execute and any unique event data the systems need
pub const Event = meta.Event;

/// A builtin system that flushes any queued storage edits
/// This incurs a "pipeline bubble" as any system before this system must complete,
/// and any system after the FlushEditQueue must wait on this flush.
pub const FlushEditQueue = meta.FlushEditQueue;

/// Allocator traced by tracy
pub const tracy_alloc = @import("tracy_alloc.zig");

/// Ezby can be used to serialize and deserialize storages
pub const ezby = @import("ezby.zig");

test {
    _ = @import("archetype_container.zig");
    _ = @import("binary_tree.zig");
    _ = @import("ezby.zig");
    _ = @import("iterator.zig");
    _ = @import("opaque_archetype.zig");
    _ = @import("storage.zig");
    _ = @import("scheduler.zig");
    _ = @import("meta.zig");
    _ = @import("storage_edit_queue.zig");
}
