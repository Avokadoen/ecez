![Test](https://github.com/Avokadoen/ecez/actions/workflows/test.yaml/badge.svg) [![Zig changes watch](https://github.com/Avokadoen/ecez/actions/workflows/cron.yaml/badge.svg)](https://github.com/Avokadoen/ecez/actions/workflows/cron.yaml)

# ECEZ - An archetype based ECS API

This is a opinionated WIP ECS (Entity Component System) API for Zig.

## Try it yourself!

### Requirements

The [master branch zig compiler](https://ziglang.org/download/)

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

## Features

As mentioned, the current state of the API is very much Work in Progress (WIP). The framework is to some degree functional and can be played with. Current *implemented* features are:

### Compile time based and type safe API
Zig's comptime feature is utilized to perform static reflection on the usage of the API to validate usage and report useful messages to the user (in theory :)). 

```zig
var world = try ecez.WorldBuilder().WithComponents(.{
        // register your game components using WithComponents
        Health, 
        Attributes,
        Chest,
        Weapon,
        Blunt,
        Sharp,
        // ...
    }).WithEvents(.{
        Event("update_loop", .{
            // register your game systems using WithSystems
            // Here AttackSystems is a struct with multiple functions which will be registered
            AttackSystems,
            // moveSystem is a single function that will be registered 
            moveSystem,
            // ...
        }, .{}),
        Event("on_mouse_click", .{fireWandSystem}, .{MouseArg})
    }).init(allocator, .{});

world.triggerEvent(.update_loop, .{}, .{});

// Trigger event can take event "scoped" arguments, like here where we include a mouse event.
// Events can also exclude components when executing systems. In this example we will not call
// "fireWandSystem" on any entity components if the entity has a MonsterTag component.
world.triggerEvent(.on_mouse_click, .{@as(MouseArg, mouse)}, .{ MonsterTag });

```

#### Special system arguments

Systems can have arguments that has a unique semantical meaning.
Currently there are 3 special arguments:
 * Entity - give the system access to the current entity
 * EventArgument - data that is relevant to an triggered event
 * SharedState - data that is global to the world instance

 ##### Examples 

Example of EventArgument
```zig
    const MouseMove = struct { x: u32, y: u32,  };
    const OnMouseMove = struct {
        // We see the argument annotated by EventArgument which hints ecez that this will be supplied on trigger
        pub fn system(thing: *ThingThatCares, mouse: EventArgument(MouseMove)) void {
            thing.value = mouse.x + mouse.y;
        }
    };

    var world = try WorldBuilder().WithComponents(...).WithEvents(.{
        // We include the inner type of the EventArgument when we register the event
        Event("onMouseMove", .{OnMouseMove}, MouseMove),
    }).init(testing.allocator, .{});

    // register some entities with ThingThatCares component ...

    // As the event is triggered we supply event specific data
    world.triggerEvent(.onMouseMove, MouseMove{ .x = 40, .y = 2 }, .{});
```

Example of SharedState
```zig
    const OnKill = struct {
        pub fn system(health: Health, kill_counter: *SharedState(KillCounter)) void {
            health = 0;
            kill_counter.count += 1;
        }
    };

    const World = try WorldBuilder().WithComponents(...).WithEvents(.{
        // We include the inner type of the EventArgument when we register the event
        Event("onKill", .{OnKill}, .{}),
    });
```

Example of Entity
```zig
    const System = struct {
        pub fn system(entity: Entity, health: Health) void {
            // ...
        }
    };
```

Both SharedState and EventArgument can be mutable by using a pointer


#### System restrictions

There are some restrictions to how you can define systems:
 * If the system takes the current entity argument, then the entity must be the *first* argument
 * Components must come *before* special arguments (event data and shared data, but not entity)
    * Event data and shared data must come *after* any component or entity argument

### Implicit multithreading of systems

When you trigger a system dispatch or an event with multiple systems then ecez will schedule this work over multiple threads. This has implications on how you use systems.
You can use the ``DependOn`` function to communicate order of system execution. 

#### Example:
```zig
var world = try ecez.WorldBuilder().WithComponents(.{
        Drag,
        Velocity,
        Position,
        HelloWorldMsg,
        // ...
    }).WithEvents(.{
        Event("update_loop", .{
            // here we see that 'calculateDamage', 'printHelloWorld' and 'applyDrag'
            // can be executed in parallel
            Systems.calculateDamage,
            Systems.printHelloWorld,
            // Apply drag reduce velocity over time
            Systems.applyDrag,
            // Move moves all entities with a Postion and Velocity component. 
            // We need to make sure any drag has been applied 
            // to a velocity before applying velocity to the position. 
            // We also have to make sure that a new "hello world" is visible in the 
            // terminal as well because why not :)                       
            DependOn(Systems.move, .{Systems.applyDrag, Systems.printHelloWorld})      
        }, .{})
    }).init(allocator, .{});
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

### Queries

You can query the api instance for all components of certain type and filter out instances of said components that also have unwanted sibling components.

#### Example

```zig
const World = ecez.WorldBuilder().WithComponents(.{
    Monsters,
    HappyTag,
    SadTag,
    AngryTag,
    SickTag,
    HealthyTag
    // ...
});

var world = try World.init(allocator, .{});
// .. some construction of your world entites

const include = ecez.query.include;

// we want to iterate over all Monsters, HappyTag and HealthyTag components grouped by entity,
// we filter out all monsters that might have the previously mentioned components if they also have 
// a SadTag or SickTag attached to the same entity
const include_entity_id = false;
var happy_healhy_monster_iter = try World.Query(
    include_entity_id,
    // notice that Monster components will be mutable through pointer semantics
    .{
        // these are our include types
        include("monster", *Monster), 
        include("happy", HappyTag), 
        include("healthy", HealthyTag),
    },
    // these are our exclude types
    .{SadTag, SickTag}
).submit(world, std.testing.allocator);

while (happy_healhy_monster_iter.next()) |happy_healhy_monster| {
    // these monsters are not sick or sad so they become more happy :)
    happy_healhy_monster.monster.mood_rating += 1;
}


if (happy_healhy_monster_iter.at(5)) |fifth_happy_monster| {
    // the 5th monster becomes extra happy! 
    happy_healhy_monster.monster.mood_rating += 1;
}

```

### Tracy integration using [ztracy](https://github.com/michal-z/zig-gamedev/tree/main/libs/ztracy)
![ztracy](media/ztracy.png)

The codebase has integration with tracy to allow both the library itself, but also applications to profile using a [tracy client](https://github.com/wolfpld/tracy). There is also a wrapper allocator called [TracyAllocator](https://github.com/Avokadoen/ecez/blob/main/src/tracy_alloc.zig) which allows tracy to report on memory usage if the application opts in to it. The extra work done by tracy is of course NOPs in builds without tracy!


### Example

Currently the project has one simple example in the [example folder](https://github.com/Avokadoen/ecez/tree/main/examples) which is an implementation of [conway's game of life](https://github.com/Avokadoen/ecez/blob/main/examples/game-of-life/main.zig) which also integrate tracy

### Test Driven Development

The codebase also utilize TDD to ensure a certain level of robustness, altough I can assure you that there are many bugs to find yet! ;)

### Planned

Please see the issues for planned features.

