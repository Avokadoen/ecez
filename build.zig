const std = @import("std");
const ztracy = @import("deps/ztracy/build.zig");
const zjobs = @import("deps/zjobs/build.zig");

/// Links a project exe with ecez
/// ecez depend on ztracy and zjobs which you can either link manually or with link_ecez_dependencies
pub fn link(
    b: *std.Build,
    exe: *std.Build.LibExeObjStep,
    target: std.zig.CrossTarget,
    mode: std.builtin.Mode,
    link_ecez_dependencies: bool,
    enable_tracy: bool,
) void {
    var ztracy_package = ztracy.package(b, target, mode, .{
        .options = .{ .enable_ztracy = enable_tracy },
    });
    var zjobs_package = zjobs.package(b, target, mode, .{});

    const ecez_module = b.createModule(std.Build.CreateModuleOptions{
        .source_file = .{ .path = thisDir() ++ "/src/main.zig" },
        .dependencies = &[_]std.Build.ModuleDependency{ .{
            .name = "ztracy",
            .module = ztracy_package.ztracy,
        }, .{
            .name = "zjobs",
            .module = zjobs_package.zjobs,
        } },
    });
    exe.addModule("ecez", ecez_module);

    if (link_ecez_dependencies) {
        ztracy_package.link(exe);
        zjobs_package.link(exe);
    }
}

/// Builds the project for testing and to run simple examples
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardOptimizeOption(.{});

    // initialize tracy
    const enable_tracy = b.option(bool, "enable-tracy", "Enable Tracy profiler") orelse false;
    var ztracy_package = ztracy.package(b, target, mode, .{ .options = .{
        .enable_ztracy = enable_tracy,
    } });
    var zjobs_package = zjobs.package(b, target, mode, .{});

    // create a debuggable test executable
    {
        const main_tests = b.addTest(.{
            .name = "main_tests",
            .root_source_file = .{ .path = "src/main.zig" },
            .optimize = mode,
        });

        ztracy_package.link(main_tests);
        zjobs_package.link(main_tests);

        b.installArtifact(main_tests);
    }

    // add library tests to the main tests
    const main_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/main.zig" },
        .optimize = mode,
    });

    ztracy_package.link(main_tests);
    zjobs_package.link(main_tests);

    // main_tests_step.linkLibrary(lib);
    const test_step = b.step("test", "Run all tests");
    const main_tests_run = b.addRunArtifact(main_tests);
    test_step.dependOn(&main_tests_run.step);

    const ecez_module = b.createModule(std.Build.CreateModuleOptions{
        .source_file = .{ .path = "src/main.zig" },
        .dependencies = &[_]std.Build.ModuleDependency{ .{
            .name = "ztracy",
            .module = ztracy_package.ztracy,
        }, .{
            .name = "zjobs",
            .module = zjobs_package.zjobs,
        } },
    });

    const Example = struct {
        name: []const u8,
    };

    inline for ([_]Example{.{
        .name = "game-of-life",
    }}) |example| {
        const path = "examples/" ++ example.name ++ "/main.zig";
        const exe = b.addExecutable(.{
            .name = example.name,
            .root_source_file = .{ .path = path },
            .target = target,
            .optimize = mode,
        });

        // link ecez
        link(b, exe, target, mode, true, enable_tracy);

        b.installArtifact(exe);

        const run_step = b.step("run-" ++ example.name, "Run '" ++ example.name ++ "' demo");
        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());
        run_step.dependOn(&run_cmd.step);

        // add any tests that are define inside each example
        const example_tests = b.addTest(.{
            .root_source_file = .{ .path = path },
            .optimize = mode,
        });

        example_tests.addModule("ecez", ecez_module);
        ztracy_package.link(example_tests);
        zjobs_package.link(example_tests);

        const example_test_run = b.addRunArtifact(example_tests);
        test_step.dependOn(&example_test_run.step);
    }
}

inline fn thisDir() []const u8 {
    return comptime std.fs.path.dirname(@src().file) orelse ".";
}
