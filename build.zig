const std = @import("std");

/// Generate documentation if the user requests it
pub fn doc(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const autodoc_test = b.addObject(.{
        .name = "ecez",
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const install_doc = b.addInstallDirectory(.{
        .source_dir = autodoc_test.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "doc",
    });

    const doc_step = b.step("doc", "Build and install documentation");
    doc_step.dependOn(&install_doc.step);
}

/// Builds the project for testing and to run simple examples
pub fn build(b: *std.Build) void {
    const options = .{
        .enable_ztracy = b.option(
            bool,
            "enable_ztracy",
            "Enable Tracy profile markers",
        ) orelse false,
        .enable_ecez_dev_markers = b.option(
            bool,
            "enable_ecez_dev_markers",
            "Enable Tracy profile markers added by ecez internally, should be false for most projects",
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

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const options_module = make_options_mod_blk: {
        const options_step = b.addOptions();
        options_step.addOption(bool, "enable_ztracy", options.enable_ztracy);
        options_step.addOption(bool, "enable_ecez_dev_markers", options.enable_ecez_dev_markers);
        break :make_options_mod_blk options_step.createModule();
    };

    const root_path = b.path("src/root.zig");
    const ecez_module = b.addModule("ecez", .{
        .root_source_file = root_path,
        .target = target,
        .optimize = optimize,
    });
    ecez_module.addImport("ecez_options", options_module);

    const ztracy_dep = b.dependency("ztracy", .{
        .enable_ztracy = options.enable_ztracy,
        .enable_fibers = options.enable_fibers,
        .on_demand = options.on_demand,
    });
    const ztracy_module = ztracy_dep.module("root");
    const ztracy_artifact = ztracy_dep.artifact("tracy");

    ecez_module.addImport("ztracy", ztracy_module);

    // create a debuggable test executable
    {
        const root_tests = b.addTest(.{
            .name = "root_tests",
            .root_source_file = root_path,
            .target = target,
            .optimize = optimize,
        });

        root_tests.root_module.addImport("ecez", ecez_module);
        root_tests.root_module.addImport("ztracy", ztracy_module);
        root_tests.linkLibrary(ztracy_artifact);

        b.installArtifact(root_tests);
    }

    // generate documentation on demand
    doc(b, target, optimize);

    // add library tests to the root tests
    const root_tests = b.addTest(.{
        .root_source_file = root_path,
        .optimize = optimize,
    });

    root_tests.root_module.addImport("ecez", ecez_module);
    root_tests.root_module.addImport("ztracy", ztracy_module);
    root_tests.linkLibrary(ztracy_artifact);

    const test_step = b.step("test", "Run all tests");
    const root_tests_run = b.addRunArtifact(root_tests);
    test_step.dependOn(&root_tests_run.step);

    const Example = struct {
        name: []const u8,
    };

    inline for ([_]Example{
        .{ .name = "game-of-life" },
        .{ .name = "readme" },
    }) |example| {
        const path = b.path("examples/" ++ example.name ++ "/main.zig");
        const exe = b.addExecutable(.{
            .name = example.name,
            .root_source_file = path,
            .target = target,
            .optimize = optimize,
        });

        exe.root_module.addImport("ecez", ecez_module);
        exe.root_module.addImport("ztracy", ztracy_module);
        exe.linkLibrary(ztracy_artifact);

        b.installArtifact(exe);

        const run_step = b.step("run-" ++ example.name, "Run '" ++ example.name ++ "' demo");
        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());
        run_step.dependOn(&run_cmd.step);

        // add any tests that are define inside each example
        const example_tests = b.addTest(.{
            .root_source_file = path,
            .target = target,
            .optimize = optimize,
        });

        example_tests.root_module.addImport("ecez", ecez_module);
        example_tests.root_module.addImport("ztracy", ztracy_module);
        example_tests.linkLibrary(ztracy_artifact);

        const example_test_run = b.addRunArtifact(example_tests);
        test_step.dependOn(&example_test_run.step);
    }
}
