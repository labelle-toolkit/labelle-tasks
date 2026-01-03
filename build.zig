const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Get dependencies
    const zspec_dep = b.dependency("zspec", .{
        .target = target,
        .optimize = optimize,
    });

    // labelle-engine dependency for standalone use and tests
    const engine_dep = b.dependency("labelle-engine", .{
        .target = target,
        .optimize = optimize,
    });
    const engine_mod = engine_dep.module("labelle-engine");
    const ecs_mod = engine_dep.module("ecs");

    // Main module (use underscore for Zig module naming convention)
    // Note: When used as a dependency, the consuming project should use
    // addTasksModule() to provide its own labelle-engine module.
    const tasks_mod = b.addModule("labelle_tasks", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    tasks_mod.addImport("labelle-engine", engine_mod);
    tasks_mod.addImport("ecs", ecs_mod);

    // Core module without ECS dependencies (for tests and simple usage)
    const core_mod = b.addModule("labelle_tasks_core", .{
        .root_source_file = b.path("src/core.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Unit tests with zspec runner (from test/ folder)
    // Uses core module to avoid graphics dependencies
    const test_mod = b.createModule(.{
        .root_source_file = b.path("test/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addImport("zspec", zspec_dep.module("zspec"));
    test_mod.addImport("labelle_tasks", core_mod);

    const unit_tests = b.addTest(.{
        .root_module = test_mod,
        .test_runner = .{ .path = zspec_dep.path("src/runner.zig"), .mode = .simple },
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // Kitchen simulator example (requires graphics libraries, skip in CI)
    const build_examples = b.option(bool, "examples", "Build examples (requires graphics libs)") orelse true;

    if (build_examples) {
        const kitchensim_mod = b.createModule(.{
            .root_source_file = b.path("usage/kitchen-sim/main.zig"),
            .target = target,
            .optimize = optimize,
        });
        kitchensim_mod.addImport("labelle_tasks", tasks_mod);

        const kitchensim_exe = b.addExecutable(.{
            .name = "kitchen_sim",
            .root_module = kitchensim_mod,
        });
        b.installArtifact(kitchensim_exe);

        const run_kitchensim = b.addRunArtifact(kitchensim_exe);
        const kitchensim_step = b.step("kitchen-sim", "Run the kitchen simulator example");
        kitchensim_step.dependOn(&run_kitchensim.step);
    }
}
