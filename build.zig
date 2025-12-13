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
    const lib_mod = b.addModule("labelle_tasks", .{
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

    // Components example - demonstrates ECS component usage with game-defined enums
    const components_mod = b.createModule(.{
        .root_source_file = b.path("usage/components/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    components_mod.addImport("labelle_tasks", lib_mod);

    const components_example = b.addExecutable(.{
        .name = "components",
        .root_module = components_mod,
    });
    b.installArtifact(components_example);

    const run_components = b.addRunArtifact(components_example);
    const components_step = b.step("components", "Run the components usage example");
    components_step.dependOn(&run_components.step);

    // Farm game example - demonstrates full engine workflow
    const farm_mod = b.createModule(.{
        .root_source_file = b.path("usage/engine/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    farm_mod.addImport("labelle_tasks", lib_mod);

    const farm_example = b.addExecutable(.{
        .name = "farm",
        .root_module = farm_mod,
    });
    b.installArtifact(farm_example);

    const run_farm = b.addRunArtifact(farm_example);
    const farm_step = b.step("farm", "Run the farm game example");
    farm_step.dependOn(&run_farm.step);

    // Run all examples step
    const examples_step = b.step("examples", "Run all usage examples");
    examples_step.dependOn(&run_kitchensim.step);
    examples_step.dependOn(&run_components.step);
    examples_step.dependOn(&run_farm.step);
}
