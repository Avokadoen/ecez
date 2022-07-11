const std = @import("std");
const ztracy = @import("deps/ztracy/build.zig");

const Example = struct {
    name: []const u8,
};

pub const EcezPackage = std.build.Pkg{
    .name = "ecez",
    .source = .{ .path = "src/main.zig" },
    .dependencies = null,
};

pub fn build(b: *std.build.Builder) void {
    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();

    // initialize tracy
    const ztracy_enable = b.option(bool, "ztracy-enable", "Enable Tracy profiler") orelse false;
    const ztracy_options = ztracy.BuildOptionsStep.init(b, .{ .enable_ztracy = ztracy_enable });
    const ztracy_pkg = ztracy.getPkg(&.{ztracy_options.getPkg()});

    const lib = b.addStaticLibrary("ecez", "src/main.zig");
    lib.setBuildMode(mode);
    lib.install();

    // add library tests to the main tests
    const main_tests = b.addTest("src/main.zig");
    main_tests.setBuildMode(mode);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&main_tests.step);

    const target = b.standardTargetOptions(.{});
    inline for ([_]Example{.{
        .name = "game-of-life",
    }}) |example| {
        const path = "examples/" ++ example.name ++ "/main.zig";
        var exe = b.addExecutable(example.name, path);
        exe.setTarget(target);
        exe.setBuildMode(mode);
        exe.addPackage(EcezPackage);

        // link tracy
        exe.addPackage(ztracy_pkg);
        ztracy.link(exe, ztracy_options);

        exe.install();

        const run_step = b.step("run-" ++ example.name, "Run '" ++ example.name ++ "' demo");
        const run_cmd = exe.run();
        run_cmd.step.dependOn(b.getInstallStep());
        run_step.dependOn(&run_cmd.step);

        // add any tests that are define inside each example
        const example_tests = b.addTest(path);
        example_tests.setBuildMode(mode);
        test_step.dependOn(&example_tests.step);
    }
}
