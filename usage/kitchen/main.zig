//! Kitchen Engine Example
//!
//! Demonstrates the Engine API with a kitchen workflow:
//! - Worker picks up ingredients from storage (Fridge has higher priority than Pantry)
//! - Worker cooks at the stove
//! - Worker stores finished meal (High priority storage preferred)
//!
//! Shows how game callbacks integrate with the Engine for:
//! - Finding best worker (distance-based)
//! - Starting steps (movement, animations)
//! - Completing steps

const std = @import("std");
const tasks = @import("labelle_tasks");

const StepType = tasks.Components.StepType;
const Priority = tasks.Components.Priority;

// ============================================================================
// Game Entity IDs
// ============================================================================

const GameEntityId = u32;

const CHEF_BOB: GameEntityId = 1;
const STOVE: GameEntityId = 100;

// ============================================================================
// Game State - Simulated World
// ============================================================================

const Position = struct { x: i32, y: i32 };

const ItemType = enum {
    Meat,
    Vegetable,
    CookedMeal,
};

const StorageData = struct {
    name: []const u8,
    pos: Position,
    priority: Priority,
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
var g_pantry: StorageData = undefined;
var g_meal_storage_high: StorageData = undefined;
var g_meal_storage_low: StorageData = undefined;
var g_chef: WorkerData = undefined;
var g_stove_pos: Position = undefined;

// Current step tracking
var g_current_step: ?StepDef = null;
var g_current_step_index: u8 = 0;

fn initGameState() void {
    g_fridge = .{
        .name = "Fridge",
        .pos = .{ .x = 0, .y = 5 },
        .priority = .High,
    };
    _ = g_fridge.addItem(.Meat);
    _ = g_fridge.addItem(.Vegetable);

    g_pantry = .{
        .name = "Pantry",
        .pos = .{ .x = 0, .y = 0 },
        .priority = .Normal,
    };
    _ = g_pantry.addItem(.Meat);
    _ = g_pantry.addItem(.Vegetable);
    _ = g_pantry.addItem(.Meat);
    _ = g_pantry.addItem(.Vegetable);

    g_meal_storage_high = .{
        .name = "Meal Storage (High)",
        .pos = .{ .x = 10, .y = 0 },
        .priority = .High,
    };

    g_meal_storage_low = .{
        .name = "Meal Storage (Low)",
        .pos = .{ .x = 10, .y = 5 },
        .priority = .Low,
    };

    g_chef = .{
        .name = "Chef Bob",
        .pos = .{ .x = 5, .y = 5 },
    };

    g_stove_pos = .{ .x = 5, .y = 0 };
}

fn distance(a: Position, b: Position) i32 {
    const dx = if (a.x > b.x) a.x - b.x else b.x - a.x;
    const dy = if (a.y > b.y) a.y - b.y else b.y - a.y;
    return dx + dy;
}

fn findStorageWithItem(item_type: ItemType) ?*StorageData {
    var best: ?*StorageData = null;
    var best_priority: ?Priority = null;

    const storages = [_]*StorageData{ &g_fridge, &g_pantry };
    for (storages) |storage| {
        if (storage.hasItem(item_type)) {
            if (best_priority == null or @intFromEnum(storage.priority) > @intFromEnum(best_priority.?)) {
                best = storage;
                best_priority = storage.priority;
            }
        }
    }
    return best;
}

fn findStorageForMeal() ?*StorageData {
    var best: ?*StorageData = null;
    var best_priority: ?Priority = null;

    const storages = [_]*StorageData{ &g_meal_storage_high, &g_meal_storage_low };
    for (storages) |storage| {
        if (storage.count < 10) {
            if (best_priority == null or @intFromEnum(storage.priority) > @intFromEnum(best_priority.?)) {
                best = storage;
                best_priority = storage.priority;
            }
        }
    }
    return best;
}

fn log(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("[Tick {d:3}] " ++ fmt ++ "\n", .{g_tick} ++ args);
}

// ============================================================================
// Engine Callbacks
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

    g_current_step = step;

    switch (step.type) {
        .Pickup => {
            // Determine which item to pickup based on step index
            const item_type: ItemType = if (g_current_step_index == 0) .Meat else .Vegetable;
            if (findStorageWithItem(item_type)) |storage| {
                g_chef.target_pos = storage.pos;
                g_chef.state = .Moving;
                log("{s} moving to {s} to pickup {s}", .{ g_chef.name, storage.name, @tagName(item_type) });
            }
        },
        .Cook => {
            g_chef.target_pos = g_stove_pos;
            g_chef.state = .Moving;
            log("{s} moving to Stove to cook", .{g_chef.name});
        },
        .Store => {
            if (findStorageForMeal()) |storage| {
                g_chef.target_pos = storage.pos;
                g_chef.state = .Moving;
                log("{s} moving to {s} to store meal", .{ g_chef.name, storage.name });
            }
        },
        else => {},
    }
}

fn onStepCompleted(
    worker_id: GameEntityId,
    workstation_id: GameEntityId,
    step: StepDef,
) void {
    _ = worker_id;
    _ = workstation_id;

    g_current_step_index += 1;
    log("{s} completed {s}", .{ g_chef.name, @tagName(step.type) });
}

fn onWorkerReleased(
    worker_id: GameEntityId,
    workstation_id: GameEntityId,
) void {
    _ = worker_id;
    _ = workstation_id;
    log("{s} released from stove", .{g_chef.name});
}

fn shouldContinue(
    workstation_id: GameEntityId,
    worker_id: GameEntityId,
    cycles_completed: u32,
) bool {
    _ = workstation_id;
    _ = worker_id;
    _ = cycles_completed;
    // Just do 1 cycle
    return false;
}

// ============================================================================
// Game Simulation
// ============================================================================

fn simulateTick(engine: *tasks.Engine(GameEntityId)) bool {
    g_tick += 1;
    log("=== TICK START ===", .{});

    // Move worker if needed
    if (g_chef.state == .Moving) {
        if (g_chef.target_pos) |target| {
            if (g_chef.pos.x == target.x and g_chef.pos.y == target.y) {
                // Arrived
                g_chef.state = .Working;
                log("{s} arrived at destination", .{g_chef.name});
            } else {
                // Move one step
                if (g_chef.pos.x < target.x) {
                    g_chef.pos.x += 1;
                } else if (g_chef.pos.x > target.x) {
                    g_chef.pos.x -= 1;
                } else if (g_chef.pos.y < target.y) {
                    g_chef.pos.y += 1;
                } else if (g_chef.pos.y > target.y) {
                    g_chef.pos.y -= 1;
                }
                log("{s} moved to ({d}, {d})", .{ g_chef.name, g_chef.pos.x, g_chef.pos.y });
            }
        }
    } else if (g_chef.state == .Working) {
        // Perform work based on current step
        if (g_current_step) |step| {
            switch (step.type) {
                .Pickup => {
                    const item_type: ItemType = if (g_current_step_index == 0) .Meat else .Vegetable;
                    if (findStorageWithItem(item_type)) |storage| {
                        if (storage.takeItem(item_type)) {
                            g_chef.carrying = item_type;
                            log("{s} picked up {s} from {s}", .{ g_chef.name, @tagName(item_type), storage.name });
                        }
                    }
                    g_chef.state = .Idle;
                    engine.notifyStepComplete(CHEF_BOB);
                },
                .Cook => {
                    g_chef.carrying = .CookedMeal;
                    log("{s} cooked a meal!", .{g_chef.name});
                    g_chef.state = .Idle;
                    engine.notifyStepComplete(CHEF_BOB);
                },
                .Store => {
                    if (findStorageForMeal()) |storage| {
                        if (g_chef.carrying) |item| {
                            if (storage.addItem(item)) {
                                log("{s} stored {s} in {s} (priority: {s})", .{
                                    g_chef.name,
                                    @tagName(item),
                                    storage.name,
                                    @tagName(storage.priority),
                                });
                                g_chef.carrying = null;
                            }
                        }
                    }
                    g_chef.state = .Idle;
                    engine.notifyStepComplete(CHEF_BOB);
                },
                else => {},
            }
        }
    }

    log("=== TICK END ===", .{});
    printStatus();

    // Return true if cycle complete
    return engine.getCyclesCompleted(STOVE) >= 1;
}

fn printStatus() void {
    std.debug.print("\n--- World Status ---\n", .{});

    std.debug.print("Storages:\n", .{});
    const storages = [_]*StorageData{ &g_meal_storage_low, &g_meal_storage_high, &g_fridge, &g_pantry };
    for (storages) |storage| {
        std.debug.print("  {s} (priority: {s}): ", .{ storage.name, @tagName(storage.priority) });
        if (storage.count == 0) {
            std.debug.print("(empty)", .{});
        } else {
            for (storage.items[0..storage.count]) |maybe_item| {
                if (maybe_item) |item| {
                    std.debug.print("{s} ", .{@tagName(item)});
                }
            }
        }
        std.debug.print("\n", .{});
    }

    std.debug.print("Workers:\n", .{});
    std.debug.print("  {s} at ({d},{d}) state={s}", .{
        g_chef.name,
        g_chef.pos.x,
        g_chef.pos.y,
        @tagName(g_chef.state),
    });
    if (g_chef.carrying) |item| {
        std.debug.print(" carrying={s}", .{@tagName(item)});
    }
    std.debug.print("\n", .{});

    std.debug.print("-------------------\n\n", .{});
}

// ============================================================================
// Main
// ============================================================================

pub fn main() !void {
    std.debug.print("\n========================================\n", .{});
    std.debug.print("  KITCHEN ENGINE EXAMPLE                \n", .{});
    std.debug.print("========================================\n\n", .{});

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
    // Register Entities
    // ========================================================================

    _ = engine.addWorker(CHEF_BOB, .{});

    const kitchen_steps = [_]StepDef{
        .{ .type = .Pickup }, // pickup meat
        .{ .type = .Pickup }, // pickup vegetable
        .{ .type = .Cook }, // cook at stove
        .{ .type = .Store }, // store cooked meal
    };

    _ = engine.addWorkstation(STOVE, .{
        .steps = &kitchen_steps,
        .priority = .Normal,
    });

    // ========================================================================
    // Initial Assertions
    // ========================================================================

    std.debug.print("Verifying initial state...\n", .{});

    std.debug.assert(g_fridge.priority == .High);
    std.debug.assert(g_pantry.priority == .Normal);
    std.debug.assert(g_fridge.count == 2);
    std.debug.assert(g_pantry.count == 4);
    std.debug.assert(g_meal_storage_high.count == 0);
    std.debug.assert(g_meal_storage_low.count == 0);
    std.debug.assert(g_chef.state == .Idle);
    std.debug.assert(g_chef.carrying == null);

    std.debug.print("Initial state verified!\n\n", .{});

    std.debug.print("Running simulation...\n", .{});
    std.debug.print("- Fridge (High priority) has Meat and Vegetable\n", .{});
    std.debug.print("- Pantry (Normal priority) has Meat, Vegetable, Meat, Vegetable\n", .{});
    std.debug.print("- Worker should pick from Fridge first (higher priority)\n", .{});
    std.debug.print("- Worker should store in Meal Storage (High) first\n\n", .{});

    // ========================================================================
    // Run Simulation
    // ========================================================================

    // Signal resources available
    engine.notifyResourcesAvailable(STOVE);

    var max_ticks: u32 = 50;
    while (max_ticks > 0) : (max_ticks -= 1) {
        if (simulateTick(&engine)) {
            std.debug.print("\n=== Cycle complete at tick {d}! ===\n\n", .{g_tick});
            break;
        }
    }

    // ========================================================================
    // Final Assertions
    // ========================================================================

    std.debug.print("Verifying final state...\n", .{});

    // Fridge should be depleted (high priority)
    std.debug.assert(g_fridge.count == 0);
    std.debug.print("  [PASS] Fridge (High priority) was depleted first\n", .{});

    // Pantry should still have items
    std.debug.assert(g_pantry.count == 4);
    std.debug.print("  [PASS] Pantry (Normal priority) was not touched\n", .{});

    // Meal stored in high priority storage
    std.debug.assert(g_meal_storage_high.count == 1);
    std.debug.assert(g_meal_storage_high.hasItem(.CookedMeal));
    std.debug.print("  [PASS] Meal stored in Meal Storage (High priority)\n", .{});

    // Low priority storage not used
    std.debug.assert(g_meal_storage_low.count == 0);
    std.debug.print("  [PASS] Meal Storage (Low priority) was not used\n", .{});

    // Worker idle
    std.debug.assert(g_chef.state == .Idle);
    std.debug.assert(g_chef.carrying == null);
    std.debug.print("  [PASS] Worker is idle with no items\n", .{});

    // Engine state
    const cycles = engine.getCyclesCompleted(STOVE);
    std.debug.assert(cycles == 1);
    std.debug.print("  [PASS] Stove completed 1 cycle\n", .{});

    const worker_state = engine.getWorkerState(CHEF_BOB);
    std.debug.assert(worker_state.? == .Idle);
    std.debug.print("  [PASS] Worker is idle in engine\n", .{});

    std.debug.print("\n========================================\n", .{});
    std.debug.print("    ALL ASSERTIONS PASSED!              \n", .{});
    std.debug.print("========================================\n", .{});
}
