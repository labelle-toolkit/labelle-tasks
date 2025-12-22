//! Simple Engine Example
//!
//! Demonstrates the basic Engine API:
//! - Priority levels affecting workstation selection
//! - Worker assignment based on priority
//! - Multi-step workflows
//!
//! Two workstations with different priorities compete for a single worker.

const std = @import("std");
const tasks = @import("labelle_tasks");

const StepType = tasks.Components.StepType;
const Priority = tasks.Components.Priority;

// ============================================================================
// Game Entity IDs
// ============================================================================

const GameEntityId = u32;

const WORKER_BOB: GameEntityId = 1;
const STATION_HIGH: GameEntityId = 100;
const STATION_LOW: GameEntityId = 101;

// ============================================================================
// Game State
// ============================================================================

var g_tick: u32 = 0;
var g_work_timers: std.AutoHashMap(GameEntityId, u32) = undefined;

fn initGameState(allocator: std.mem.Allocator) void {
    g_work_timers = std.AutoHashMap(GameEntityId, u32).init(allocator);
}

fn deinitGameState() void {
    g_work_timers.deinit();
}

fn entityName(id: GameEntityId) []const u8 {
    return switch (id) {
        WORKER_BOB => "Bob",
        STATION_HIGH => "High Priority Station",
        STATION_LOW => "Low Priority Station",
        else => "Unknown",
    };
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
    // Only one worker, just return them
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
    std.debug.print("[Tick {d:3}] {s} STARTING {s} at {s}\n", .{
        g_tick,
        entityName(worker_id),
        @tagName(step.type),
        entityName(workstation_id),
    });

    // All steps take 1 tick
    g_work_timers.put(worker_id, 1) catch {};
}

fn onStepCompleted(
    worker_id: GameEntityId,
    workstation_id: GameEntityId,
    step: StepDef,
) void {
    std.debug.print("[Tick {d:3}] {s} COMPLETED {s} at {s}\n", .{
        g_tick,
        entityName(worker_id),
        @tagName(step.type),
        entityName(workstation_id),
    });
}

fn onWorkerReleased(
    worker_id: GameEntityId,
    workstation_id: GameEntityId,
) void {
    std.debug.print("[Tick {d:3}] {s} RELEASED from {s}\n", .{
        g_tick,
        entityName(worker_id),
        entityName(workstation_id),
    });
}

fn shouldContinue(
    workstation_id: GameEntityId,
    worker_id: GameEntityId,
    cycles_completed: u32,
) bool {
    _ = workstation_id;
    _ = worker_id;
    // Do 1 cycle per workstation
    return cycles_completed < 1;
}

// ============================================================================
// Main
// ============================================================================

pub fn main() !void {
    std.debug.print("\n", .{});
    std.debug.print("========================================\n", .{});
    std.debug.print("  SIMPLE ENGINE EXAMPLE                 \n", .{});
    std.debug.print("========================================\n\n", .{});

    std.debug.print("This example demonstrates:\n", .{});
    std.debug.print("- Priority-based workstation selection\n", .{});
    std.debug.print("- Worker assignment to highest priority first\n\n", .{});

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
    std.debug.print("- One worker (Bob)\n", .{});
    std.debug.print("- High Priority Station (should be picked first)\n", .{});
    std.debug.print("- Low Priority Station (should be picked second)\n\n", .{});

    _ = engine.addWorker(WORKER_BOB, .{});

    const simple_steps = [_]StepDef{
        .{ .type = .Pickup },
        .{ .type = .Store },
    };

    _ = engine.addWorkstation(STATION_HIGH, .{
        .steps = &simple_steps,
        .priority = .High,
    });

    _ = engine.addWorkstation(STATION_LOW, .{
        .steps = &simple_steps,
        .priority = .Low,
    });

    // ========================================================================
    // Simulate
    // ========================================================================

    std.debug.print("--- Starting simulation ---\n\n", .{});

    // Signal both stations have resources at the same time
    std.debug.print("[Tick   0] Both stations signal resources available!\n", .{});
    engine.notifyResourcesAvailable(STATION_HIGH);
    engine.notifyResourcesAvailable(STATION_LOW);

    // Run simulation
    const max_ticks = 20;
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

        // Check completion
        const high_cycles = engine.getCyclesCompleted(STATION_HIGH);
        const low_cycles = engine.getCyclesCompleted(STATION_LOW);

        if (high_cycles >= 1 and low_cycles >= 1) {
            std.debug.print("\n[Tick {d:3}] Both stations completed!\n", .{g_tick});
            break;
        }

        // If worker released, they'll auto-assign to queued station
    }

    // ========================================================================
    // Assertions
    // ========================================================================

    std.debug.print("\n--- Assertions ---\n", .{});

    const high_cycles = engine.getCyclesCompleted(STATION_HIGH);
    const low_cycles = engine.getCyclesCompleted(STATION_LOW);

    std.debug.assert(high_cycles == 1);
    std.debug.print("[PASS] High Priority Station completed 1 cycle\n", .{});

    std.debug.assert(low_cycles == 1);
    std.debug.print("[PASS] Low Priority Station completed 1 cycle\n", .{});

    const bob_state = engine.getWorkerState(WORKER_BOB);
    std.debug.assert(bob_state.? == .Idle);
    std.debug.print("[PASS] Bob is idle\n", .{});

    std.debug.print("\n========================================\n", .{});
    std.debug.print("    ALL ASSERTIONS PASSED!              \n", .{});
    std.debug.print("========================================\n", .{});
}
