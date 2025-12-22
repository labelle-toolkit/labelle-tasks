//! Engine API Example
//!
//! Demonstrates the self-contained Engine API for task orchestration.
//! The engine manages all task state internally - the game just:
//! 1. Registers workers and workstations
//! 2. Provides callbacks for game-specific logic
//! 3. Notifies the engine of events
//!
//! No ECS knowledge required!

const std = @import("std");
const tasks = @import("labelle_tasks");

const StepType = tasks.Components.StepType;
const Priority = tasks.Components.Priority;

// ============================================================================
// Game Entity IDs (whatever your game uses)
// ============================================================================

const GameEntityId = u32;

const CHEF_MARIO: GameEntityId = 1;
const CHEF_LUIGI: GameEntityId = 2;
const STOVE_1: GameEntityId = 100;
const STOVE_2: GameEntityId = 101;

// ============================================================================
// Game State (simulated)
// ============================================================================

const Position = struct { x: i32, y: i32 };

var g_positions: std.AutoHashMap(GameEntityId, Position) = undefined;
var g_tick: u32 = 0;

// Track simulated work per worker
var g_work_timers: std.AutoHashMap(GameEntityId, u32) = undefined;

fn initGameState(allocator: std.mem.Allocator) void {
    g_positions = std.AutoHashMap(GameEntityId, Position).init(allocator);
    g_work_timers = std.AutoHashMap(GameEntityId, u32).init(allocator);
    // Workers start at center
    g_positions.put(CHEF_MARIO, .{ .x = 5, .y = 5 }) catch {};
    g_positions.put(CHEF_LUIGI, .{ .x = 5, .y = 5 }) catch {};
    // Workstations
    g_positions.put(STOVE_1, .{ .x = 0, .y = 0 }) catch {};
    g_positions.put(STOVE_2, .{ .x = 10, .y = 0 }) catch {};
}

fn deinitGameState() void {
    g_positions.deinit();
    g_work_timers.deinit();
}

fn distance(a: Position, b: Position) i32 {
    const dx = if (a.x > b.x) a.x - b.x else b.x - a.x;
    const dy = if (a.y > b.y) a.y - b.y else b.y - a.y;
    return dx + dy;
}

fn entityName(id: GameEntityId) []const u8 {
    return switch (id) {
        CHEF_MARIO => "Chef Mario",
        CHEF_LUIGI => "Chef Luigi",
        STOVE_1 => "Stove 1",
        STOVE_2 => "Stove 2",
        else => "Unknown",
    };
}

// ============================================================================
// Callbacks (Game provides these to Engine)
// ============================================================================

/// Engine asks: "Which worker should I assign to this workstation?"
/// Game answers based on distance, skills, preferences, etc.
fn findBestWorker(
    workstation_id: GameEntityId,
    step: StepType,
    available_workers: []const GameEntityId,
) ?GameEntityId {
    _ = step;

    if (available_workers.len == 0) return null;

    const ws_pos = g_positions.get(workstation_id) orelse return available_workers[0];

    var best: ?GameEntityId = null;
    var best_dist: i32 = std.math.maxInt(i32);

    for (available_workers) |worker_id| {
        const worker_pos = g_positions.get(worker_id) orelse continue;
        const dist = distance(worker_pos, ws_pos);
        if (dist < best_dist) {
            best_dist = dist;
            best = worker_id;
        }
    }

    std.debug.print("[Tick {d:3}] findBestWorker: chose {s} (distance {d})\n", .{
        g_tick,
        entityName(best orelse available_workers[0]),
        best_dist,
    });

    return best orelse available_workers[0];
}

/// Engine tells game: "This worker should start this step"
/// Game starts movement, animation, timer, etc.
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

    // Simulate work taking time - set timer for this worker
    const ticks: u32 = switch (step.type) {
        .Pickup => 2,
        .Cook => 3,
        .Store => 1,
        .Craft => 1,
    };
    g_work_timers.put(worker_id, ticks) catch {};
}

/// Engine tells game: "Step completed"
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

/// Engine tells game: "Worker released from workstation"
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

/// Engine asks: "Should this workstation start another cycle?"
fn shouldContinue(
    workstation_id: GameEntityId,
    worker_id: GameEntityId,
    cycles_completed: u32,
) bool {
    _ = workstation_id;
    _ = worker_id;
    // Do 2 cycles max
    return cycles_completed < 2;
}

// ============================================================================
// Main
// ============================================================================

pub fn main() !void {
    std.debug.print("\n", .{});
    std.debug.print("========================================\n", .{});
    std.debug.print("  ENGINE API EXAMPLE                    \n", .{});
    std.debug.print("========================================\n\n", .{});

    std.debug.print("This example demonstrates the self-contained Engine API.\n", .{});
    std.debug.print("No ECS required - just register entities and callbacks!\n\n", .{});

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

    // Register callbacks
    engine.setFindBestWorker(findBestWorker);
    engine.setOnStepStarted(onStepStarted);
    engine.setOnStepCompleted(onStepCompleted);
    engine.setOnWorkerReleased(onWorkerReleased);
    engine.setShouldContinue(shouldContinue);

    // ========================================================================
    // Register Game Entities
    // ========================================================================

    std.debug.print("Registering workers and workstations...\n", .{});

    _ = engine.addWorker(CHEF_MARIO, .{});
    _ = engine.addWorker(CHEF_LUIGI, .{});

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

    std.debug.print("- Chef Mario at (5,5)\n", .{});
    std.debug.print("- Chef Luigi at (5,5)\n", .{});
    std.debug.print("- Stove 1 at (0,0) - High priority\n", .{});
    std.debug.print("- Stove 2 at (10,0) - Normal priority\n\n", .{});

    // ========================================================================
    // Simulate Game Loop
    // ========================================================================

    std.debug.print("--- Starting simulation ---\n\n", .{});

    // Signal resources available for both stoves
    std.debug.print("[Tick   0] Resources available at both stoves!\n", .{});
    engine.notifyResourcesAvailable(STOVE_1);
    engine.notifyResourcesAvailable(STOVE_2);

    const max_ticks = 50;
    while (g_tick < max_ticks) {
        g_tick += 1;

        // Simulate work completion for all workers
        var workers_to_complete: [2]GameEntityId = undefined;
        var num_to_complete: usize = 0;

        var timer_iter = g_work_timers.iterator();
        while (timer_iter.next()) |entry| {
            const remaining = entry.value_ptr.*;
            if (remaining > 1) {
                entry.value_ptr.* = remaining - 1;
            } else if (remaining == 1) {
                // Will complete this tick
                workers_to_complete[num_to_complete] = entry.key_ptr.*;
                num_to_complete += 1;
            }
        }

        // Notify completions (after iteration to avoid modification during iteration)
        for (workers_to_complete[0..num_to_complete]) |worker| {
            _ = g_work_timers.remove(worker);
            engine.notifyStepComplete(worker);
        }

        // Check if both stoves finished their cycles
        const stove1_cycles = engine.getCyclesCompleted(STOVE_1);
        const stove2_cycles = engine.getCyclesCompleted(STOVE_2);

        if (stove1_cycles >= 2 and stove2_cycles >= 2) {
            std.debug.print("\n[Tick {d:3}] Both stoves completed 2 cycles!\n", .{g_tick});
            break;
        }

        // If a cycle completed and worker continues, signal resources again
        const stove1_status = engine.getWorkstationStatus(STOVE_1);
        const stove2_status = engine.getWorkstationStatus(STOVE_2);

        if (stove1_status == .Blocked and engine.getAssignedWorker(STOVE_1) != null) {
            std.debug.print("[Tick {d:3}] Signaling resources for Stove 1 next cycle\n", .{g_tick});
            engine.notifyResourcesAvailable(STOVE_1);
        }
        if (stove2_status == .Blocked and engine.getAssignedWorker(STOVE_2) != null) {
            std.debug.print("[Tick {d:3}] Signaling resources for Stove 2 next cycle\n", .{g_tick});
            engine.notifyResourcesAvailable(STOVE_2);
        }
    }

    // ========================================================================
    // Final State
    // ========================================================================

    std.debug.print("\n--- Final State ---\n", .{});

    std.debug.print("Stove 1: {d} cycles completed\n", .{engine.getCyclesCompleted(STOVE_1)});
    std.debug.print("Stove 2: {d} cycles completed\n", .{engine.getCyclesCompleted(STOVE_2)});

    const mario_state = engine.getWorkerState(CHEF_MARIO);
    const luigi_state = engine.getWorkerState(CHEF_LUIGI);
    std.debug.print("Chef Mario: {s}\n", .{@tagName(mario_state.?)});
    std.debug.print("Chef Luigi: {s}\n", .{@tagName(luigi_state.?)});

    // Assertions
    std.debug.print("\n--- Assertions ---\n", .{});

    std.debug.assert(engine.getCyclesCompleted(STOVE_1) == 2);
    std.debug.print("[PASS] Stove 1 completed 2 cycles\n", .{});

    std.debug.assert(engine.getCyclesCompleted(STOVE_2) == 2);
    std.debug.print("[PASS] Stove 2 completed 2 cycles\n", .{});

    std.debug.assert(mario_state.? == .Idle);
    std.debug.print("[PASS] Chef Mario is idle\n", .{});

    std.debug.assert(luigi_state.? == .Idle);
    std.debug.print("[PASS] Chef Luigi is idle\n", .{});

    std.debug.print("\n========================================\n", .{});
    std.debug.print("    ALL ASSERTIONS PASSED!              \n", .{});
    std.debug.print("========================================\n", .{});
}
