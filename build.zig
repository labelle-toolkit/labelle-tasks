const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Get dependencies
    const zspec_dep = b.dependency("zspec", .{
        .target = target,
        .optimize = optimize,
    });

    // Main module (use underscore for Zig module naming convention)
    const tasks_mod = b.addModule("labelle_tasks", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Unit tests with zspec runner (from test/ folder)
    const test_mod = b.createModule(.{
        .root_source_file = b.path("test/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addImport("zspec", zspec_dep.module("zspec"));
    test_mod.addImport("labelle_tasks", tasks_mod);

    const unit_tests = b.addTest(.{
        .root_module = test_mod,
        .test_runner = .{ .path = zspec_dep.path("src/runner.zig"), .mode = .simple },
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // Kitchen simulator example
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
