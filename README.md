![Test](https://github.com/Avokadoen/ecez/actions/workflows/test.yaml/badge.svg) [![Zig changes watch](https://github.com/Avokadoen/ecez/actions/workflows/cron.yaml/badge.svg)](https://github.com/Avokadoen/ecez/actions/workflows/cron.yaml)

# ECEZ - An archetype based ECS API

This is a opinionated WIP ECS (Entity Component System) API for Zig.

## Try it yourself!

### Requirements

The [zig compiler 0.13.0-dev.351+64ef45eb0](https://ziglang.org)

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

As mentioned, the current state of the API is very much Work in Progress (WIP). The framework is to some degree functional and can be played with. Current *implemented* features are:

### Compile time based and type safe API
Zig's comptime feature is utilized to perform static reflection on the usage of the API to validate usage and report useful messages to the user (in theory :)). 

```zig
    // The Storage simply store entites and their components and expose a query API
    const Storage = ecez.CreateStorage(.{
        Health, 
        Attributes,
        Chest,
        Weapon,
        Blunt,
        Sharp,
        // ...
    }, .{});

    // Scheduler can dispatch systems on multiple threads
    const Scheduler = ecez.CreateScheduler(
        Storage,
        .{
            ecez.Event("update_loop", .{
                // Here AttackSystems is a struct with multiple functions which will be registered
                AttackSystems,
                MoveSystem,
                // ...
            }, .{}),
            ecez.Event("on_mouse_click", .{FireWandSystem}, .{MouseArg}),
        },
    )

    var storage = try Storage.init(testing.allocator, .{});
    defer storage.deinit();

    var scheduler = Scheduler.init();
    defer scheduler.deinit();

    scheduler.dispatchEvent(&storage, .update_loop, .{}, .{});

    // Dispatch event can take event "scoped" arguments, like here where we include a mouse event.
    // Events can also exclude components when executing systems. 
    scheduler.dispatchEvent(&storage, .on_mouse_click, .{@as(MouseArg, mouse)});

    // Events/Systems execute asynchronously
    // You can wait on specific events ...
    scheduler.waitEvent(.update_loop);
    scheduler.waitEvent(.on_mouse_click);
    // .. or all events
    scheduler.waitIdle();

```

#### Special system arguments

Systems can have arguments that have a unique semantical meaning:
 * ExcludeEntitiesWith - Tags components that should be excluded - entities that has said components will not be called with this system
 * Entity - give the system access to the current entity
 * EventArgument - data that is relevant to an triggered event
 * Queries - the same queries described [below](#queries)
 * InvocationCount - how many times the system has been executed for the current dispatch
 * Storage.StorageEditQueue - Any storage type has a StorageEditQueue which can be included as a system argument pointer allowing storage edits

 ##### Examples 

Example of ExcludeEntitiesWith
```zig
    const FindGoodGuys = struct {
        pub fn system(human: *Human, e: meta.ExcludeEntitiesWith(.{ PickNoseTag })) void {
            _ = e;
            std.debug.print("{s} is a good guy!", .{human.name});
        }
    };

    const FindBadGuys = struct {
        pub fn system(human: *Human, tag: PickNoseTag) void {
            _ = tag;
            std.debug.print("{s} is a bad guy!", .{human.name});
        }
    };

    var storage = try StorageStub.init(testing.allocator);
    defer storage.deinit();

    var scheduler = try CreateScheduler(
        StorageStub,
        .{
            Event("find_good_guys", .{FindGoodGuys}, .{}),
            Event("find_bad_guys", .{FindBadGuys}, .{}),
        },
    ).init(testing.allocator, .{});
    defer scheduler.deinit();

    scheduler.dispatchEvent(&storage, .find_good_guys, .{});
    scheduler.waitEvent(.find_good_guys);

    scheduler.dispatchEvent(&storage, .find_bad_guys, .{});
    scheduler.waitEvent(.find_bad_guys);
    
    // no entity with human component will be printed twice!
```


Example of EventArgument
```zig
    const MouseMove = struct { x: u32, y: u32,  };
    const OnMouseMove = struct {
        // system that procces "thing" components by reading event argument "mouse"
        pub fn system(thing: *ThingThatCares, mouse: MouseMove) void {
            thing.value = mouse.x + mouse.y;
        }
    };

    const Scheduler = ecez.CreateScheduler(
        Storage,
        .{
            // We include the inner type of the EventArgument when we register the event
            ecez.Event("onMouseMove", .{OnMouseMove}, MouseMove),
        },
    )
    
    // ...

    // As the event is triggered we supply event specific data
    scheduler.dispatchEvent(&storage, .onMouseMove, MouseMove{ .x = 40, .y = 2 });
```

Example of Entity
```zig
    const System = struct {
        pub fn system(entity: Entity, health: Health) void {
            // ...
        }
    };
```

Example of Query
```zig
    const QueryActiveColliders = StorageStub.Query(
        struct{
            // !entity must be the first field if it exist!
            entity: Entity, 
            position: Position,
            collider: Collider,
        },
        // exclude type
        .{ InactiveTag },
    ).Iter;

    const System = struct {
        // Very bad brute force collision detection with wasted checks (it will check previously checked entities)
        // Hint: other_obj.skip + InvocationCount could be used here to improve the checks ;)
        pub fn system(
            entity: Entity, 
            position: Position, 
            collider: BoxCollider, 
            other_obj: *QueryActiveColliders,
        ) ecez.ReturnCommand {
            while (other_colliders.next()) |other_collider| {
                const is_colliding = // ....;
                if (is_colliding) {
                    return .@"break";
                }              
            }
            return .@"continue";
        }
    };
```

Example of InvocationCount
```zig
    const System = struct {
        pub fn system(health: HealthComponent, count: InvocationCount) void {
            // ...
        }
    };
```

Example of Storage.StorageEditQueue
```zig
const Storage = ecez.CreateStorage(
    .{
        // ... Components
    },
    .{}
);
const System = struct {
    // Keep in mind it *must* be a pointer
    pub fn system(entity: Entity, health: HealthComponent, storage_edit: *Storage.StorageEditQueue) void {
        if (health.value <= 0) {
            storage_edit.queueSetComponent(entity, RagdollComponent);
        }
    }
};

const Scheduler = ecez.CreateScheduler(
    Storage,
    .{
        ecez.Event("onUpdate", .{
            System,
            ecez.FlushEditQueue, // FlushEditQueue will ensure any queued storage work will start & finish 
        }, .{}),
    }
);
```

You can have multiple queries in a single system, and have systems with only query parameters.

EventArgument can be mutable by using a pointer

### System return values

Systems have two valid return types: ``void`` and ``ecez.ReturnCommand``.

``ReturnCommand`` is an enum defined as followed:
```zig

/// Special optional return type for systems that allow systems exit early if needed
pub const ReturnCommand = enum {
    /// System should continue to execute as normal
    @"continue",
    /// System should exit early
    @"break",
};

```


#### System restrictions

There are some restrictions to how you can define systems:
 * If the system takes the current entity argument, then the **entity must be the first argument**
 * **Components must come before special arguments** (event data, but not entity)
    * Event data must come *after* any component or entity argument

### Implicit multithreading of systems

When you trigger a system dispatch or an event with multiple systems then ecez will schedule this work over multiple threads. This has implications on how you use systems.
You can use the ``DependOn`` function to communicate order of system execution. 

#### Example:
```zig
    const Scheduler1 = ecez.CreateScheduler(
        Storage,
        .{
            ecez.Event("update_loop", .{
                // here we see that 'CalculateDamage', 'PrintHelloWorld' and 'ApplyDrag'
                // can be executed in parallel
                CalculateDamage,
                PrintHelloWorld,
                // Apply drag reduce velocity over time
                ApplyDrag,
                // Move moves all entities with a Postion and Velocity component. 
                // We need to make sure any drag has been applied 
                // to a velocity before applying velocity to the position. 
                // We also have to make sure that a new "hello world" is visible in the 
                // terminal as well because why not :)                       
                ecez.DependOn(Move, .{ApplyDrag, PrintHelloWorld}),
            }, .{}),
        },
    );

    // You can also use structs with systems for DependOn
    const Scheduler2 = ecez.CreateScheduler(
        Storage,
        .{
            ecez.Event("update_loop", .{
                // Submit all combat systems in a single struct
                CombatSystemsStruct,
                // Submit all physics systems in a single struct
                PhysicsSystemsStruct,
                // Submit all AI systems, wait for Physics and Combat to complete
                ecez.DependOn(AiSystemsStruct, .{PhysicsSystemsStruct, CombatSystemsStruct}),
            }, .{}),
        },
    );
```


```mermaid
---
title: System execution sequence
---
sequenceDiagram
    % our systems
    participant calculateDamage
    participant printHelloWorld
    participant applyDrag
    participant move

    par move blocked 
        par execute unblocked systems
            calculateDamage->>calculateDamage: 
            printHelloWorld->>printHelloWorld: 
            applyDrag->>applyDrag: 
        end
        applyDrag->>move: applyDrag done
        printHelloWorld->>move: printHelloWorld done
    end
    move->>move: run
```

#### Multithreading is done through [zjobs](https://github.com/michal-z/zig-gamedev/tree/main/libs/zjobs)

zjobs is as the name suggest a job based multithreading API. 

### <a name="queries"></a> Queries

You can query the storage instance for components and filter out instances of components that are paired with unwanted components.

#### Example

```zig
const Storage = ecez.CreateStorage(.{
    Monsters,
    HappyTag,
    SadTag,
    AngryTag,
    SickTag,
    HealthyTag
    // ...
}, .{});

var storage = try Storage.init(allocator, .{});

// .. some construction of your entites

const include = ecez.include;

// we want to iterate over all Monsters, HappyTag and HealthyTag components grouped by entity,
// we filter out all monsters that might have the previously mentioned components if they also have 
// a SadTag or SickTag attached to the same entity
var happy_healhy_monster_iter = Storage.Query(
    // notice that Monster components will be mutable through pointer semantics
    // we query our result by submitting the type we want the resulting items to be
    struct{
        // these are our include types
        entity: Entity,
        monster: *Monster,
        happy_tag: HappyTag,
        healthy: HealthyTag,
    },
    // excluded types are submitted in a tuple of types
    .{SadTag, SickTag}
).submit(&storage);

while (happy_healhy_monster_iter.next()) |happy_healhy_monster| {
    // these monsters are not sick or sad so they become more happy :)
    happy_healhy_monster.monster.mood_rating += 1;
}

happy_healhy_monster_iter.reset();
happy_healhy_monster_iter.skip(5);
if (happy_healhy_monster_iter.next()) |fifth_happy_monster| {
    if (happy_healhy_monster.entity == entity_we_are_looking_for) {
        // the 5th monster becomes extra happy! 
        happy_healhy_monster.monster.mood_rating += 1;
    }
}

```

### Thead safe queuing of storage edits

You can queue edits of the storage from multiple threads, while iterating or as previously mentioned in systems by queuing the edits.

This is done through the storage functions with the `queue*Op*` naming scheme. These functions are thread safe, but the operations queued 
have to be triggered manually with `flushStorageQueue`, unless done through systems in which case the scheduler will do it for you on event completion.

### Serialization through the ezby format

ecez uses a custom byte format to convert storages into a slice of bytes.

There is a loose spec: [ezby spec](byte_format.md)

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

Currently the project has one simple example in the [example folder](https://github.com/Avokadoen/ecez/tree/main/examples) which is an implementation of [conway's game of life](https://github.com/Avokadoen/ecez/blob/main/examples/game-of-life/main.zig) which also integrate tracy

### Test Driven Development

The codebase also utilize TDD to ensure a certain level of robustness, altough I can assure you that there are many bugs to find yet! ;)

### Planned

Please see the issues for planned features.

