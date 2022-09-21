const std = @import("std");
const ztracy = @import("deps/ztracy/build.zig");

const Example = struct {
    name: []const u8,
};

/// Links a project exe with ecez and optinally ztracy
pub fn link(b: *std.build.Builder, exe: *std.build.LibExeObjStep, enable_ztracy: bool) void {
    const ztracy_options = ztracy.BuildOptionsStep.init(b, .{ .enable_ztracy = enable_ztracy });
    const ztracy_pkg = ztracy.getPkg(&.{ztracy_options.getPkg()});

    const ecez_package = std.build.Pkg{
        .name = "ecez",
        .source = .{ .path = thisDir() ++ "/src/main.zig" },
        .dependencies = &[_]std.build.Pkg{ztracy_pkg},
    };

    // add ztracy or a stub if disabled
    exe.addPackage(ztracy_pkg);
    ztracy.link(exe, ztracy_options);

    exe.addPackage(ecez_package);
}

/// Builds the project for testing and to run simple examples
pub fn build(b: *std.build.Builder) void {
    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();

    // we force stage 1 until certain issues have been resolved
    // see issue: https://github.com/ziglang/zig/issues/12521
    b.use_stage1 = true;

    // initialize tracy
    const ztracy_enable = b.option(bool, "enable-tracy", "Enable Tracy profiler") orelse false;
    const ztracy_options = ztracy.BuildOptionsStep.init(b, .{ .enable_ztracy = ztracy_enable });
    const ztracy_pkg = ztracy.getPkg(&.{ztracy_options.getPkg()});

    // const ecez_package = std.build.Pkg{
    //     .name = "ecez",
    //     .source = .{ .path = "src/main.zig" },
    //     .dependencies = &[_]std.build.Pkg{ztracy_pkg},
    // };

    const lib = b.addStaticLibrary("ecez", "src/main.zig");
    lib.setBuildMode(mode);
    lib.addPackage(ztracy_pkg);
    ztracy.link(lib, ztracy_options);
    lib.install();

    // add library tests to the main tests
    const main_tests = b.addTestExe("main_tests", "src/main.zig");
    main_tests.setBuildMode(mode);
    main_tests.addPackage(ztracy_pkg);
    ztracy.link(main_tests, ztracy_options);
    main_tests.linkLibrary(lib);
    main_tests.install();

    {
        const main_tests_step = b.addTest("src/main.zig");
        main_tests_step.setBuildMode(mode);
        main_tests_step.addPackage(ztracy_pkg);
        ztracy.link(main_tests_step, ztracy_options);
        main_tests_step.linkLibrary(lib);
        const test_step = b.step("test", "Run all tests");
        test_step.dependOn(&main_tests_step.step);
    }

    // const target = b.standardTargetOptions(.{});
    // inline for ([_]Example{.{
    //     .name = "game-of-life",
    // }}) |example| {
    //     const path = "examples/" ++ example.name ++ "/main.zig";
    //     var exe = b.addExecutable(example.name, path);
    //     exe.setTarget(target);
    //     exe.setBuildMode(mode);

    //     exe.addPackage(ztracy_pkg);
    //     ztracy.link(exe, ztracy_options);

    //     exe.addPackage(ecez_package);

    //     exe.install();

    //     const run_step = b.step("run-" ++ example.name, "Run '" ++ example.name ++ "' demo");
    //     const run_cmd = exe.run();
    //     run_cmd.step.dependOn(b.getInstallStep());
    //     run_step.dependOn(&run_cmd.step);

    //     // add any tests that are define inside each example
    //     const example_tests = b.addTest(path);
    //     example_tests.setBuildMode(mode);
    //     example_tests.addPackage(ztracy_pkg);
    //     ztracy.link(example_tests, ztracy_options);
    //     test_step.dependOn(&example_tests.step);
    // }
}

inline fn thisDir() []const u8 {
    return comptime std.fs.path.dirname(@src().file) orelse ".";
}
