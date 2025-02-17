const std = @import("std");
const ecez = @import("ecez");
const ezby = ecez.ezby;

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    // We start by defining some components
    const Component = struct {
        pub const Health = struct {
            value: f32,
        };
        pub const DeadTag = struct {};
        pub const Weapon = struct {};
        pub const Position = struct {
            x: f32 = 0,
            y: f32 = 0,
            z: f32 = 0,
        };
        pub const Velocity = struct {};
        pub const HeartOrgan = struct {};
    };

    // Given a set of components, we can store them in a storage defined by the component set.
    const Storage = ecez.CreateStorage(.{
        Component.Health,
        Component.DeadTag,
        Component.Weapon,
        Component.Position,
        Component.Velocity,
        Component.HeartOrgan,
    });

    // Initialize our storage
    var storage = try Storage.init(allocator);
    defer storage.deinit();

    // We can then define queries on the storage. These can be used to iterate entities with certain components-
    const Queries = struct {
        pub const Living = Storage.Query(
            // Any result item will be of this type
            struct {
                health: *Component.Health, // health can be mutated because it's a pointer
                pos: Component.Position, // pos is read-only acces as we are requesting the value, you can also request a const ptr as read-only
            },
            // include types:
            .{
                // Any query result must have the following components, but they wont be included in the result struct
                Component.HeartOrgan,
            },
            // exclude types:
            .{
                // Exclude any entity with the following component
                Component.DeadTag,
            },
        );
    };

    // Lets create an entity that will be a result in a 'Living' query
    const my_living_entity = try storage.createEntity(.{
        Component.Health{ .value = 42 },
        Component.Position{},
        Component.HeartOrgan{},
    });

    // You can unset components (remove)
    storage.unsetComponents(my_living_entity, .{Component.Health});

    // We can check if entity has component
    std.debug.assert(storage.hasComponents(my_living_entity, .{Component.Health}) == false);

    // We can set components (add or reassign)
    try storage.setComponents(my_living_entity, .{Component.Health{ .value = 50 }});

    // Using query example:
    {
        var living_iter = try Queries.Living.submit(allocator, &storage);
        defer living_iter.deinit(allocator);
        while (living_iter.next()) |item| {
            // Item is the type submitted in the query. In this case it will have 'health' which is pointer to Component.Health
            // and a member 'pos' which is a Component.Position value.

            // We can mutate health since the query result item has pointer to health component
            item.health.value += 0.5;

            std.debug.print("{d}\n", .{item.health.value});
        }
    }

    // You can define subsets of the storage.
    // This is used to track what components systems will read/write
    const StorageSubset = Storage.Subset(
        .{
            *Component.Position, // Request Position by pointer access (subset has write and read access for this type)
            *Component.Velocity, // Also request velocity with write access
            Component.Health, // Request Health by value only (subset has read only access for this type)
        },
    );

    // You can send data to systems through event arguments
    const MouseEvent = struct {
        x: u32,
        y: u32,
    };

    const Systems = struct {
        // System arguments can have queries (Notice it must be pointer to query)
        pub fn iterateLiving(living_query: *Queries.Living) void {
            while (living_query.next()) |item| {
                item.health.value += 0.5;
                std.debug.print("{d}\n", .{item.health.value});
            }
        }

        // Systems can also have multiple query arguments, and Storage.Subsets
        pub fn spawnLivingTrail(living_query: *Queries.Living, subset: *StorageSubset) void {
            while (living_query.next()) |item| {
                // For each living, create a new entity at the living pos
                const new_entity = subset.createEntity(.{ item.pos, Component.Velocity{} }) catch @panic("oom");

                // we can read health from the storage subset, but no write operation would be allowed (compile error)
                // Write operations include:
                //  - getComponent(s) with health as pointer
                //  - (un)setComponents with health
                //  - createEntity with health
                std.debug.assert(subset.hasComponents(new_entity, .{Component.Health}) == false);
            }
        }

        pub fn handleMouseEvent(living_query: *Queries.Living, mouse_event: MouseEvent) void {
            while (living_query.next()) |item| {
                _ = item;

                std.debug.print("{d} {d}\n", .{ mouse_event.x, mouse_event.y });
            }
        }
    };

    // We also define a scheduler to execute systems on
    // A ecez scheduler consist of Events:
    const MyFirstEvent = ecez.Event(
        // A name is given, this will be used to dispatch a given event
        "myFirstEvent",
        // A tuple of systems is then given. These will be dispatched in the given order (top to bottom),
        // However they may run in parrallel if there is limited dependencies between them.
        .{
            Systems.iterateLiving,
            Systems.spawnLivingTrail,
            Systems.handleMouseEvent,
        },
    );

    // Scheduler can have multiple events ...
    const MySecondEvent = ecez.Event(
        "mySecondEvent",
        .{
            Systems.iterateLiving,
            Systems.spawnLivingTrail,
            Systems.handleMouseEvent,
        },
    );

    // Create a scheduler type with our events
    const Scheduler = ecez.CreateScheduler(.{
        MyFirstEvent,
        MySecondEvent,
    });

    // Initialize a instance of our Scheduler type
    var scheduler = try Scheduler.init(.{
        .pool_allocator = allocator,
        .query_submit_allocator = allocator,
    });
    defer scheduler.deinit();

    // Remember that one of our systems request MouseEvent which was not a component, but an EventArgument
    const mouse_event = MouseEvent{ .x = 99, .y = 98 };

    // disaptch our first event which we name "myFirstEvent"
    scheduler.dispatchEvent(&storage, .myFirstEvent, mouse_event);

    // events are async, so we must wait for it to complete
    scheduler.waitEvent(.myFirstEvent);

    // Like the first event we can also dispatch our second event
    scheduler.dispatchEvent(&storage, .mySecondEvent, mouse_event);
    scheduler.waitEvent(.mySecondEvent);

    // serialize the storage into a slice of bytes
    const bytes = try ezby.serialize(allocator, Storage, storage, .{});
    defer allocator.free(bytes);

    // nuke the storage for fun
    storage.clearRetainingCapacity();

    // restore the storage state with the slice of bytes which is ezby encoded
    try ezby.deserialize(Storage, &storage, bytes);
}
