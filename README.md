![Test](https://github.com/Avokadoen/ecez/actions/workflows/test.yaml/badge.svg) [![Zig changes watch](https://github.com/Avokadoen/ecez/actions/workflows/cron.yaml/badge.svg)](https://github.com/Avokadoen/ecez/actions/workflows/cron.yaml)

# ECEZ - An ECS API

This is a ECS (Entity Component System) API for Zig.

## Try it yourself!

### Requirements

The [zig compiler 0.13.0](https://ziglang.org)

You can use zigup to easily get this specific version

### Steps
Run the following commands
```bash
# Clone the repo
git clone https://github.com/Avokadoen/ecez.git
# Run tests
zig build test
# Run GOL example, use '-Denable-tracy=true' at the end to add tracy functionality
zig build run-game-of-life 

```

## Zig documentation

You can generate the ecez API documentation using `zig build docs`. This will produce some web resources in `zig-out/doc/ecez`. 
You will need a local server to serve the documentation since browsers will block resources loaded by the index.html. 

The simplest solution to this is just using a basic python server:
```bash
python -m http.server 8000 -d ecez/zig-out/doc/ecez # you can then access the documentation at http://localhost:8000/#ecez.main 
```

## Features

### Compile time based and type safe API
Zig's comptime feature is utilized to perform static reflection on the usage of the API to validate usage and report useful messages to the user (in theory :)). 

```zig
    // We start by defining some components
    const Component = struct {
        pub const Health = struct {
            value: f32,
        };
        pub const DeadTag = struct {};
        pub const Weapon = struct {};
        pub const Position = struct {};
        pub const Velocity = struct {};
    };

    // Given a set of components, we can store them in a storage defined by the component set.
    const Storage = ecez.CreateStorage(.{
        Component.Health,
        Component.DeadTag,
        Component.Weapon,
        Component.Position,
        Component.Velocity,
    });

    // Initialize our storage
    var storage = try Storage.init(allocator);
    defer storage.deinit();

    // We can then define queries on the storage. These can be used to iterate entities with certain components-
    const Queries = struct {
        pub const Living = Storage.Query(
            // Any result item will be of this type
            struct { health: *Component.Health, pos: Component.Position },
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
    });

    // You can unset components (remove)
    try storage.unsetComponents(my_living_entity, .{Component.Health});

    // We can check if entity has component
    std.debug.assert(storage.hasComponents(my_living_entity, .{Component.Health}) == false);

    // We can set components (add or reassign)
    try storage.setComponents(my_living_entity, .{Component.Health{ .value = 50 }});

    // Using query example:
    var living_iter = Queries.Living.submit(&storage);
    while (living_iter.next()) |item| {
        // Item is the type submitted in the query. In this case it will have 'health' which is pointer to Component.Health
        // and a member 'pos' which is a Component.Position value.

        // We can mutate health since the query result item has pointer to health component
        item.health.value += 0.5;

        std.debug.print("{d}", .{item.health.value});
    }

    // You can define subsets of the storage.
    // This is used to track what components systems will read/write
    const StorageSubset = struct {
        const PosVelView = Storage.Subset(
            .{
                Component.Position,
                Component.Velocity,
            },
            .read_and_write,
        );
    };

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
                std.debug.print("{d}", .{item.health.value});
            }
        }

        // Systems can also have multiple query arguments, and Storage.Subsets
        pub fn spawnLivingTrail(living_query: *Queries.Living, pos_vel_view: *StorageSubset.PosVelView) void {
            while (living_query.next()) |item| {
                // For each living, create a new entity at the living pos
                _ = pos_vel_view.createEntity(.{ item.pos, Component.Velocity{} }) catch @panic("oom");
            }
        }

        pub fn handleMouseEvent(living_query: *Queries.Living, mouse_event: MouseEvent) void {
            while (living_query.next()) |item| {
                _ = item;

                std.debug.print("{d} {d}\n", .{ mouse_event.x, mouse_event.y });
            }
        }
    };

    // Like a storage, we can define a scheduler. This will execute systems on multiple threads.
    // The scheduler tracks all reads and writes done on the components in order to safetly do this without race hazards.
    var scheduler = try ecez.CreateScheduler(.{ecez.Event(
        "myFirstEvent",
        .{
            Systems.iterateLiving,
            Systems.spawnLivingTrail,
            Systems.handleMouseEvent,
        },
    )}).init(allocator, .{});
    defer scheduler.deinit();

    // Remember that one of our systems request MouseEvent which was not a component, but an EventArgument
    const mouse_event = MouseEvent{ .x = 99, .y = 98 };

    // disaptch our first event which we name "myFirstEvent"
    scheduler.dispatchEvent(&storage, .myFirstEvent, mouse_event);

    // events are async, so we must wait for it to complete
    scheduler.waitEvent(.myFirstEvent);
```

### System arguments

Systems can take 3 argument types:
 * Queries - Storage queries requesting a certain entity composition. T
 * Storage.Subset - A subset of the storage. This is just the normal storage with limitations on which components can be touched. You can create entities, (un)set components .. etc
 * EventArgument - Any non query or subset. Can be useful as a "context" for the event

### Implicit multithreading of systems

When you trigger a system dispatch or an event with multiple systems then ecez will schedule this work over multiple threads. 
Synchronization is handled by ecez although there are some caveats that you should be aware of:

 * Dont request write access (query result members that are of pointer type) unless you need it.
    * Writes has more limitations on what can run in parallel 
 * Be specific, only request the types you will use.
 * EventArgument will not be considered when synchronizing. This means that if you mutate an event argument then you must take some care in order to ensure legal behaviour
 

### Serialization through the ezby format

ecez uses a custom byte format to convert storages into a slice of bytes.

#### Example

```zig
const ecez = @import("ecez");
const ezby = ecez.ezby;

// ... create storage and some entities with components ...

// serialize the storage into a slice of bytes
const bytes = try ezby.serialize(StorageType, testing.allocator, storage, .{});
defer testing.allocator.free(bytes);

// nuke the storage for fun
storage.clearRetainingCapacity();

// restore the storage state with the slice of bytes which is ezby encoded
try ezby.deserialize(StorageType, &storage, bytes);
```

### Tracy integration using [ztracy](https://github.com/michal-z/zig-gamedev/tree/main/libs/ztracy)
![ztracy](media/ztracy.png)

The codebase has integration with tracy to allow both the library itself, but also applications to profile using a [tracy client](https://github.com/wolfpld/tracy). There is also a wrapper allocator called [TracyAllocator](https://github.com/Avokadoen/ecez/blob/main/src/tracy_alloc.zig) which allows tracy to report on memory usage if the application opts in to it. The extra work done by tracy is of course NOPs in builds without tracy!


### Demo/Examples

Currently the project has two simple examples in the [example folder](https://github.com/Avokadoen/ecez/tree/main/examples):
 * Implementation of [conway's game of life](https://github.com/Avokadoen/ecez/blob/main/examples/game-of-life/main.zig) which also integrate tracy
 * The code from this [readme](https://github.com/Avokadoen/ecez/blob/main/examples/readme/main.zig)

### Test Driven Development

The codebase also utilize TDD to ensure a certain level of robustness, altough I can assure you that there are many bugs to find yet! ;)

### Planned

Please see the issues for planned features.

