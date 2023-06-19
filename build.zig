const std = @import("std");
const ztracy = @import("deps/ztracy/build.zig");
const zjobs = @import("deps/zjobs/build.zig");

/// Links a project exe with ecez and optinally enable ztracy
/// The exe may also link with tracy and zjobs by setting link_ecez_dependencies
pub fn link(b: *std.Build, exe: *std.Build.LibExeObjStep, link_ecez_dependencies: bool, enable_tracy: bool) void {
    var ztracy_package = ztracy.package(b, .{ .options = .{ .enable_ztracy = enable_tracy } });

    var zjobs_package = zjobs.package(b, .{});

    const ecez_module = b.createModule(std.Build.CreateModuleOptions{
        .source_file = .{ .path = thisDir() ++ "/src/main.zig" },
        .dependencies = &[_]std.Build.ModuleDependency{ .{
            .name = "ztracy",
            .module = ztracy_package.module,
        }, .{
            .name = "zjobs",
            .module = zjobs_package.module,
        } },
    });
    exe.addModule("ecez", ecez_module);

    if (link_ecez_dependencies) {
        exe.addModule("ztracy", ztracy_package.module);
        ztracy.link(exe, .{ .enable_ztracy = enable_tracy });

        exe.addModule("zjobs", zjobs_package.module);
    }
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
        });

        main_tests.addModule("ztracy", ztracy_package.module);
        ztracy.link(main_tests, .{ .enable_ztracy = enable_tracy });
        main_tests.addModule("zjobs", zjobs_package.module);

        b.installArtifact(main_tests);
    }

    // add library tests to the main tests
    const main_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/main.zig" },
        .optimize = mode,
    });

    main_tests.addModule("ztracy", ztracy_package.module);
    ztracy.link(main_tests, .{ .enable_ztracy = enable_tracy });
    main_tests.addModule("zjobs", zjobs_package.module);

    // main_tests_step.linkLibrary(lib);
    const test_step = b.step("test", "Run all tests");
    const main_tests_run = b.addRunArtifact(main_tests);
    test_step.dependOn(&main_tests_run.step);

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

    const Example = struct {
        name: []const u8,
        link_libc: bool,
    };

    inline for ([_]Example{
        .{ .name = "game-of-life", .link_libc = false },
        .{ .name = "benchmark-instantiate-similar", .link_libc = true },
    }) |example| {
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

        if (example.link_libc) {
            exe.linkLibC();
        }

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

        ztracy.link(example_tests, .{ .enable_ztracy = enable_tracy });
        test_step.dependOn(&example_tests.step);
    }
}

inline fn thisDir() []const u8 {
    return comptime std.fs.path.dirname(@src().file) orelse ".";
}
