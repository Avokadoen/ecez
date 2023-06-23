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

As mentioned, the current state of the API is very much Work in Progress (WIP). The framework is to some degree functional and can be played with. Current *implemented* features are

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

try world.triggerEvent(.update_loop, .{}, .{});

// Trigger event can take event "scoped" arguments, like here where we include a mouse event.
// Events can also exclude components when executing systems. In this example we will not call
// "fireWandSystem" on any entity components if the entity has a MonsterTag component.
try world.triggerEvent(.on_mouse_click, .{@as(MouseArg, mouse)}, .{ MonsterTag });

```

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


### Multithreading is done through [zjobs](https://github.com/michal-z/zig-gamedev/tree/main/libs/zjobs)

zjobs is as the name suggest a job based multithreading API. 

### Tracy integration using [ztracy](https://github.com/michal-z/zig-gamedev/tree/main/libs/ztracy)
![ztracy](media/ztracy.png)

The codebase has integration with tracy to allow both the library itself, but also applications to profile using a [tracy client](https://github.com/wolfpld/tracy). There is also a wrapper allocator called [TracyAllocator](https://github.com/Avokadoen/ecez/blob/main/src/tracy_alloc.zig) which allows tracy to report on memory usage if the application opts in to it. The extra work done by tracy is of course NOPs in builds without tracy!


### Example

Currently the project has one simple example in the [example folder](https://github.com/Avokadoen/ecez/tree/main/examples) which is an implementation of [conway's game of life](https://github.com/Avokadoen/ecez/blob/main/examples/game-of-life/main.zig) which also integrate tracy

### Test Driven Development

The codebase also utilize TDD to ensure a certain level of robustness, altough I can assure you that there are many bugs to find yet! ;)

### Planned

Please see the issues for planned features.

