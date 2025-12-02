const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Get dependencies
    const zspec_dep = b.dependency("zspec", .{
        .target = target,
        .optimize = optimize,
    });

    const ecs_dep = b.dependency("zig-ecs", .{
        .target = target,
        .optimize = optimize,
    });

    // Main library module
    const lib_mod = b.addModule("labelle-tasks", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ecs", .module = ecs_dep.module("zig-ecs") },
        },
    });

    // Library artifact
    const lib = b.addLibrary(.{
        .name = "labelle_tasks",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ecs", .module = ecs_dep.module("zig-ecs") },
            },
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

    // Simple example - demonstrates Task, TaskStatus, Priority, InterruptLevel
    const simple_mod = b.createModule(.{
        .root_source_file = b.path("usage/simple/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    simple_mod.addImport("labelle_tasks", lib_mod);
    simple_mod.addImport("ecs", ecs_dep.module("zig-ecs"));

    const simple_example = b.addExecutable(.{
        .name = "simple_example",
        .root_module = simple_mod,
    });
    b.installArtifact(simple_example);

    const run_simple = b.addRunArtifact(simple_example);
    const simple_step = b.step("simple", "Run the simple task example");
    simple_step.dependOn(&run_simple.step);

    // Kitchen example - demonstrates TaskGroup, GroupSteps, multi-step workflows
    const kitchen_mod = b.createModule(.{
        .root_source_file = b.path("usage/kitchen/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    kitchen_mod.addImport("labelle_tasks", lib_mod);
    kitchen_mod.addImport("ecs", ecs_dep.module("zig-ecs"));

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
    abandonment_mod.addImport("ecs", ecs_dep.module("zig-ecs"));

    const abandonment_example = b.addExecutable(.{
        .name = "abandonment_example",
        .root_module = abandonment_mod,
    });
    b.installArtifact(abandonment_example);

    const run_abandonment = b.addRunArtifact(abandonment_example);
    const abandonment_step = b.step("abandonment", "Run the worker abandonment example");
    abandonment_step.dependOn(&run_abandonment.step);

    // Systems example - demonstrates ECS systems for automatic state management
    const systems_mod = b.createModule(.{
        .root_source_file = b.path("usage/systems/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    systems_mod.addImport("labelle_tasks", lib_mod);
    systems_mod.addImport("ecs", ecs_dep.module("zig-ecs"));

    const systems_example = b.addExecutable(.{
        .name = "systems_example",
        .root_module = systems_mod,
    });
    b.installArtifact(systems_example);

    const run_systems = b.addRunArtifact(systems_example);
    const systems_step = b.step("systems", "Run the ECS systems example");
    systems_step.dependOn(&run_systems.step);

    // Run all examples step
    const examples_step = b.step("examples", "Run all usage examples");
    examples_step.dependOn(&run_simple.step);
    examples_step.dependOn(&run_kitchen.step);
    examples_step.dependOn(&run_abandonment.step);
    examples_step.dependOn(&run_systems.step);
}
