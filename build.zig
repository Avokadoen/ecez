const std = @import("std");
const ztracy = @import("deps/ztracy/build.zig");
const zjobs = @import("deps/zjobs/build.zig");

const Example = struct {
    name: []const u8,
};

/// Links a project exe with ecez and optinally ztracy
pub fn link(b: *std.Build, exe: *std.Build.LibExeObjStep, enable_ztracy: bool) void {
    var ztracy_package = ztracy.package(b, .{ .enable_ztracy = enable_ztracy });

    var zjobs_module = zjobs.getModule(b);

    const ecez_module = b.createModule("ecez", std.Build.CreateModuleOptions{
        .source_file = .{ .path = "src/main.zig" },
        .dependencies = &[_]std.Build.ModuleDependency{ .{
            .name = "ztracy",
            .module = ztracy_package.module,
        }, .{
            .name = "zjobs",
            .module = zjobs_module,
        } },
    });
    exe.addModule("ecez", ecez_module);

    ztracy.link(exe, .{ .enable_ztracy = enable_ztracy });
}

/// Builds the project for testing and to run simple examples
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardOptimizeOption(.{});

    // initialize tracy
    const enable_tracy = b.option(bool, "enable-tracy", "Enable Tracy profiler") orelse false;
    var ztracy_package = ztracy.package(b, .{ .options = .{ .enable_ztracy = enable_tracy } });

    var zjobs_package = zjobs.package(b, .{});

    // create a debuggable test executable
    {
        const main_tests = b.addTest(.{
            .name = "main_tests",
            .root_source_file = .{ .path = "src/main.zig" },
            .optimize = mode,
            .kind = .test_exe,
        });

        main_tests.addModule("ztracy", ztracy_package.module);
        ztracy.link(main_tests, .{ .enable_ztracy = enable_tracy });
        main_tests.addModule("zjobs", zjobs_package.module);

        main_tests.install();
    }

    // add library tests to the main tests
    const main_tests_step = b.addTest(.{
        .root_source_file = .{ .path = "src/main.zig" },
        .optimize = mode,
    });

    main_tests_step.addModule("ztracy", ztracy_package.module);
    ztracy.link(main_tests_step, .{ .enable_ztracy = enable_tracy });
    main_tests_step.addModule("zjobs", zjobs_package.module);

    // main_tests_step.linkLibrary(lib);
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&main_tests_step.step);

    var ecez_module = b.createModule(std.Build.CreateModuleOptions{
        .source_file = .{ .path = "src/main.zig" },
        .dependencies = &[_]std.Build.ModuleDependency{ .{
            .name = "ztracy",
            .module = ztracy_package.module,
        }, .{
            .name = "zjobs",
            .module = zjobs_package.module,
        } },
    });

    inline for ([_]Example{.{
        .name = "game-of-life",
    }}) |example| {
        const path = "examples/" ++ example.name ++ "/main.zig";
        var exe = b.addExecutable(.{
            .name = example.name,
            .root_source_file = .{ .path = path },
            .target = target,
            .optimize = mode,
        });

        exe.addModule("ecez", ecez_module);

        exe.addModule("ztracy", ztracy_package.module);
        ztracy.link(exe, .{ .enable_ztracy = enable_tracy });
        exe.addModule("zjobs", zjobs_package.module);

        exe.install();

        const run_step = b.step("run-" ++ example.name, "Run '" ++ example.name ++ "' demo");
        const run_cmd = exe.run();
        run_cmd.step.dependOn(b.getInstallStep());
        run_step.dependOn(&run_cmd.step);

        // add any tests that are define inside each example
        const example_tests = b.addTest(.{
            .root_source_file = .{ .path = path },
            .optimize = mode,
        });
        example_tests.addModule("ecez", ecez_module);

        ztracy.link(example_tests, .{ .enable_ztracy = enable_tracy });
        test_step.dependOn(&example_tests.step);
    }
}

inline fn thisDir() []const u8 {
    return comptime std.fs.path.dirname(@src().file) orelse ".";
}
