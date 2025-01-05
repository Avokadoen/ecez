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

You should also checkout [src/main.zig](https://github.com/Avokadoen/ecez/blob/main/src/main.zig) which has the public API. From there you can follow the deifinition to get more details.

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

https://github.com/Avokadoen/ecez/blob/c0d43e4e1f847d5de1a8a0988abf30ac419f280a/examples/readme/main.zig#L1-L153

### System arguments

Systems can take 3 argument types:
 * Queries - Storage queries requesting a certain entity composition. T
 * Storage.Subset - A subset of the storage. This is just the normal storage with limitations on which 
    components can be touched. You can create entities, (un)set components .. etc
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

https://github.com/Avokadoen/ecez/blob/c0d43e4e1f847d5de1a8a0988abf30ac419f280a/examples/readme/main.zig#L143-L153

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

