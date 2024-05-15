const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const Thread = std.Thread;

const entity_type = @import("entity_type.zig");
pub const Entity = entity_type.Entity;

const meta = @import("meta.zig");

/// Create a storage edit queue, this allows thread safe queing of storage edits.
/// These edits can either be parsed during the end of the scheduler execution,
/// or during, if expressed as such in the scheduler type definition.
pub fn StorageEditQueue(comptime components: []const type) type {
    // create the component edit queues based on storage components
    const Queues = make_queue_type_blk: {
        comptime var fields: [components.len]std.builtin.Type.StructField = undefined;
        for (&fields, components) |*field, component| {
            const Queue = ComponentQueue(component);
            var default = Queue{};
            field.* = .{
                .name = @typeName(component),
                .type = Queue,
                .default_value = &default,
                .is_comptime = false,
                .alignment = @alignOf(Queue),
            };
        }

        const struct_type = std.builtin.Type.Struct{
            .layout = .Auto,
            .fields = &fields,
            .decls = &[0]std.builtin.Type.Declaration{},
            .is_tuple = false,
        };

        break :make_queue_type_blk @Type(std.builtin.Type{ .Struct = struct_type });
    };

    return struct {
        const Self = @This();

        // used to identify special argument in system
        comptime secret_field: meta.ArgType = .storage_edit_queue,

        allocator: Allocator,
        queues: Queues = .{},

        /// Queue create entity operation
        pub fn queueCreateEntity(self: *Self, component: anytype) Allocator.Error!void {
            const Component = @TypeOf(component);
            comptime verifyComponent(Component);

            var queue = &@field(self.queues, @typeName(Component));
            try queue.queueCreateEntity(self.allocator, component);
        }

        /// Queue set component operation
        pub fn queueSetComponent(self: *Self, entity: Entity, component: anytype) Allocator.Error!void {
            const Component = @TypeOf(component);
            comptime verifyComponent(Component);

            var queue = &@field(self.queues, @typeName(Component));
            try queue.queueSetComponent(self.allocator, entity, component);
        }

        /// Queue remove component operation
        pub fn queueRemoveComponent(self: *Self, entity: Entity, Component: type) Allocator.Error!void {
            comptime verifyComponent(Component);

            var queue = &@field(self.queues, @typeName(Component));
            try queue.queueRemoveComponent(self.allocator, entity);
        }

        /// Clear the queues and free and buffers allocated so far
        pub fn clearAndFree(self: *Self) void {
            inline for (components) |Component| {
                var queue = &@field(self.queues, @typeName(Component));
                queue.clearAndFree(self.allocator);
            }
        }

        pub fn clearRetainingCapacity(self: *Self) void {
            inline for (components) |Component| {
                var queue = &@field(self.queues, @typeName(Component));
                queue.clearRetainingCapacity(self.allocator);
            }
        }

        fn verifyComponent(comptime Component: type) void {
            verify_blk: {
                inline for (components) |RegisteredComponent| {
                    if (RegisteredComponent == Component) {
                        break :verify_blk;
                    }
                }
                @compileError(@typeName(Component) ++ " is not part of the storage components");
            }
        }
    };
}

// TODO: doc comments + tests
fn ComponentQueue(Component: type) type {
    return struct {
        const Self = @This();

        pub const CreateEntityJob = struct {
            component: Component,
        };

        pub const SetComponentJob = struct {
            entity: Entity,
            component: Component,
        };

        pub const RemoveComponentJob = struct {
            entity: Entity,
        };

        create_entity_mutex: Thread.Mutex = .{},
        create_entity_queue: ArrayListUnmanaged(CreateEntityJob) = .{},

        set_component_mutex: Thread.Mutex = .{},
        set_component_queue: ArrayListUnmanaged(SetComponentJob) = .{},

        remove_component_mutex: Thread.Mutex = .{},
        remove_component_queue: ArrayListUnmanaged(RemoveComponentJob) = .{},

        pub fn queueCreateEntity(self: *Self, allocator: Allocator, component: Component) Allocator.Error!void {
            self.create_entity_mutex.lock();
            defer self.create_entity_mutex.unlock();

            try self.create_entity_queue.append(allocator, CreateEntityJob{ .component = component });
        }

        pub fn queueSetComponent(self: *Self, allocator: Allocator, entity: Entity, component: Component) Allocator.Error!void {
            self.set_component_mutex.lock();
            defer self.set_component_mutex.unlock();

            try self.set_component_queue.append(allocator, SetComponentJob{ .entity = entity, .component = component });
        }

        pub fn queueRemoveComponent(self: *Self, allocator: Allocator, entity: Entity) Allocator.Error!void {
            self.remove_component_mutex.lock();
            defer self.remove_component_mutex.unlock();

            try self.remove_component_queue.append(allocator, RemoveComponentJob{ .entity = entity });
        }

        pub fn clearAndFree(self: *Self, allocator: Allocator) void {
            self.create_entity_queue.clearAndFree(allocator);
            self.set_component_queue.clearAndFree(allocator);
            self.remove_component_queue.clearAndFree(allocator);
        }

        pub fn clearRetainingCapacity(self: *Self) void {
            self.create_entity_queue.clearRetainingCapacity();
            self.set_component_queue.clearRetainingCapacity();
            self.remove_component_queue.clearRetainingCapacity();
        }
    };
}

const Testing = @import("Testing.zig");
const testing = std.testing;

const StorageStub = @import("storage.zig").CreateStorage(Testing.AllComponentsTuple);

// TODO: we cant use tuples here because of https://github.com/ziglang/zig/issues/12963
const AEntityType = Testing.Archetype.A;
const BEntityType = Testing.Archetype.B;

test "ComponentQueue cleanAndFree fress memory" {
    var component_queue_a = ComponentQueue(Testing.Component.A){};

    // populate it with some heap memory
    try component_queue_a.queueCreateEntity(testing.allocator, Testing.Component.A{ .value = 0 });
    try component_queue_a.queueSetComponent(testing.allocator, Entity{ .id = 0 }, Testing.Component.A{ .value = 0 });
    try component_queue_a.queueRemoveComponent(testing.allocator, Entity{ .id = 0 });

    // clear and free storage
    component_queue_a.clearAndFree(testing.allocator);
}

test "StorageEditQueue clearAndFree frees memory" {
    // create storage queue
    var storage_queue = StorageEditQueue(&Testing.AllComponentsArr){
        .allocator = testing.allocator,
    };

    // populate it with some heap memory
    try storage_queue.queueCreateEntity(Testing.Component.A{ .value = 0 });
    try storage_queue.queueSetComponent(Entity{ .id = 0 }, Testing.Component.A{ .value = 0 });
    try storage_queue.queueRemoveComponent(Entity{ .id = 0 }, Testing.Component.A);

    try storage_queue.queueCreateEntity(Testing.Component.B{ .value = 0 });
    try storage_queue.queueSetComponent(Entity{ .id = 0 }, Testing.Component.B{ .value = 0 });
    try storage_queue.queueRemoveComponent(Entity{ .id = 0 }, Testing.Component.B);

    try storage_queue.queueCreateEntity(Testing.Component.C{});
    try storage_queue.queueSetComponent(Entity{ .id = 0 }, Testing.Component.C{});
    try storage_queue.queueRemoveComponent(Entity{ .id = 0 }, Testing.Component.C);

    // clear and free storage
    storage_queue.clearAndFree();
}

test "StorageEditQueue queueCreateEntity populated as expected" {
    // create storage queue
    var storage_queue = StorageEditQueue(&Testing.AllComponentsArr){
        .allocator = testing.allocator,
    };
    defer storage_queue.clearAndFree();

    {
        const a_component = Testing.Component.A{ .value = 0 };
        try storage_queue.queueCreateEntity(a_component);
        const a_queue = &@field(storage_queue.queues, @typeName(Testing.Component.A));
        try testing.expectEqual(1, a_queue.create_entity_queue.items.len);

        const create_entity_job = a_queue.create_entity_queue.items[0];
        try testing.expectEqual(a_component, create_entity_job.component);
    }

    {
        const b_component = Testing.Component.B{ .value = 0 };
        try storage_queue.queueCreateEntity(b_component);
        const b_queue = &@field(storage_queue.queues, @typeName(Testing.Component.B));
        try testing.expectEqual(1, b_queue.create_entity_queue.items.len);

        const create_entity_job = b_queue.create_entity_queue.items[0];
        try testing.expectEqual(b_component, create_entity_job.component);
    }

    {
        const c_component = Testing.Component.C{};
        try storage_queue.queueCreateEntity(c_component);
        const c_queue = &@field(storage_queue.queues, @typeName(Testing.Component.C));
        try testing.expectEqual(1, c_queue.create_entity_queue.items.len);

        const create_entity_job = c_queue.create_entity_queue.items[0];
        try testing.expectEqual(c_component, create_entity_job.component);
    }
}

test "StorageEditQueue queueSetComponent populated as expected" {
    // create storage queue
    var storage_queue = StorageEditQueue(&Testing.AllComponentsArr){
        .allocator = testing.allocator,
    };
    defer storage_queue.clearAndFree();

    const entity = Entity{ .id = 0 };

    {
        const a_component = Testing.Component.A{ .value = 0 };
        try storage_queue.queueSetComponent(entity, a_component);
        const a_queue = &@field(storage_queue.queues, @typeName(Testing.Component.A));
        try testing.expectEqual(1, a_queue.set_component_queue.items.len);

        const set_component_job = a_queue.set_component_queue.items[0];
        try testing.expectEqual(a_component, set_component_job.component);
        try testing.expectEqual(entity, set_component_job.entity);
    }

    {
        const b_component = Testing.Component.B{ .value = 0 };
        try storage_queue.queueSetComponent(entity, b_component);
        const b_queue = &@field(storage_queue.queues, @typeName(Testing.Component.B));
        try testing.expectEqual(1, b_queue.set_component_queue.items.len);

        const set_component_job = b_queue.set_component_queue.items[0];
        try testing.expectEqual(b_component, set_component_job.component);
        try testing.expectEqual(entity, set_component_job.entity);
    }

    {
        const c_component = Testing.Component.C{};
        try storage_queue.queueSetComponent(entity, c_component);
        const c_queue = &@field(storage_queue.queues, @typeName(Testing.Component.C));
        try testing.expectEqual(1, c_queue.set_component_queue.items.len);

        const set_component_job = c_queue.set_component_queue.items[0];
        try testing.expectEqual(c_component, set_component_job.component);
        try testing.expectEqual(entity, set_component_job.entity);
    }
}

test "StorageEditQueue queueRemoveComponent populated as expected" {
    // create storage queue
    var storage_queue = StorageEditQueue(&Testing.AllComponentsArr){
        .allocator = testing.allocator,
    };
    defer storage_queue.clearAndFree();

    const entity = Entity{ .id = 0 };

    {
        try storage_queue.queueRemoveComponent(entity, Testing.Component.A);
        const a_queue = &@field(storage_queue.queues, @typeName(Testing.Component.A));
        try testing.expectEqual(1, a_queue.remove_component_queue.items.len);

        const remove_component_job = a_queue.remove_component_queue.items[0];
        try testing.expectEqual(entity, remove_component_job.entity);
    }

    {
        try storage_queue.queueRemoveComponent(entity, Testing.Component.B);
        const b_queue = &@field(storage_queue.queues, @typeName(Testing.Component.B));
        try testing.expectEqual(1, b_queue.remove_component_queue.items.len);

        const remove_component_job = b_queue.remove_component_queue.items[0];
        try testing.expectEqual(entity, remove_component_job.entity);
    }

    {
        try storage_queue.queueRemoveComponent(entity, Testing.Component.C);
        const c_queue = &@field(storage_queue.queues, @typeName(Testing.Component.C));
        try testing.expectEqual(1, c_queue.remove_component_queue.items.len);

        const remove_component_job = c_queue.remove_component_queue.items[0];
        try testing.expectEqual(entity, remove_component_job.entity);
    }
}
