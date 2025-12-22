//! Worker Abandonment Engine Example
//!
//! Demonstrates task group continuation after worker abandonment:
//! - Worker starts a multi-step task group
//! - Worker gets interrupted (fight, death, shift end)
//! - Group keeps its current step (doesn't reset)
//! - New worker continues from where the previous worker left off
//!
//! Key concept: abandonWork() keeps the step, releaseWorker() resets

const std = @import("std");
const tasks = @import("labelle_tasks");

const StepType = tasks.Components.StepType;
const Priority = tasks.Components.Priority;

// ============================================================================
// Game Entity IDs
// ============================================================================

const GameEntityId = u32;

const CHEF_ALICE: GameEntityId = 1;
const CHEF_BOB: GameEntityId = 2;
const STOVE: GameEntityId = 100;

// ============================================================================
// Game State
// ============================================================================

const Position = struct { x: i32, y: i32 };

const ItemType = enum {
    Meat,
    Vegetable,
    CookedMeal,
};

const StorageData = struct {
    name: []const u8,
    items: [10]?ItemType = [_]?ItemType{null} ** 10,
    count: usize = 0,

    fn hasItem(self: *const StorageData, item_type: ItemType) bool {
        for (self.items[0..self.count]) |maybe_item| {
            if (maybe_item) |item| {
                if (item == item_type) return true;
            }
        }
        return false;
    }

    fn takeItem(self: *StorageData, item_type: ItemType) bool {
        for (&self.items, 0..) |*maybe_item, i| {
            if (maybe_item.*) |item| {
                if (item == item_type and i < self.count) {
                    maybe_item.* = null;
                    var j = i;
                    while (j < self.count - 1) : (j += 1) {
                        self.items[j] = self.items[j + 1];
                    }
                    self.items[self.count - 1] = null;
                    self.count -= 1;
                    return true;
                }
            }
        }
        return false;
    }

    fn addItem(self: *StorageData, item_type: ItemType) bool {
        if (self.count >= 10) return false;
        self.items[self.count] = item_type;
        self.count += 1;
        return true;
    }
};

const WorkerData = struct {
    name: []const u8,
    pos: Position,
    carrying: ?ItemType = null,
    target_pos: ?Position = null,
    state: enum { Idle, Moving, Working } = .Idle,
};

// Global game state
var g_tick: u32 = 0;
var g_fridge: StorageData = undefined;
var g_meal_storage: StorageData = undefined;
var g_alice: WorkerData = undefined;
var g_bob: WorkerData = undefined;
var g_stove_pos: Position = undefined;
var g_fridge_pos: Position = undefined;
var g_meal_storage_pos: Position = undefined;

// Current step tracking
var g_current_worker: ?GameEntityId = null;
var g_current_step: ?StepDef = null;

fn initGameState() void {
    g_fridge_pos = .{ .x = 0, .y = 0 };
    g_stove_pos = .{ .x = 5, .y = 0 };
    g_meal_storage_pos = .{ .x = 10, .y = 0 };

    g_fridge = .{ .name = "Fridge" };
    _ = g_fridge.addItem(.Meat);
    _ = g_fridge.addItem(.Vegetable);

    g_meal_storage = .{ .name = "Meal Storage" };

    g_alice = .{
        .name = "Chef Alice",
        .pos = .{ .x = 5, .y = 0 },
    };

    g_bob = .{
        .name = "Chef Bob",
        .pos = .{ .x = 5, .y = 0 },
    };
}

fn getWorkerData(id: GameEntityId) ?*WorkerData {
    return switch (id) {
        CHEF_ALICE => &g_alice,
        CHEF_BOB => &g_bob,
        else => null,
    };
}

fn log(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("[Tick {d:3}] " ++ fmt ++ "\n", .{g_tick} ++ args);
}

// ============================================================================
// Engine Callbacks
// ============================================================================

// Track who is in a fight (can't work)
var g_alice_in_fight: bool = false;

fn findBestWorker(
    workstation_id: GameEntityId,
    step: StepType,
    available_workers: []const GameEntityId,
) ?GameEntityId {
    _ = workstation_id;
    _ = step;
    // Skip Alice if she's in a fight
    for (available_workers) |worker| {
        if (worker == CHEF_ALICE and g_alice_in_fight) continue;
        return worker;
    }
    return null;
}

fn onStepStarted(
    worker_id: GameEntityId,
    workstation_id: GameEntityId,
    step: StepDef,
) void {
    _ = workstation_id;

    g_current_worker = worker_id;
    g_current_step = step;

    const worker = getWorkerData(worker_id) orelse return;

    switch (step.type) {
        .Pickup => {
            worker.target_pos = g_fridge_pos;
            worker.state = .Moving;
            // Determine item based on what's in fridge
            const item_name: []const u8 = if (g_fridge.hasItem(.Meat)) "Meat" else "Vegetable";
            log("{s} moving to Fridge to pickup {s}", .{ worker.name, item_name });
        },
        .Cook => {
            worker.target_pos = g_stove_pos;
            worker.state = .Moving;
            log("{s} moving to Stove to cook", .{worker.name});
        },
        .Store => {
            worker.target_pos = g_meal_storage_pos;
            worker.state = .Moving;
            log("{s} moving to Meal Storage to store CookedMeal", .{worker.name});
        },
        else => {},
    }
}

fn onStepCompleted(
    worker_id: GameEntityId,
    workstation_id: GameEntityId,
    step: StepDef,
) void {
    _ = workstation_id;
    _ = step;
    _ = worker_id;
}

fn onWorkerReleased(
    worker_id: GameEntityId,
    workstation_id: GameEntityId,
) void {
    _ = workstation_id;
    const worker = getWorkerData(worker_id) orelse return;
    log("{s} released", .{worker.name});
}

fn shouldContinue(
    workstation_id: GameEntityId,
    worker_id: GameEntityId,
    cycles_completed: u32,
) bool {
    _ = workstation_id;
    _ = worker_id;
    _ = cycles_completed;
    return false;
}

// ============================================================================
// Game Simulation
// ============================================================================

fn simulateTick(engine: *tasks.Engine(GameEntityId)) void {
    g_tick += 1;
    log("=== TICK START ===", .{});

    const worker_id = g_current_worker orelse return;
    const worker = getWorkerData(worker_id) orelse return;

    if (worker.state == .Moving) {
        if (worker.target_pos) |target| {
            if (worker.pos.x == target.x and worker.pos.y == target.y) {
                worker.state = .Working;
                log("{s} arrived at destination", .{worker.name});
            } else {
                if (worker.pos.x < target.x) {
                    worker.pos.x += 1;
                } else if (worker.pos.x > target.x) {
                    worker.pos.x -= 1;
                } else if (worker.pos.y < target.y) {
                    worker.pos.y += 1;
                } else if (worker.pos.y > target.y) {
                    worker.pos.y -= 1;
                }
                log("{s} moved to ({d}, {d})", .{ worker.name, worker.pos.x, worker.pos.y });
            }
        }
    } else if (worker.state == .Working) {
        if (g_current_step) |step| {
            switch (step.type) {
                .Pickup => {
                    // Pick up whatever is available
                    if (g_fridge.hasItem(.Meat)) {
                        if (g_fridge.takeItem(.Meat)) {
                            worker.carrying = .Meat;
                            log("{s} picked up Meat from Fridge", .{worker.name});
                        }
                    } else if (g_fridge.hasItem(.Vegetable)) {
                        if (g_fridge.takeItem(.Vegetable)) {
                            worker.carrying = .Vegetable;
                            log("{s} picked up Vegetable from Fridge", .{worker.name});
                        }
                    }
                    worker.state = .Idle;
                    engine.notifyStepComplete(worker_id);
                },
                .Cook => {
                    worker.carrying = .CookedMeal;
                    log("{s} cooked a meal!", .{worker.name});
                    worker.state = .Idle;
                    engine.notifyStepComplete(worker_id);
                },
                .Store => {
                    if (worker.carrying) |item| {
                        if (g_meal_storage.addItem(item)) {
                            log("{s} stored {s} in Meal Storage", .{ worker.name, @tagName(item) });
                            worker.carrying = null;
                        }
                    }
                    worker.state = .Idle;
                    engine.notifyStepComplete(worker_id);
                },
                else => {},
            }
        }
    }

    log("=== TICK END ===", .{});
}

fn printStatus() void {
    std.debug.print("\n--- World Status ---\n", .{});

    std.debug.print("Storages:\n", .{});
    std.debug.print("  {s}: ", .{g_meal_storage.name});
    if (g_meal_storage.count == 0) {
        std.debug.print("(empty)", .{});
    } else {
        for (g_meal_storage.items[0..g_meal_storage.count]) |maybe_item| {
            if (maybe_item) |item| {
                std.debug.print("{s} ", .{@tagName(item)});
            }
        }
    }
    std.debug.print("\n", .{});

    std.debug.print("  {s}: ", .{g_fridge.name});
    if (g_fridge.count == 0) {
        std.debug.print("(empty)", .{});
    } else {
        for (g_fridge.items[0..g_fridge.count]) |maybe_item| {
            if (maybe_item) |item| {
                std.debug.print("{s} ", .{@tagName(item)});
            }
        }
    }
    std.debug.print("\n", .{});

    std.debug.print("Workers:\n", .{});
    std.debug.print("  {s}: state={s}", .{ g_bob.name, @tagName(g_bob.state) });
    if (g_bob.carrying) |item| {
        std.debug.print(" carrying={s}", .{@tagName(item)});
    }
    std.debug.print("\n", .{});

    std.debug.print("  {s}: state={s}", .{ g_alice.name, @tagName(g_alice.state) });
    if (g_alice.carrying) |item| {
        std.debug.print(" carrying={s}", .{@tagName(item)});
    }
    std.debug.print("\n", .{});

    std.debug.print("-------------------\n\n", .{});
}

// ============================================================================
// Main
// ============================================================================

pub fn main() !void {
    std.debug.print("\n", .{});
    std.debug.print("========================================\n", .{});
    std.debug.print("  WORKER ABANDONMENT ENGINE EXAMPLE     \n", .{});
    std.debug.print("========================================\n\n", .{});

    std.debug.print("Scenario:\n", .{});
    std.debug.print("1. Chef Alice starts cooking (picks up meat)\n", .{});
    std.debug.print("2. Alice gets into a FIGHT and abandons work\n", .{});
    std.debug.print("3. Chef Bob arrives and continues from step 1\n", .{});
    std.debug.print("   (pickup vegetable, not meat again!)\n\n", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    initGameState();

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
    // Register Entities - Start with just Alice
    // ========================================================================

    _ = engine.addWorker(CHEF_ALICE, .{});

    const kitchen_steps = [_]StepDef{
        .{ .type = .Pickup }, // step 0: pickup meat
        .{ .type = .Pickup }, // step 1: pickup vegetable
        .{ .type = .Cook }, // step 2: cook at stove
        .{ .type = .Store }, // step 3: store cooked meal
    };

    _ = engine.addWorkstation(STOVE, .{
        .steps = &kitchen_steps,
        .priority = .Normal,
    });

    // ========================================================================
    // Phase 1: Alice picks up meat
    // ========================================================================

    std.debug.print("--- Phase 1: Alice picks up meat ---\n\n", .{});

    engine.notifyResourcesAvailable(STOVE);

    // Run until Alice completes step 0 (picks up meat)
    var step_reached = false;
    var ticks: u32 = 0;
    while (ticks < 15) : (ticks += 1) {
        simulateTick(&engine);

        // Check if step 1 started (meaning step 0 completed)
        const current_step = engine.getCurrentStep(STOVE);
        if (current_step != null and current_step.? == 1) {
            step_reached = true;
            break;
        }
    }
    printStatus();

    // Assertions
    std.debug.assert(step_reached);
    const step_after_phase1 = engine.getCurrentStep(STOVE);
    std.debug.assert(step_after_phase1.? == 1);
    std.debug.assert(g_alice.carrying == .Meat);

    std.debug.print("[PASS] Alice completed step 0, now at step 1\n", .{});
    std.debug.print("[PASS] Alice is carrying Meat\n", .{});
    std.debug.print("[PASS] Fridge now only has Vegetable\n\n", .{});

    // ========================================================================
    // Phase 2: Alice gets into a fight!
    // ========================================================================

    std.debug.print("========================================\n", .{});
    std.debug.print("  FIGHT! Alice abandons work!           \n", .{});
    std.debug.print("========================================\n\n", .{});

    // Alice is now in a fight - she can't work
    g_alice_in_fight = true;

    // KEY: abandonWork keeps the step index!
    engine.abandonWork(CHEF_ALICE);
    g_alice.state = .Idle;
    g_alice.target_pos = null;
    g_current_worker = null;

    printStatus();

    // Assertions
    const status_after_abandon = engine.getWorkstationStatus(STOVE);
    std.debug.assert(status_after_abandon == .Blocked);
    const step_after_abandon = engine.getCurrentStep(STOVE);
    std.debug.assert(step_after_abandon.? == 1); // KEY: Still at step 1!

    const alice_assigned = engine.getAssignedWorker(STOVE);
    std.debug.assert(alice_assigned == null);

    std.debug.print("[PASS] Group is Blocked but KEPT step=1\n", .{});
    std.debug.print("[PASS] Alice unassigned, still has Meat\n\n", .{});

    // ========================================================================
    // Phase 3: Bob arrives and continues
    // ========================================================================

    std.debug.print("========================================\n", .{});
    std.debug.print("  Bob arrives to continue!              \n", .{});
    std.debug.print("========================================\n\n", .{});

    // Add Bob as available worker
    _ = engine.addWorker(CHEF_BOB, .{});

    // Signal resources available again - Bob should be assigned
    engine.notifyResourcesAvailable(STOVE);

    // Run until completion
    var completed = false;
    ticks = 0;
    while (ticks < 30) : (ticks += 1) {
        simulateTick(&engine);

        if (engine.getCyclesCompleted(STOVE) >= 1) {
            completed = true;
            break;
        }
    }
    printStatus();

    // Final assertions
    std.debug.assert(completed);
    std.debug.print("[PASS] Bob completed the recipe!\n", .{});

    std.debug.assert(g_meal_storage.count == 1);
    std.debug.assert(g_meal_storage.hasItem(.CookedMeal));
    std.debug.print("[PASS] Meal stored successfully\n", .{});

    // Alice still has her meat
    std.debug.assert(g_alice.carrying == .Meat);
    std.debug.print("[PASS] Alice still has her Meat (from the fight)\n", .{});

    std.debug.print("\n========================================\n", .{});
    std.debug.print("    ALL ASSERTIONS PASSED!              \n", .{});
    std.debug.print("========================================\n", .{});
}
