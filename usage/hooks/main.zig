//! Hook System Example
//!
//! Demonstrates the labelle-tasks hook system:
//! - Defining hook handlers for task engine events
//! - Using EngineWithHooks for hook-based integration
//! - Pattern for integration with labelle-engine
//!
//! This example shows how to observe task engine events using hooks
//! instead of (or in addition to) callbacks.

const std = @import("std");
const tasks = @import("labelle_tasks");

const StepType = tasks.StepType;
const StepDef = tasks.StepDef;
const Priority = tasks.Priority;

// ============================================================================
// Game Entity IDs
// ============================================================================

const GameEntityId = u32;

const CHEF_ALICE: GameEntityId = 1;
const CHEF_BOB: GameEntityId = 2;
const STOVE_1: GameEntityId = 100;
const STOVE_2: GameEntityId = 101;

// ============================================================================
// Hook Handlers
// ============================================================================
// Define handlers for task engine events.
// Each function name matches the hook name (e.g., step_started, step_completed).
// Only implement the hooks you care about - others are no-ops.

const GameTaskHooks = struct {
    // Track statistics for assertions
    var steps_started: u32 = 0;
    var steps_completed: u32 = 0;
    var workers_assigned: u32 = 0;
    var workers_released: u32 = 0;
    var cycles_completed: u32 = 0;
    var workstations_activated: u32 = 0;
    var workstations_blocked: u32 = 0;

    fn reset() void {
        steps_started = 0;
        steps_completed = 0;
        workers_assigned = 0;
        workers_released = 0;
        cycles_completed = 0;
        workstations_activated = 0;
        workstations_blocked = 0;
    }

    pub fn step_started(payload: tasks.hooks.HookPayload(GameEntityId)) void {
        const info = payload.step_started;
        steps_started += 1;
        std.debug.print("[hook] step_started: worker={d} workstation={d} step={s}\n", .{
            info.worker_id,
            info.workstation_id,
            @tagName(info.step.type),
        });
    }

    pub fn step_completed(payload: tasks.hooks.HookPayload(GameEntityId)) void {
        const info = payload.step_completed;
        steps_completed += 1;
        std.debug.print("[hook] step_completed: worker={d} workstation={d} step={s}\n", .{
            info.worker_id,
            info.workstation_id,
            @tagName(info.step.type),
        });
    }

    pub fn worker_assigned(payload: tasks.hooks.HookPayload(GameEntityId)) void {
        const info = payload.worker_assigned;
        workers_assigned += 1;
        std.debug.print("[hook] worker_assigned: worker={d} -> workstation={d}\n", .{
            info.worker_id,
            info.workstation_id,
        });
    }

    pub fn worker_released(payload: tasks.hooks.HookPayload(GameEntityId)) void {
        const info = payload.worker_released;
        workers_released += 1;
        std.debug.print("[hook] worker_released: worker={d} <- workstation={d}\n", .{
            info.worker_id,
            info.workstation_id,
        });
    }

    pub fn workstation_activated(payload: tasks.hooks.HookPayload(GameEntityId)) void {
        const info = payload.workstation_activated;
        workstations_activated += 1;
        std.debug.print("[hook] workstation_activated: workstation={d} priority={s}\n", .{
            info.workstation_id,
            @tagName(info.priority),
        });
    }

    pub fn workstation_blocked(payload: tasks.hooks.HookPayload(GameEntityId)) void {
        const info = payload.workstation_blocked;
        workstations_blocked += 1;
        std.debug.print("[hook] workstation_blocked: workstation={d}\n", .{
            info.workstation_id,
        });
    }

    pub fn cycle_completed(payload: tasks.hooks.HookPayload(GameEntityId)) void {
        const info = payload.cycle_completed;
        cycles_completed += 1;
        std.debug.print("[hook] cycle_completed: workstation={d} worker={d} cycles={d}\n", .{
            info.workstation_id,
            info.worker_id,
            info.cycles_completed,
        });
    }
};

// ============================================================================
// Analytics Hooks (demonstrates multiple hook handlers)
// ============================================================================
// You can have multiple handler structs that respond to the same hooks.
// Use MergeTasksHooks to combine them.

const AnalyticsHooks = struct {
    var total_events: u32 = 0;

    pub fn step_completed(_: tasks.hooks.HookPayload(GameEntityId)) void {
        total_events += 1;
        // In a real game, you might send analytics events here
    }

    pub fn cycle_completed(_: tasks.hooks.HookPayload(GameEntityId)) void {
        total_events += 1;
    }
};

// ============================================================================
// Create the Dispatcher and Engine
// ============================================================================

// Merge multiple hook handler structs into one dispatcher
const AllHooks = tasks.hooks.MergeTasksHooks(GameEntityId, .{
    GameTaskHooks,
    AnalyticsHooks,
});

// Create an Engine that emits hooks
const TaskEngine = tasks.EngineWithHooks(GameEntityId, AllHooks);

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

// ============================================================================
// Callbacks (still needed for decision logic)
// ============================================================================
// Note: Hooks are for observing events, not for making decisions.
// FindBestWorker and ShouldContinue are still callbacks because they
// return values that affect engine behavior.

fn findBestWorker(
    _: GameEntityId,
    _: StepType,
    available_workers: []const GameEntityId,
) ?GameEntityId {
    // Simple: pick first available worker
    if (available_workers.len > 0) {
        return available_workers[0];
    }
    return null;
}

fn shouldContinue(
    _: GameEntityId,
    _: GameEntityId,
    cycles_completed: u32,
) bool {
    // Do 1 cycle per workstation
    return cycles_completed < 1;
}

// ============================================================================
// Main
// ============================================================================

pub fn main() !void {
    std.debug.print("\n", .{});
    std.debug.print("========================================\n", .{});
    std.debug.print("  HOOK SYSTEM EXAMPLE                   \n", .{});
    std.debug.print("========================================\n\n", .{});

    std.debug.print("This example demonstrates:\n", .{});
    std.debug.print("- Hook-based event observation\n", .{});
    std.debug.print("- Multiple hook handlers (GameTaskHooks + AnalyticsHooks)\n", .{});
    std.debug.print("- EngineWithHooks for automatic hook emission\n", .{});
    std.debug.print("\n", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    initGameState(allocator);
    defer deinitGameState();

    // Reset hook counters
    GameTaskHooks.reset();
    AnalyticsHooks.total_events = 0;

    // ========================================================================
    // Initialize Engine with Hooks
    // ========================================================================

    var engine = TaskEngine.init(allocator);
    defer engine.deinit();

    // Set decision callbacks (still needed)
    engine.setFindBestWorker(findBestWorker);
    engine.setShouldContinue(shouldContinue);

    // ========================================================================
    // Register Entities
    // ========================================================================

    std.debug.print("--- Setup ---\n", .{});
    std.debug.print("Adding 2 chefs and 2 stoves\n\n", .{});

    _ = engine.addWorker(CHEF_ALICE, .{});
    _ = engine.addWorker(CHEF_BOB, .{});

    const cooking_steps = [_]StepDef{
        .{ .type = .Pickup },
        .{ .type = .Cook },
        .{ .type = .Store },
    };

    _ = engine.addWorkstation(STOVE_1, .{
        .steps = &cooking_steps,
        .priority = .High,
    });

    _ = engine.addWorkstation(STOVE_2, .{
        .steps = &cooking_steps,
        .priority = .Normal,
    });

    // ========================================================================
    // Simulate
    // ========================================================================

    std.debug.print("--- Starting simulation ---\n\n", .{});

    // Signal both stoves have resources
    std.debug.print("[Tick 0] Both stoves signal resources available!\n\n", .{});
    engine.notifyResourcesAvailable(STOVE_1);
    engine.notifyResourcesAvailable(STOVE_2);

    // Run simulation
    const max_ticks = 30;
    while (g_tick < max_ticks) {
        g_tick += 1;

        // Simulate work timers
        var workers_to_complete: [2]GameEntityId = undefined;
        var num_to_complete: usize = 0;

        // Check for any active workers
        const workers = [_]GameEntityId{ CHEF_ALICE, CHEF_BOB };
        for (workers) |worker| {
            if (engine.getWorkerState(worker)) |state| {
                if (state == .Working) {
                    // Simple timer: each step takes 1 tick
                    if (g_work_timers.get(worker)) |remaining| {
                        if (remaining <= 1) {
                            workers_to_complete[num_to_complete] = worker;
                            num_to_complete += 1;
                            _ = g_work_timers.remove(worker);
                        } else {
                            try g_work_timers.put(worker, remaining - 1);
                        }
                    } else {
                        // Start timer
                        try g_work_timers.put(worker, 1);
                    }
                }
            }
        }

        // Notify step completions
        for (workers_to_complete[0..num_to_complete]) |worker| {
            engine.notifyStepComplete(worker);
        }

        // Check if done
        const stove1_cycles = engine.getCyclesCompleted(STOVE_1);
        const stove2_cycles = engine.getCyclesCompleted(STOVE_2);

        if (stove1_cycles >= 1 and stove2_cycles >= 1) {
            std.debug.print("\n[Tick {d}] Both stoves completed!\n", .{g_tick});
            break;
        }
    }

    // ========================================================================
    // Assertions
    // ========================================================================

    std.debug.print("\n--- Assertions ---\n\n", .{});

    // Check hook counters
    std.debug.print("Hook statistics:\n", .{});
    std.debug.print("  steps_started: {d}\n", .{GameTaskHooks.steps_started});
    std.debug.print("  steps_completed: {d}\n", .{GameTaskHooks.steps_completed});
    std.debug.print("  workers_assigned: {d}\n", .{GameTaskHooks.workers_assigned});
    std.debug.print("  workers_released: {d}\n", .{GameTaskHooks.workers_released});
    std.debug.print("  cycles_completed: {d}\n", .{GameTaskHooks.cycles_completed});
    std.debug.print("  workstations_activated: {d}\n", .{GameTaskHooks.workstations_activated});
    std.debug.print("  analytics_events: {d}\n", .{AnalyticsHooks.total_events});
    std.debug.print("\n", .{});

    // Each stove has 3 steps, 2 stoves = 6 steps total
    std.debug.assert(GameTaskHooks.steps_started == 6);
    std.debug.print("[PASS] 6 steps started (3 per stove x 2 stoves)\n", .{});

    std.debug.assert(GameTaskHooks.steps_completed == 6);
    std.debug.print("[PASS] 6 steps completed\n", .{});

    // 2 workers assigned
    std.debug.assert(GameTaskHooks.workers_assigned == 2);
    std.debug.print("[PASS] 2 workers assigned\n", .{});

    // 2 workers released
    std.debug.assert(GameTaskHooks.workers_released == 2);
    std.debug.print("[PASS] 2 workers released\n", .{});

    // 2 cycles completed
    std.debug.assert(GameTaskHooks.cycles_completed == 2);
    std.debug.print("[PASS] 2 cycles completed\n", .{});

    // Analytics received cycle_completed events
    std.debug.assert(AnalyticsHooks.total_events >= 2);
    std.debug.print("[PASS] Analytics received events\n", .{});

    std.debug.print("\n========================================\n", .{});
    std.debug.print("    ALL ASSERTIONS PASSED!              \n", .{});
    std.debug.print("========================================\n\n", .{});

    // ========================================================================
    // labelle-engine Integration Pattern
    // ========================================================================

    std.debug.print("--- labelle-engine Integration Pattern ---\n\n", .{});
    std.debug.print("When integrating with labelle-engine, you can create a plugin\n", .{});
    std.debug.print("that responds to engine hooks and manages the task engine:\n\n", .{});
    std.debug.print("  const TasksPlugin = struct {{\n", .{});
    std.debug.print("      // Plugin listens to engine hooks\n", .{});
    std.debug.print("      pub const EngineHooks = struct {{\n", .{});
    std.debug.print("          pub fn game_init(_: engine.HookPayload) void {{\n", .{});
    std.debug.print("              // Initialize task engine\n", .{});
    std.debug.print("          }}\n", .{});
    std.debug.print("          pub fn frame_start(_: engine.HookPayload) void {{\n", .{});
    std.debug.print("              // Update task engine\n", .{});
    std.debug.print("          }}\n", .{});
    std.debug.print("      }};\n", .{});
    std.debug.print("  }};\n\n", .{});
    std.debug.print("  // Merge with game hooks\n", .{});
    std.debug.print("  const AllHooks = engine.MergeEngineHooks(.{{ GameHooks, TasksPlugin.EngineHooks }});\n", .{});
    std.debug.print("  const Game = engine.GameWith(AllHooks);\n", .{});
    std.debug.print("\nSee labelle-engine/usage/example_hooks/ for a complete example.\n", .{});
}
