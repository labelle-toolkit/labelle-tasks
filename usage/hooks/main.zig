//! Hook System Example
//!
//! Demonstrates the labelle-tasks hook system with the storage-based API:
//! - Defining hook handlers for task engine events
//! - Using EngineWithHooks for hook-based integration
//! - Observing pickup, process, store, and cycle events
//!
//! This example shows a simple bakery where a baker picks up flour,
//! processes it into bread, and stores the bread.

const std = @import("std");
const tasks = @import("labelle_tasks");

// ============================================================================
// Game Types
// ============================================================================

const GameId = u32;

const Item = enum {
    Flour,
    Bread,
};

// Entity IDs
const BAKER: GameId = 1;
const BAKERY: GameId = 10;
const FLOUR_STORAGE: GameId = 100; // EIS
const DOUGH_BOWL: GameId = 101; // IIS
const OVEN_TRAY: GameId = 102; // IOS
const BREAD_BASKET: GameId = 103; // EOS

// ============================================================================
// Hook Handlers
// ============================================================================
// Define handlers for task engine events.
// Each function name matches the hook name.

const BakeryHooks = struct {
    // Statistics for assertions
    var pickups_started: u32 = 0;
    var processes_started: u32 = 0;
    var processes_completed: u32 = 0;
    var stores_started: u32 = 0;
    var workers_released: u32 = 0;
    var cycles_completed: u32 = 0;

    fn reset() void {
        pickups_started = 0;
        processes_started = 0;
        processes_completed = 0;
        stores_started = 0;
        workers_released = 0;
        cycles_completed = 0;
    }

    pub fn pickup_started(payload: tasks.hooks.HookPayload(GameId, Item)) void {
        const info = payload.pickup_started;
        pickups_started += 1;
        std.debug.print("[hook] pickup_started: baker={d} picking from storage={d}\n", .{
            info.worker_id,
            info.eis_id,
        });
    }

    pub fn process_started(payload: tasks.hooks.HookPayload(GameId, Item)) void {
        const info = payload.process_started;
        processes_started += 1;
        std.debug.print("[hook] process_started: baker={d} processing at bakery={d}\n", .{
            info.worker_id,
            info.workstation_id,
        });
    }

    pub fn process_completed(payload: tasks.hooks.HookPayload(GameId, Item)) void {
        const info = payload.process_completed;
        processes_completed += 1;
        std.debug.print("[hook] process_completed: baker={d} finished at bakery={d}\n", .{
            info.worker_id,
            info.workstation_id,
        });
    }

    pub fn store_started(payload: tasks.hooks.HookPayload(GameId, Item)) void {
        const info = payload.store_started;
        stores_started += 1;
        std.debug.print("[hook] store_started: baker={d} storing to basket={d}\n", .{
            info.worker_id,
            info.eos_id,
        });
    }

    pub fn worker_released(payload: tasks.hooks.HookPayload(GameId, Item)) void {
        const info = payload.worker_released;
        workers_released += 1;
        std.debug.print("[hook] worker_released: baker={d} released from bakery={d}\n", .{
            info.worker_id,
            info.workstation_id,
        });
    }

    pub fn cycle_completed(payload: tasks.hooks.HookPayload(GameId, Item)) void {
        const info = payload.cycle_completed;
        cycles_completed += 1;
        std.debug.print("[hook] cycle_completed: bakery={d} completed cycle {d}\n", .{
            info.workstation_id,
            info.cycles_completed,
        });
    }
};

// ============================================================================
// Create the Dispatcher and Engine
// ============================================================================

const Dispatcher = tasks.hooks.HookDispatcher(GameId, Item, BakeryHooks);
const TaskEngine = tasks.EngineWithHooks(GameId, Item, Dispatcher);

// ============================================================================
// Callbacks (still needed for worker selection)
// ============================================================================

fn findBestWorker(
    _: ?GameId,
    available_workers: []const GameId,
) ?GameId {
    if (available_workers.len > 0) {
        return available_workers[0];
    }
    return null;
}

// ============================================================================
// Main
// ============================================================================

pub fn main() !void {
    std.debug.print("\n", .{});
    std.debug.print("========================================\n", .{});
    std.debug.print("  HOOK SYSTEM EXAMPLE (Storage API)     \n", .{});
    std.debug.print("========================================\n\n", .{});

    std.debug.print("This example demonstrates:\n", .{});
    std.debug.print("- Hook-based event observation\n", .{});
    std.debug.print("- Storage-based workflow (EIS -> IIS -> IOS -> EOS)\n", .{});
    std.debug.print("- EngineWithHooks for automatic hook emission\n", .{});
    std.debug.print("\n", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Reset hook counters
    BakeryHooks.reset();

    // ========================================================================
    // Initialize Engine with Hooks
    // ========================================================================

    var engine = TaskEngine.init(allocator);
    defer engine.deinit();

    engine.setFindBestWorker(findBestWorker);

    // ========================================================================
    // Setup: Create storages and workstation
    // ========================================================================

    std.debug.print("--- Setup ---\n", .{});
    std.debug.print("Creating bakery with:\n", .{});
    std.debug.print("- Flour storage (EIS) with 5 flour\n", .{});
    std.debug.print("- Dough bowl (IIS) for 1 flour -> 1 bread\n", .{});
    std.debug.print("- Oven tray (IOS) for 1 bread output\n", .{});
    std.debug.print("- Bread basket (EOS)\n", .{});
    std.debug.print("- Process time: 3 ticks\n\n", .{});

    // EIS: External Input Storage (flour supply)
    _ = engine.addStorage(FLOUR_STORAGE, .{ .item = .Flour });
    _ = engine.addToStorage(FLOUR_STORAGE, .Flour, 5);

    // IIS: Internal Input Storage (recipe - 1 flour per cycle)
    _ = engine.addStorage(DOUGH_BOWL, .{ .item = .Flour });

    // IOS: Internal Output Storage (produces 1 bread per cycle)
    _ = engine.addStorage(OVEN_TRAY, .{ .item = .Bread });

    // EOS: External Output Storage (bread basket)
    _ = engine.addStorage(BREAD_BASKET, .{ .item = .Bread });

    // Workstation
    _ = engine.addWorkstation(BAKERY, .{
        .eis = &.{FLOUR_STORAGE},
        .iis = &.{DOUGH_BOWL},
        .ios = &.{OVEN_TRAY},
        .eos = &.{BREAD_BASKET},
        .process_duration = 3,
        .priority = .High,
    });

    // Worker
    _ = engine.addWorker(BAKER, .{});

    // ========================================================================
    // Simulate
    // ========================================================================

    std.debug.print("--- Simulation ---\n\n", .{});

    // Signal worker is idle to start
    std.debug.print("[Tick 0] Baker becomes idle, looking for work...\n\n", .{});
    engine.notifyWorkerIdle(BAKER);

    // Run simulation for multiple cycles
    var tick: u32 = 0;
    const max_ticks: u32 = 50;

    while (tick < max_ticks) {
        tick += 1;

        // Update process timers
        engine.update();

        // Simulate worker actions based on current state
        if (engine.getWorkerState(BAKER)) |state| {
            if (state == .Working) {
                // Check if worker is in pickup or store step
                if (engine.getWorkstationStatus(BAKERY)) |ws_status| {
                    _ = ws_status;
                    // Simulate instant pickup/store completion after 1 tick delay
                    // In a real game, this would be based on movement completion
                }
            }
        }

        // Simple simulation: complete pickup/store after being assigned
        // Check cycle progress
        const current_step = blk: {
            // Access internal state via base engine
            const ws_id = engine.base.workstation_by_game_id.get(BAKERY) orelse break :blk null;
            const ws = engine.base.workstations.get(ws_id) orelse break :blk null;
            break :blk ws.current_step;
        };

        if (current_step) |step| {
            switch (step) {
                .Pickup => {
                    // Complete pickup after 1 tick
                    if (tick % 2 == 0) {
                        std.debug.print("[Tick {d}] Baker completes pickup\n", .{tick});
                        engine.notifyPickupComplete(BAKER);
                    }
                },
                .Process => {
                    // Process is automatic via update()
                },
                .Store => {
                    // Complete store after 1 tick
                    std.debug.print("[Tick {d}] Baker completes store\n", .{tick});
                    engine.notifyStoreComplete(BAKER);
                },
            }
        }

        // Check if we've made enough bread
        const bread_count = engine.getStorageQuantity(BREAD_BASKET, .Bread);
        if (bread_count >= 3) {
            std.debug.print("\n[Tick {d}] Bread basket full! ({d} bread)\n", .{ tick, bread_count });
            break;
        }
    }

    // ========================================================================
    // Assertions
    // ========================================================================

    std.debug.print("\n--- Assertions ---\n\n", .{});

    std.debug.print("Hook statistics:\n", .{});
    std.debug.print("  pickups_started: {d}\n", .{BakeryHooks.pickups_started});
    std.debug.print("  processes_started: {d}\n", .{BakeryHooks.processes_started});
    std.debug.print("  processes_completed: {d}\n", .{BakeryHooks.processes_completed});
    std.debug.print("  stores_started: {d}\n", .{BakeryHooks.stores_started});
    std.debug.print("  workers_released: {d}\n", .{BakeryHooks.workers_released});
    std.debug.print("  cycles_completed: {d}\n", .{BakeryHooks.cycles_completed});
    std.debug.print("\n", .{});

    // Verify hooks were called
    std.debug.assert(BakeryHooks.cycles_completed >= 1);
    std.debug.print("[PASS] At least 1 cycle completed\n", .{});

    std.debug.assert(BakeryHooks.pickups_started >= 1);
    std.debug.print("[PASS] At least 1 pickup started\n", .{});

    std.debug.assert(BakeryHooks.processes_completed >= 1);
    std.debug.print("[PASS] At least 1 process completed\n", .{});

    // Verify final state
    const final_bread = engine.getStorageQuantity(BREAD_BASKET, .Bread);
    std.debug.assert(final_bread >= 1);
    std.debug.print("[PASS] Bread basket has {d} bread\n", .{final_bread});

    std.debug.print("\n========================================\n", .{});
    std.debug.print("    ALL ASSERTIONS PASSED!              \n", .{});
    std.debug.print("========================================\n\n", .{});

    // ========================================================================
    // Integration Pattern
    // ========================================================================

    std.debug.print("--- labelle-engine Integration Pattern ---\n\n", .{});
    std.debug.print("When integrating with labelle-engine:\n\n", .{});
    std.debug.print("  const TasksPlugin = struct {{\n", .{});
    std.debug.print("      pub const EngineHooks = struct {{\n", .{});
    std.debug.print("          pub fn frame_start(payload: engine.HookPayload) void {{\n", .{});
    std.debug.print("              task_engine.update(payload.frame_start.dt);\n", .{});
    std.debug.print("          }}\n", .{});
    std.debug.print("      }};\n", .{});
    std.debug.print("  }};\n\n", .{});
    std.debug.print("  const AllHooks = engine.MergeEngineHooks(.{{ GameHooks, TasksPlugin.EngineHooks }});\n", .{});
    std.debug.print("  const Game = engine.GameWith(AllHooks);\n", .{});
}
