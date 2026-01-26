const std = @import("std");

/// Graphics backend selection (must match labelle-engine)
/// These options are accepted for compatibility but no longer used directly.
pub const Backend = enum {
    raylib,
    sokol,
    sdl,
    bgfx,
    zgpu,
};

/// ECS backend selection (must match labelle-engine)
/// These options are accepted for compatibility but no longer used directly.
pub const EcsBackend = enum {
    zig_ecs,
    zflecs,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Backend options - accepted for compatibility with parent projects
    // but no longer used since we removed the labelle-engine dependency
    _ = b.option(Backend, "backend", "Graphics backend (unused, for compatibility)");
    _ = b.option(EcsBackend, "ecs_backend", "ECS backend (unused, for compatibility)");
    _ = b.option(bool, "physics", "Physics enabled (unused, for compatibility)");

    // Get dependencies
    const zspec_dep = b.dependency("zspec", .{
        .target = target,
        .optimize = optimize,
    });

    // Main module (use underscore for Zig module naming convention)
    // Note: labelle-engine is NO LONGER a direct dependency.
    // Engine types are now injected via EngineTypes parameter to prevent
    // WASM module collision (issue #38).
    // The game project adds labelle-engine import when building the plugin.
    const tasks_mod = b.addModule("labelle_tasks", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

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
