const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Get dependencies
    const zspec_dep = b.dependency("zspec", .{
        .target = target,
        .optimize = optimize,
    });

    // Main library module
    const lib_mod = b.addModule("labelle-tasks", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Library artifact
    const lib = b.addLibrary(.{
        .name = "labelle_tasks",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(lib);

    // Unit tests with zspec runner (from test/ folder)
    const test_mod = b.createModule(.{
        .root_source_file = b.path("test/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addImport("zspec", zspec_dep.module("zspec"));
    test_mod.addImport("labelle_tasks", lib_mod);

    const lib_unit_tests = b.addTest(.{
        .root_module = test_mod,
        .test_runner = .{ .path = zspec_dep.path("src/runner.zig"), .mode = .simple },
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);

    // ========================================================================
    // Usage Examples
    // ========================================================================

    // Kitchen simulator - interactive game demo (uses new storage-based API)
    const kitchensim_mod = b.createModule(.{
        .root_source_file = b.path("usage/kitchen-sim/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    kitchensim_mod.addImport("labelle_tasks", lib_mod);

    const kitchensim_example = b.addExecutable(.{
        .name = "kitchen_sim",
        .root_module = kitchensim_mod,
    });
    b.installArtifact(kitchensim_example);

    const run_kitchensim = b.addRunArtifact(kitchensim_example);
    const kitchensim_step = b.step("kitchen-sim", "Run the interactive kitchen simulator");
    kitchensim_step.dependOn(&run_kitchensim.step);

    // Run all examples step
    const examples_step = b.step("examples", "Run all usage examples");
    examples_step.dependOn(&run_kitchensim.step);
}
