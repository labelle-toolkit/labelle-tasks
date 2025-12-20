//! Farm Game Example
//!
//! A simple farm game demonstrating labelle-tasks engine:
//! - Farmers harvest crops from fields
//! - Crops are stored in a barn
//! - A mill processes wheat into flour
//!
//! Shows the complete engine workflow with multiple workers and workstations.

const std = @import("std");
const tasks = @import("labelle_tasks");

// ============================================================================
// Game Types
// ============================================================================

const EntityId = u32;

const Item = enum {
    Wheat,
    Carrot,
    Flour,
};

const Engine = tasks.Engine(EntityId, Item);

// ============================================================================
// Entity IDs
// ============================================================================

const Entities = struct {
    // Workers
    const farmer_alice: EntityId = 1;
    const farmer_bob: EntityId = 2;

    // Storages
    const wheat_field: EntityId = 10;
    const carrot_field: EntityId = 11;
    const barn: EntityId = 20;
    const mill_input: EntityId = 30;
    const mill_output: EntityId = 31;
    const flour_storage: EntityId = 40;

    // Workstations
    const mill: EntityId = 100;
};

// ============================================================================
// Game State
// ============================================================================

const WorkerState = struct {
    location: Location = .barn,
    timer: u32 = 0,
    carrying: ?Item = null,
    doing_store: bool = false,
};

const Location = enum {
    barn,
    wheat_field,
    carrot_field,
    mill,
    walking,
};

const WALK_TIME: u32 = 3;
const MILL_TIME: u32 = 5;

var g_workers: std.AutoHashMap(EntityId, WorkerState) = undefined;
var g_engine: *Engine = undefined;
var g_tick: u32 = 0;

fn initGame(allocator: std.mem.Allocator, engine: *Engine) void {
    g_workers = std.AutoHashMap(EntityId, WorkerState).init(allocator);
    g_workers.put(Entities.farmer_alice, .{}) catch {};
    g_workers.put(Entities.farmer_bob, .{}) catch {};
    g_engine = engine;
}

fn deinitGame() void {
    g_workers.deinit();
}

fn workerName(id: EntityId) []const u8 {
    return switch (id) {
        Entities.farmer_alice => "Alice",
        Entities.farmer_bob => "Bob",
        else => "Unknown",
    };
}

fn itemName(item: Item) []const u8 {
    return switch (item) {
        .Wheat => "wheat",
        .Carrot => "carrot",
        .Flour => "flour",
    };
}

// ============================================================================
// Engine Callbacks
// ============================================================================

fn findBestWorker(_: ?EntityId, available: []const EntityId) ?EntityId {
    // Return first available worker
    return if (available.len > 0) available[0] else null;
}

fn onPickupStarted(worker_id: EntityId, _: EntityId, _: EntityId) void {
    const worker = g_workers.getPtr(worker_id) orelse return;
    worker.location = .walking;
    worker.timer = WALK_TIME;

    log("{s} walking to pick up ingredients", .{workerName(worker_id)});
}

fn onProcessStarted(worker_id: EntityId, workstation_id: EntityId) void {
    const worker = g_workers.getPtr(worker_id) orelse return;
    worker.location = .mill;

    if (workstation_id == Entities.mill) {
        log("{s} started milling wheat", .{workerName(worker_id)});
    }
}

fn onProcessComplete(worker_id: EntityId, workstation_id: EntityId) void {
    if (workstation_id == Entities.mill) {
        log("{s} finished milling - flour ready!", .{workerName(worker_id)});
    }
}

fn onStoreStarted(worker_id: EntityId, _: EntityId, _: EntityId) void {
    const worker = g_workers.getPtr(worker_id) orelse return;
    worker.location = .walking;
    worker.timer = WALK_TIME;
    worker.doing_store = true;

    log("{s} carrying flour to storage", .{workerName(worker_id)});
}

fn onTransportStarted(worker_id: EntityId, from_id: EntityId, to_id: EntityId, item: Item) void {
    const worker = g_workers.getPtr(worker_id) orelse return;
    worker.location = .walking;
    worker.timer = WALK_TIME;
    worker.carrying = item;

    const from = switch (from_id) {
        Entities.wheat_field => "wheat field",
        Entities.carrot_field => "carrot field",
        Entities.flour_storage => "flour storage",
        else => "storage",
    };
    const to = switch (to_id) {
        Entities.barn => "barn",
        Entities.mill_input => "mill",
        else => "storage",
    };

    log("{s} transporting {s} from {s} to {s}", .{
        workerName(worker_id),
        itemName(item),
        from,
        to,
    });
}

fn onWorkerReleased(worker_id: EntityId, _: EntityId) void {
    const worker = g_workers.getPtr(worker_id) orelse return;
    worker.location = .barn;
    worker.carrying = null;

    log("{s} returned to barn", .{workerName(worker_id)});
}

// ============================================================================
// Game Loop
// ============================================================================

fn update() void {
    g_tick += 1;

    // Update engine timers
    g_engine.update();

    // Update worker timers
    var iter = g_workers.iterator();
    while (iter.next()) |entry| {
        const worker = entry.value_ptr;
        if (worker.timer > 0) {
            worker.timer -= 1;
            if (worker.timer == 0) {
                handleWorkerArrived(entry.key_ptr.*);
            }
        }
    }
}

fn handleWorkerArrived(worker_id: EntityId) void {
    const worker = g_workers.getPtr(worker_id) orelse return;

    if (worker.carrying != null) {
        // Was transporting - notify completion
        worker.carrying = null;
        worker.location = .barn;
        g_engine.notifyTransportComplete(worker_id);
    } else if (worker.doing_store) {
        // Was storing - notify completion
        worker.doing_store = false;
        worker.location = .barn;
        g_engine.notifyStoreComplete(worker_id);
    } else if (worker.location == .walking) {
        // Arrived at pickup location
        g_engine.notifyPickupComplete(worker_id);
    }
}

fn log(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("[{d:4}] ", .{g_tick});
    std.debug.print(fmt ++ "\n", args);
}

// ============================================================================
// Main
// ============================================================================

pub fn main() !void {
    std.debug.print("\n", .{});
    std.debug.print("========================================\n", .{});
    std.debug.print("  FARM GAME - labelle-tasks demo        \n", .{});
    std.debug.print("========================================\n\n", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize engine
    var engine = Engine.init(allocator);
    defer engine.deinit();

    initGame(allocator, &engine);
    defer deinitGame();

    // Set callbacks
    engine.setFindBestWorker(findBestWorker);
    engine.setOnPickupStarted(onPickupStarted);
    engine.setOnProcessStarted(onProcessStarted);
    engine.setOnProcessComplete(onProcessComplete);
    engine.setOnStoreStarted(onStoreStarted);
    engine.setOnTransportStarted(onTransportStarted);
    engine.setOnWorkerReleased(onWorkerReleased);

    // ========================================================================
    // Setup World
    // ========================================================================

    std.debug.print("Setting up the farm...\n\n", .{});

    // Add workers
    _ = engine.addWorker(Entities.farmer_alice, .{});
    _ = engine.addWorker(Entities.farmer_bob, .{});
    std.debug.print("  Workers: Alice, Bob\n", .{});

    // Fields (external sources)
    const wheat_slots = [_]Engine.Slot{.{ .item = .Wheat, .capacity = 20 }};
    _ = engine.addStorage(Entities.wheat_field, .{ .slots = &wheat_slots });

    const carrot_slots = [_]Engine.Slot{.{ .item = .Carrot, .capacity = 20 }};
    _ = engine.addStorage(Entities.carrot_field, .{ .slots = &carrot_slots });
    std.debug.print("  Fields: Wheat, Carrot\n", .{});

    // Barn (stores raw crops)
    const barn_slots = [_]Engine.Slot{
        .{ .item = .Wheat, .capacity = 10 },
        .{ .item = .Carrot, .capacity = 10 },
    };
    _ = engine.addStorage(Entities.barn, .{ .slots = &barn_slots });
    std.debug.print("  Barn: holds wheat and carrots\n", .{});

    // Mill storages
    const mill_input_slots = [_]Engine.Slot{.{ .item = .Wheat, .capacity = 2 }};
    _ = engine.addStorage(Entities.mill_input, .{ .slots = &mill_input_slots });

    const mill_output_slots = [_]Engine.Slot{.{ .item = .Flour, .capacity = 1 }};
    _ = engine.addStorage(Entities.mill_output, .{ .slots = &mill_output_slots });

    const flour_slots = [_]Engine.Slot{.{ .item = .Flour, .capacity = 10 }};
    _ = engine.addStorage(Entities.flour_storage, .{ .slots = &flour_slots });
    std.debug.print("  Mill: 2 wheat -> 1 flour\n", .{});

    // Transport routes
    _ = engine.addTransport(.{
        .from = Entities.wheat_field,
        .to = Entities.barn,
        .item = .Wheat,
        .priority = .Normal,
    });
    _ = engine.addTransport(.{
        .from = Entities.carrot_field,
        .to = Entities.barn,
        .item = .Carrot,
        .priority = .Normal,
    });
    _ = engine.addTransport(.{
        .from = Entities.barn,
        .to = Entities.mill_input,
        .item = .Wheat,
        .priority = .High,
    });
    std.debug.print("  Transports: field->barn, barn->mill\n", .{});

    // Mill workstation
    _ = engine.addWorkstation(Entities.mill, .{
        .eis = Entities.mill_input,
        .iis = Entities.mill_input,
        .ios = Entities.mill_output,
        .eos = Entities.flour_storage,
        .process_duration = MILL_TIME,
        .priority = .High,
    });
    std.debug.print("  Mill workstation: processes wheat into flour\n", .{});

    // ========================================================================
    // Simulate Harvest
    // ========================================================================

    std.debug.print("\n--- Harvest begins! ---\n\n", .{});

    // Crops appear in fields
    _ = engine.addToStorage(Entities.wheat_field, .Wheat, 5);
    _ = engine.addToStorage(Entities.carrot_field, .Carrot, 3);
    log("Harvest ready: 5 wheat, 3 carrots in fields", .{});

    // Run simulation
    const max_ticks = 100;
    while (g_tick < max_ticks) {
        update();

        // Check completion
        const flour = engine.getStorageQuantity(Entities.flour_storage, .Flour);
        const wheat_in_field = engine.getStorageQuantity(Entities.wheat_field, .Wheat);
        const carrots_in_field = engine.getStorageQuantity(Entities.carrot_field, .Carrot);

        // Stop when all crops harvested and some flour produced
        if (wheat_in_field == 0 and carrots_in_field == 0 and flour >= 2) {
            break;
        }
    }

    // ========================================================================
    // Final Report
    // ========================================================================

    std.debug.print("\n--- Final State ---\n\n", .{});

    const wheat_field = engine.getStorageQuantity(Entities.wheat_field, .Wheat);
    const carrot_field = engine.getStorageQuantity(Entities.carrot_field, .Carrot);
    const barn_wheat = engine.getStorageQuantity(Entities.barn, .Wheat);
    const barn_carrots = engine.getStorageQuantity(Entities.barn, .Carrot);
    const flour = engine.getStorageQuantity(Entities.flour_storage, .Flour);
    const cycles = engine.getCyclesCompleted(Entities.mill);

    std.debug.print("  Fields:  wheat={d}, carrots={d}\n", .{ wheat_field, carrot_field });
    std.debug.print("  Barn:    wheat={d}, carrots={d}\n", .{ barn_wheat, barn_carrots });
    std.debug.print("  Flour:   {d} bags\n", .{flour});
    std.debug.print("  Mill:    {d} cycles completed\n", .{cycles});

    // Assertions
    std.debug.print("\n--- Assertions ---\n\n", .{});

    std.debug.assert(wheat_field == 0);
    std.debug.print("  [PASS] All wheat harvested\n", .{});

    std.debug.assert(carrot_field == 0);
    std.debug.print("  [PASS] All carrots harvested\n", .{});

    std.debug.assert(flour >= 2);
    std.debug.print("  [PASS] At least 2 flour produced\n", .{});

    std.debug.assert(cycles >= 2);
    std.debug.print("  [PASS] Mill ran at least 2 cycles\n", .{});

    std.debug.print("\n========================================\n", .{});
    std.debug.print("    ALL ASSERTIONS PASSED!              \n", .{});
    std.debug.print("========================================\n", .{});
}
