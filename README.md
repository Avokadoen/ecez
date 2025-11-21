![Test](https://github.com/Avokadoen/ecez/actions/workflows/test.yaml/badge.svg)

# ECEZ - An ECS API

This is a ECS (Entity Component System) API for Zig.

## Try it yourself!

### Requirements

The [zig compiler 0.15.1](https://ziglang.org)

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

You should also checkout [src/root.zig](https://github.com/Avokadoen/ecez/blob/main/src/root.zig) which has the public API. From there you can follow the deifinition to get more details.

### Include ecez and optionally tracy in your project

Add ecez to build.zig.zon, example in terminal:
```
zig fetch --save git+https://github.com/Avokadoen/ecez.git/#HEAD
```

#### Basic ecez build

build.zig
```zig
const ecez = b.dependency("ecez", .{});
const ecez_module = ecez.module("ecez");
exe.root_module.addImport("ecez", ecez_module);
```

#### Using ztracy with ecez:
build.zig:
```zig
const options = .{
   .enable_ztracy = b.option(
      bool,
      "enable_ztracy",
      "Enable Tracy profile markers",
   ) orelse false,
   .enable_fibers = b.option(
      bool,
      "enable_fibers",
      "Enable Tracy fiber support",
   ) orelse false,
   .on_demand = b.option(
      bool,
      "on_demand",
      "Build tracy with TRACY_ON_DEMAND",
   ) orelse false,
};

// link ecez and ztracy
{
   const ecez = b.dependency("ecez", .{
      .enable_ztracy = options.enable_ztracy,
      .enable_fibers = options.enable_fibers,
      .on_demand = options.on_demand,
   });
   const ecez_module = ecez.module("ecez");

   exe.root_module.addImport("ecez", ecez_module);
   exe_unit_tests.root_module.addImport("ecez", ecez_module);

   const ztracy_dep = ecez.builder.dependency("ztracy", .{
      .enable_ztracy = options.enable_ztracy,
      .enable_fibers = options.enable_fibers,
      .on_demand = options.on_demand,
   });
   const ztracy_module = ztracy_dep.module("root");

   exe.root_module.addImport("ztracy", ztracy_module);
   exe_unit_tests.root_module.addImport("ztracy", ztracy_module);

   exe.linkLibrary(ztracy_dep.artifact("tracy"));
}
```

## Zig documentation

### Prebuilt

You can access prebuilt documentation built from recent main at https://avokadoen.github.io/ecez

### Build yourself
You can generate the ecez API documentation using `zig build doc`. This will produce some web resources in `zig-out/doc`.
You will need a local server to serve the documentation since browsers will block resources loaded by the index.html. 

The simplest solution to this is just using a basic python server:
```bash
python -m http.server 8000 -d ./zig-out/doc # you can then access the documentation at http://localhost:8000/#ecez 
```

## Features

### Compile time based and type safe API
Zig's comptime feature is utilized to perform static reflection on the usage of the API to validate usage and report useful messages to the user (in theory :)). 

https://github.com/Avokadoen/ecez/blob/5d20e77e1760132c99d44f717486bff60252d7c1/examples/readme/main.zig#L13-L217

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

https://github.com/Avokadoen/ecez/blob/5d20e77e1760132c99d44f717486bff60252d7c1/examples/readme/main.zig#L221-L229

### Tracy integration using [ztracy](https://github.com/michal-z/zig-gamedev/tree/main/libs/ztracy)
![ztracy](media/ztracy.png)

The codebase has integration with tracy to allow both the library itself, but also applications to profile using a [tracy client](https://github.com/wolfpld/tracy). The extra work done by tracy is of course NOPs in builds without tracy!


### Demo/Examples

Currently the project has two simple examples in the [example folder](https://github.com/Avokadoen/ecez/tree/main/examples):
 * Implementation of [conway's game of life](https://github.com/Avokadoen/ecez/blob/main/examples/game-of-life/main.zig) which also integrate tracy
 * The code from this [readme](https://github.com/Avokadoen/ecez/blob/main/examples/readme/main.zig)

 There is also [wizard rampage](https://github.com/Avokadoen/wizard_rampage) which is closer to actual game code. This was originally a game jam so some of the code is "hacky" but the ecez usage should be a practical example

### External projects using ecez

There are currently two projects that I know of that use ecez to some extent:

- [Dizc](https://codeberg.org/hubidubi/dizc) A scene containing a hex map, rendering with raylib
- [Lucens](https://github.com/QuentinTessier/Lucens) A custom game engine written in opengl

### Test Driven Development

The codebase also utilize TDD to ensure a certain level of robustness, altough I can assure you that there are many bugs to find yet! ;)

### Planned

Please see the issues for planned features.

