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

    // Simple example - demonstrates priority-based workstation selection
    const simple_mod = b.createModule(.{
        .root_source_file = b.path("usage/simple/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    simple_mod.addImport("labelle_tasks", lib_mod);

    const simple_example = b.addExecutable(.{
        .name = "simple_example",
        .root_module = simple_mod,
    });
    b.installArtifact(simple_example);

    const run_simple = b.addRunArtifact(simple_example);
    const simple_step = b.step("simple", "Run the simple example");
    simple_step.dependOn(&run_simple.step);

    // Kitchen example - demonstrates multi-step workflows with priority
    const kitchen_mod = b.createModule(.{
        .root_source_file = b.path("usage/kitchen/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    kitchen_mod.addImport("labelle_tasks", lib_mod);

    const kitchen_example = b.addExecutable(.{
        .name = "kitchen_example",
        .root_module = kitchen_mod,
    });
    b.installArtifact(kitchen_example);

    const run_kitchen = b.addRunArtifact(kitchen_example);
    const kitchen_step = b.step("kitchen", "Run the kitchen example");
    kitchen_step.dependOn(&run_kitchen.step);

    // Abandonment example - demonstrates worker abandonment and task continuation
    const abandonment_mod = b.createModule(.{
        .root_source_file = b.path("usage/abandonment/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    abandonment_mod.addImport("labelle_tasks", lib_mod);

    const abandonment_example = b.addExecutable(.{
        .name = "abandonment_example",
        .root_module = abandonment_mod,
    });
    b.installArtifact(abandonment_example);

    const run_abandonment = b.addRunArtifact(abandonment_example);
    const abandonment_step = b.step("abandonment", "Run the worker abandonment example");
    abandonment_step.dependOn(&run_abandonment.step);

    // Multi-cycle example - demonstrates shouldContinue callback
    const multicycle_mod = b.createModule(.{
        .root_source_file = b.path("usage/systems/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    multicycle_mod.addImport("labelle_tasks", lib_mod);

    const multicycle_example = b.addExecutable(.{
        .name = "multicycle_example",
        .root_module = multicycle_mod,
    });
    b.installArtifact(multicycle_example);

    const run_multicycle = b.addRunArtifact(multicycle_example);
    const multicycle_step = b.step("multicycle", "Run the multi-cycle example");
    multicycle_step.dependOn(&run_multicycle.step);

    // Multi-worker example - demonstrates two workers on two workstations
    const multiworker_mod = b.createModule(.{
        .root_source_file = b.path("usage/engine/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    multiworker_mod.addImport("labelle_tasks", lib_mod);

    const multiworker_example = b.addExecutable(.{
        .name = "multiworker_example",
        .root_module = multiworker_mod,
    });
    b.installArtifact(multiworker_example);

    const run_multiworker = b.addRunArtifact(multiworker_example);
    const multiworker_step = b.step("multiworker", "Run the multi-worker example");
    multiworker_step.dependOn(&run_multiworker.step);

    // Kitchen simulator - interactive game demo
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
    examples_step.dependOn(&run_simple.step);
    examples_step.dependOn(&run_kitchen.step);
    examples_step.dependOn(&run_abandonment.step);
    examples_step.dependOn(&run_multicycle.step);
    examples_step.dependOn(&run_multiworker.step);
}
