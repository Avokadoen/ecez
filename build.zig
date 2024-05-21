const std = @import("std");

/// Generate documentation if the user requests it
pub fn doc(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const autodoc_test = b.addObject(.{
        .name = "ecez",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    const install_docs = b.addInstallDirectory(.{
        .source_dir = autodoc_test.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "doc/ecez",
    });

    const docs_step = b.step("docs", "Build and install documentation");
    docs_step.dependOn(&install_docs.step);
}

/// Builds the project for testing and to run simple examples
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // initialize tracy
    const enable_tracy = b.option(bool, "enable_tracy", "Enable Tracy profiler") orelse false;

    const ztracy = b.dependency("ztracy", .{
        .enable_ztracy = enable_tracy,
        .enable_fibers = true,
    });
    const zjobs = b.dependency("zjobs", .{});

    const imports = [_]std.Build.Module.Import{ .{
        .name = "ztracy",
        .module = ztracy.module("root"),
    }, .{
        .name = "zjobs",
        .module = zjobs.module("root"),
    } };

    const ecez = b.addModule("ecez", std.Build.Module.CreateOptions{
        .root_source_file = .{ .path = "src/main.zig" },
        .imports = &imports,
    });

    // create a debuggable test executable
    {
        const main_tests = b.addTest(.{
            .name = "main_tests",
            .root_source_file = .{ .path = "src/main.zig" },
            .optimize = optimize,
        });

        main_tests.root_module.addImport("ecez", ecez);
        main_tests.root_module.addImport("zjobs", zjobs.module("root"));
        main_tests.root_module.addImport("ztracy", ztracy.module("root"));

        b.installArtifact(main_tests);
    }

    // generate documentation on demand
    doc(b, target, optimize);

    // add library tests to the main tests
    const main_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/main.zig" },
        .optimize = optimize,
    });

    main_tests.root_module.addImport("ecez", ecez);
    main_tests.root_module.addImport("zjobs", zjobs.module("root"));
    main_tests.root_module.addImport("ztracy", ztracy.module("root"));

    const test_step = b.step("test", "Run all tests");
    const main_tests_run = b.addRunArtifact(main_tests);
    test_step.dependOn(&main_tests_run.step);

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
            .optimize = optimize,
        });

        exe.root_module.addImport("ecez", ecez);
        exe.root_module.addImport("zjobs", zjobs.module("root"));
        exe.root_module.addImport("ztracy", ztracy.module("root"));
        exe.linkLibrary(ztracy.artifact("tracy"));

        b.installArtifact(exe);

        const run_step = b.step("run-" ++ example.name, "Run '" ++ example.name ++ "' demo");
        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());
        run_step.dependOn(&run_cmd.step);

        // add any tests that are define inside each example
        const example_tests = b.addTest(.{
            .root_source_file = .{ .path = path },
            .optimize = optimize,
        });

        example_tests.root_module.addImport("ecez", ecez);
        example_tests.root_module.addImport("zjobs", zjobs.module("root"));
        example_tests.root_module.addImport("ztracy", ztracy.module("root"));

        const example_test_run = b.addRunArtifact(example_tests);
        test_step.dependOn(&example_test_run.step);
    }
}
