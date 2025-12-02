//! Multi-Cycle Engine Example
//!
//! Demonstrates the Engine API with worker cycling:
//! - Worker completes multiple cycles at a workstation
//! - shouldContinue callback controls when worker continues
//! - Worker is released after max cycles
//!
//! This replaces the ECS event-driven example with the simpler Engine API.

const std = @import("std");
const tasks = @import("labelle_tasks");

const StepType = tasks.StepType;
const StepDef = tasks.StepDef;
const Priority = tasks.Priority;

// ============================================================================
// Game Entity IDs
// ============================================================================

const GameEntityId = u32;

const CHEF_MARIO: GameEntityId = 1;
const KITCHEN: GameEntityId = 100;

// ============================================================================
// Game State
// ============================================================================

var g_tick: u32 = 0;
var g_work_timers: std.AutoHashMap(GameEntityId, u32) = undefined;
var g_cycles_completed: u32 = 0;
const MAX_CYCLES: u32 = 2;

fn initGameState(allocator: std.mem.Allocator) void {
    g_work_timers = std.AutoHashMap(GameEntityId, u32).init(allocator);
    g_cycles_completed = 0;
}

fn deinitGameState() void {
    g_work_timers.deinit();
}

// ============================================================================
// Callbacks
// ============================================================================

fn findBestWorker(
    workstation_id: GameEntityId,
    step: StepType,
    available_workers: []const GameEntityId,
) ?GameEntityId {
    _ = workstation_id;
    _ = step;
    if (available_workers.len > 0) {
        return available_workers[0];
    }
    return null;
}

fn onStepStarted(
    worker_id: GameEntityId,
    workstation_id: GameEntityId,
    step: StepDef,
) void {
    _ = worker_id;
    _ = workstation_id;

    std.debug.print("[Tick {d:3}] Chef Mario STARTING: {s}\n", .{
        g_tick,
        @tagName(step.type),
    });

    // Simulate work taking time
    const ticks: u32 = switch (step.type) {
        .Pickup => 1,
        .Cook => 2,
        .Store => 1,
        .Craft => 1,
    };
    g_work_timers.put(CHEF_MARIO, ticks) catch {};
}

fn onStepCompleted(
    worker_id: GameEntityId,
    workstation_id: GameEntityId,
    step: StepDef,
) void {
    _ = worker_id;
    _ = workstation_id;

    std.debug.print("[Tick {d:3}] Chef Mario FINISHED step\n", .{g_tick});

    // Track cycles when last step completes
    if (step.type == .Store) {
        g_cycles_completed += 1;
    }
}

fn onWorkerReleased(
    worker_id: GameEntityId,
    workstation_id: GameEntityId,
) void {
    _ = worker_id;
    _ = workstation_id;
    std.debug.print("[Tick {d:3}] Chef Mario released (completed {d} cycles)\n", .{
        g_tick,
        g_cycles_completed,
    });
}

fn shouldContinue(
    workstation_id: GameEntityId,
    worker_id: GameEntityId,
    cycles_completed: u32,
) bool {
    _ = workstation_id;
    _ = worker_id;
    return cycles_completed < MAX_CYCLES;
}

// ============================================================================
// Main
// ============================================================================

pub fn main() !void {
    std.debug.print("\n", .{});
    std.debug.print("========================================\n", .{});
    std.debug.print("  MULTI-CYCLE ENGINE EXAMPLE            \n", .{});
    std.debug.print("========================================\n\n", .{});

    std.debug.print("This example demonstrates:\n", .{});
    std.debug.print("- Worker completing multiple cycles\n", .{});
    std.debug.print("- shouldContinue callback for cycle control\n", .{});
    std.debug.print("- Worker release after max cycles\n\n", .{});

    std.debug.print("Step durations: Pickup=1, Cook=2, Store=1\n\n", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    initGameState(allocator);
    defer deinitGameState();

    // ========================================================================
    // Initialize Engine
    // ========================================================================

    var engine = tasks.Engine(GameEntityId).init(allocator);
    defer engine.deinit();

    engine.setFindBestWorker(findBestWorker);
    engine.setOnStepStarted(onStepStarted);
    engine.setOnStepCompleted(onStepCompleted);
    engine.setOnWorkerReleased(onWorkerReleased);
    engine.setShouldContinue(shouldContinue);

    // ========================================================================
    // Register Entities
    // ========================================================================

    std.debug.print("Setup:\n", .{});
    std.debug.print("- Chef Mario (max 2 cycles)\n", .{});
    std.debug.print("- Kitchen (3 steps: Pickup -> Cook -> Store)\n\n", .{});

    _ = engine.addWorker(CHEF_MARIO, .{});

    const kitchen_steps = [_]StepDef{
        .{ .type = .Pickup },
        .{ .type = .Cook },
        .{ .type = .Store },
    };

    _ = engine.addWorkstation(KITCHEN, .{
        .steps = &kitchen_steps,
        .priority = .Normal,
    });

    // ========================================================================
    // Simulate
    // ========================================================================

    std.debug.print("[Tick   0] Signaling resources available...\n", .{});
    engine.notifyResourcesAvailable(KITCHEN);

    const max_ticks = 30;
    while (g_tick < max_ticks) {
        g_tick += 1;

        // Simulate work completion
        var workers_to_complete: [1]GameEntityId = undefined;
        var num_to_complete: usize = 0;

        var timer_iter = g_work_timers.iterator();
        while (timer_iter.next()) |entry| {
            const remaining = entry.value_ptr.*;
            if (remaining > 1) {
                entry.value_ptr.* = remaining - 1;
            } else if (remaining == 1) {
                workers_to_complete[num_to_complete] = entry.key_ptr.*;
                num_to_complete += 1;
            }
        }

        for (workers_to_complete[0..num_to_complete]) |worker| {
            _ = g_work_timers.remove(worker);
            engine.notifyStepComplete(worker);
        }

        // If cycle completed and worker continues, signal resources
        const status = engine.getWorkstationStatus(KITCHEN);
        if (status == .Blocked and engine.getAssignedWorker(KITCHEN) != null) {
            std.debug.print("[Tick {d:3}] Cycle done, signaling resources for next cycle...\n", .{g_tick});
            engine.notifyResourcesAvailable(KITCHEN);
        }

        // Check if done
        const worker_state = engine.getWorkerState(CHEF_MARIO);
        if (worker_state == .Idle and g_cycles_completed >= MAX_CYCLES) {
            std.debug.print("\n[Tick {d:3}] Simulation complete!\n", .{g_tick});
            break;
        }
    }

    // ========================================================================
    // Assertions
    // ========================================================================

    std.debug.print("\n--- Assertions ---\n", .{});

    std.debug.print("Worker cycles completed: {d}\n", .{g_cycles_completed});
    std.debug.assert(g_cycles_completed == 2);
    std.debug.print("[PASS] Worker completed 2 cycles\n", .{});

    const final_worker = engine.getWorkerState(CHEF_MARIO);
    std.debug.assert(final_worker == .Idle);
    std.debug.print("[PASS] Worker is idle after completion\n", .{});

    const final_status = engine.getWorkstationStatus(KITCHEN);
    std.debug.assert(final_status == .Blocked);
    std.debug.print("[PASS] Workstation is blocked (waiting for resources)\n", .{});

    const assigned = engine.getAssignedWorker(KITCHEN);
    std.debug.assert(assigned == null);
    std.debug.print("[PASS] Worker is unassigned\n", .{});

    std.debug.print("\n========================================\n", .{});
    std.debug.print("    ALL ASSERTIONS PASSED!              \n", .{});
    std.debug.print("========================================\n", .{});
}
