const std = @import("std");
const zspec = @import("zspec");
const expect = zspec.expect;
const tasks = @import("labelle_tasks");

const Priority = tasks.Components.Priority;

// Test Item type
const Item = enum { Vegetable, Meat, Meal, Water };

// ============================================================================
// Test Hook Handlers
// ============================================================================

var g_pickup_started_calls: u32 = 0;
var g_process_started_calls: u32 = 0;
var g_process_complete_calls: u32 = 0;
var g_store_started_calls: u32 = 0;
var g_worker_released_calls: u32 = 0;
var g_transport_started_calls: u32 = 0;

fn resetCallbacks() void {
    g_pickup_started_calls = 0;
    g_process_started_calls = 0;
    g_process_complete_calls = 0;
    g_store_started_calls = 0;
    g_worker_released_calls = 0;
    g_transport_started_calls = 0;
}

const TestHooks = struct {
    pub fn pickup_started(_: tasks.hooks.HookPayload(u32, Item)) void {
        g_pickup_started_calls += 1;
    }

    pub fn process_started(_: tasks.hooks.HookPayload(u32, Item)) void {
        g_process_started_calls += 1;
    }

    pub fn process_completed(_: tasks.hooks.HookPayload(u32, Item)) void {
        g_process_complete_calls += 1;
    }

    pub fn store_started(_: tasks.hooks.HookPayload(u32, Item)) void {
        g_store_started_calls += 1;
    }

    pub fn worker_released(_: tasks.hooks.HookPayload(u32, Item)) void {
        g_worker_released_calls += 1;
    }

    pub fn transport_started(_: tasks.hooks.HookPayload(u32, Item)) void {
        g_transport_started_calls += 1;
    }
};

const TestDispatcher = tasks.hooks.HookDispatcher(u32, Item, TestHooks);

// Engine type alias
const TestEngine = tasks.Engine(u32, Item, TestDispatcher);

fn testFindBestWorker(
    workstation_id: ?u32,
    available_workers: []const u32,
) ?u32 {
    _ = workstation_id;
    if (available_workers.len > 0) {
        return available_workers[0];
    }
    return null;
}

// ============================================================================
// Engine Tests
// ============================================================================

pub const @"Engine" = struct {
    pub const @"init and deinit" = struct {
        test "creates engine without error" {
            var eng = TestEngine.init(std.testing.allocator);
            defer eng.deinit();
        }
    };

    pub const @"addWorker" = struct {
        test "adds a worker" {
            var eng = TestEngine.init(std.testing.allocator);
            defer eng.deinit();

            _ = eng.addWorker(1, .{});
            const state = eng.getWorkerState(1);
            try expect.notEqual(state, null);
        }

        test "worker starts as Idle" {
            var eng = TestEngine.init(std.testing.allocator);
            defer eng.deinit();

            _ = eng.addWorker(1, .{});
            const state = eng.getWorkerState(1);
            try expect.equal(state.?, .Idle);
        }
    };

    pub const @"addStorage" = struct {
        test "adds a storage" {
            var eng = TestEngine.init(std.testing.allocator);
            defer eng.deinit();

            _ = eng.addStorage(100, .{ .item = .Vegetable });

            const storage = eng.getStorage(100);
            try expect.notEqual(storage, null);
        }

        test "storage starts empty" {
            var eng = TestEngine.init(std.testing.allocator);
            defer eng.deinit();

            _ = eng.addStorage(100, .{ .item = .Vegetable });

            try expect.equal(eng.getStorageQuantity(100, .Vegetable), 0);
        }

        test "can add items to storage" {
            var eng = TestEngine.init(std.testing.allocator);
            defer eng.deinit();

            _ = eng.addStorage(100, .{ .item = .Vegetable });

            const added = eng.addToStorage(100, .Vegetable, 5);
            try expect.equal(added, 5);
            try expect.equal(eng.getStorageQuantity(100, .Vegetable), 5);
        }

    };

    pub const @"addWorkstation" = struct {
        test "adds a workstation" {
            var eng = TestEngine.init(std.testing.allocator);
            defer eng.deinit();

            // Create storages (each storage holds one item type)
            _ = eng.addStorage(10, .{ .item = .Vegetable }); // EIS
            _ = eng.addStorage(11, .{ .item = .Vegetable }); // IIS
            _ = eng.addStorage(12, .{ .item = .Meal }); // IOS
            _ = eng.addStorage(13, .{ .item = .Meal }); // EOS

            _ = eng.addWorkstation(100, .{
                .eis = &.{10},
                .iis = &.{11},
                .ios = &.{12},
                .eos = &.{13},
                .process_duration = 10,
            });

            const status = eng.getWorkstationStatus(100);
            try expect.notEqual(status, null);
        }

        test "workstation starts as Blocked when inputs needed" {
            var eng = TestEngine.init(std.testing.allocator);
            defer eng.deinit();

            // Workstation with IIS requirement needs inputs
            _ = eng.addStorage(10, .{ .item = .Vegetable }); // EIS
            _ = eng.addStorage(11, .{ .item = .Vegetable }); // IIS
            _ = eng.addStorage(12, .{ .item = .Meal }); // IOS
            _ = eng.addStorage(13, .{ .item = .Meal }); // EOS

            _ = eng.addWorkstation(100, .{
                .eis = &.{10},
                .iis = &.{11},
                .ios = &.{12},
                .eos = &.{13},
                .process_duration = 10,
            });

            const status = eng.getWorkstationStatus(100);
            // Blocked because EIS doesn't have the required item
            try expect.equal(status.?, .Blocked);
        }

        test "producer workstation starts as Queued" {
            var eng = TestEngine.init(std.testing.allocator);
            defer eng.deinit();

            // Producer with no inputs needed
            _ = eng.addStorage(12, .{ .item = .Water }); // IOS
            _ = eng.addStorage(13, .{ .item = .Water }); // EOS

            _ = eng.addWorkstation(100, .{
                .ios = &.{12},
                .eos = &.{13},
                .process_duration = 10,
            });

            const status = eng.getWorkstationStatus(100);
            // Queued because no inputs needed and EOS has space
            try expect.equal(status.?, .Queued);
        }
    };

    pub const @"automatic workstation start" = struct {
        test "transitions to Queued when EIS has item" {
            resetCallbacks();
            var eng = TestEngine.init(std.testing.allocator);
            defer eng.deinit();

            // Create storages for kitchen (single item recipe)
            _ = eng.addStorage(10, .{ .item = .Vegetable }); // EIS
            _ = eng.addStorage(11, .{ .item = .Vegetable }); // IIS
            _ = eng.addStorage(12, .{ .item = .Meal }); // IOS
            _ = eng.addStorage(13, .{ .item = .Meal }); // EOS

            _ = eng.addWorkstation(100, .{
                .eis = &.{10},
                .iis = &.{11},
                .ios = &.{12},
                .eos = &.{13},
                .process_duration = 10,
            });

            // Initially blocked - no items
            try expect.equal(eng.getWorkstationStatus(100).?, .Blocked);

            // Add vegetable - now has item for recipe
            _ = eng.addToStorage(10, .Vegetable, 1);
            try expect.equal(eng.getWorkstationStatus(100).?, .Queued);
        }

        test "assigns worker when Queued" {
            resetCallbacks();
            var eng = TestEngine.init(std.testing.allocator);
            defer eng.deinit();

            eng.setFindBestWorker(testFindBestWorker);

            // Create simple producer (no EIS/IIS)
            _ = eng.addStorage(12, .{ .item = .Water }); // IOS
            _ = eng.addStorage(13, .{ .item = .Water }); // EOS

            _ = eng.addWorker(1, .{});
            _ = eng.addWorkstation(100, .{
                .ios = &.{12},
                .eos = &.{13},
                .process_duration = 10,
            });

            // Producer workstation immediately assigns idle worker when added
            // (no inputs needed, EOS has space, worker available)
            try expect.equal(eng.getWorkerState(1).?, .Working);
            try expect.equal(eng.getWorkstationStatus(100).?, .Active);
            // Process started callback should be called
            try expect.equal(g_process_started_calls, 1);
        }
    };

    pub const @"full cycle" = struct {
        test "completes Pickup -> Process -> Store cycle" {
            resetCallbacks();
            var eng = TestEngine.init(std.testing.allocator);
            defer eng.deinit();

            eng.setFindBestWorker(testFindBestWorker);

            // Create storages for kitchen (single ingredient recipe)
            _ = eng.addStorage(10, .{ .item = .Vegetable }); // EIS
            _ = eng.addStorage(11, .{ .item = .Vegetable }); // IIS
            _ = eng.addStorage(12, .{ .item = .Meal }); // IOS
            _ = eng.addStorage(13, .{ .item = .Meal }); // EOS

            _ = eng.addWorker(1, .{});
            _ = eng.addWorkstation(100, .{
                .eis = &.{10},
                .iis = &.{11},
                .ios = &.{12},
                .eos = &.{13},
                .process_duration = 5,
            });

            // Add ingredient (1 for recipe)
            _ = eng.addToStorage(10, .Vegetable, 1);

            // Pickup should have started
            try expect.equal(g_pickup_started_calls, 1);

            // Complete pickup
            eng.notifyPickupComplete(1);

            // EIS -> IIS transfer should have happened
            try expect.equal(eng.getStorageQuantity(10, .Vegetable), 0);
            try expect.equal(eng.getStorageQuantity(11, .Vegetable), 1);

            // Process should have started
            try expect.equal(g_process_started_calls, 1);

            // Run 5 ticks for process
            var i: u32 = 0;
            while (i < 5) : (i += 1) {
                eng.update();
            }

            // Process should be complete
            try expect.equal(g_process_complete_calls, 1);

            // IIS -> IOS transformation
            try expect.equal(eng.getStorageQuantity(11, .Vegetable), 0);
            try expect.equal(eng.getStorageQuantity(12, .Meal), 1);

            // Store should have started
            try expect.equal(g_store_started_calls, 1);

            // Complete store
            eng.notifyStoreComplete(1);

            // IOS -> EOS transfer
            try expect.equal(eng.getStorageQuantity(12, .Meal), 0);
            try expect.equal(eng.getStorageQuantity(13, .Meal), 1);

            // Worker should be released
            try expect.equal(g_worker_released_calls, 1);
            try expect.equal(eng.getWorkerState(1).?, .Idle);

            // Cycle should be counted
            try expect.equal(eng.getCyclesCompleted(100), 1);
        }
    };

    pub const @"transport" = struct {
        test "transports items between storages" {
            resetCallbacks();
            var eng = TestEngine.init(std.testing.allocator);
            defer eng.deinit();

            eng.setFindBestWorker(testFindBestWorker);

            // Source storage
            _ = eng.addStorage(10, .{ .item = .Meal });

            // Destination storage
            _ = eng.addStorage(20, .{ .item = .Meal });

            // Add transport
            _ = eng.addTransport(.{
                .from = 10,
                .to = 20,
                .item = .Meal,
            });

            _ = eng.addWorker(1, .{});

            // Add item to source
            _ = eng.addToStorage(10, .Meal, 1);

            // Transport should start (worker should be assigned)
            try expect.equal(g_transport_started_calls, 1);
            try expect.equal(eng.getWorkerState(1).?, .Working);

            // Complete transport
            eng.notifyTransportComplete(1);

            // Item should be transferred
            try expect.equal(eng.getStorageQuantity(10, .Meal), 0);
            try expect.equal(eng.getStorageQuantity(20, .Meal), 1);

            // Worker should be idle
            try expect.equal(eng.getWorkerState(1).?, .Idle);
        }
    };

    pub const @"abandonWork" = struct {
        test "releases worker from workstation" {
            resetCallbacks();
            var eng = TestEngine.init(std.testing.allocator);
            defer eng.deinit();

            eng.setFindBestWorker(testFindBestWorker);

            // Create storages
            _ = eng.addStorage(10, .{ .item = .Vegetable }); // EIS
            _ = eng.addStorage(11, .{ .item = .Vegetable }); // IIS
            _ = eng.addStorage(12, .{ .item = .Meal }); // IOS
            _ = eng.addStorage(13, .{ .item = .Meal }); // EOS

            _ = eng.addWorker(1, .{});
            _ = eng.addWorkstation(100, .{
                .eis = &.{10},
                .iis = &.{11},
                .ios = &.{12},
                .eos = &.{13},
                .process_duration = 10,
            });

            // Add ingredient and start (1 for recipe)
            _ = eng.addToStorage(10, .Vegetable, 1);

            try expect.equal(eng.getWorkerState(1).?, .Working);

            // Abandon work
            eng.abandonWork(1);

            try expect.equal(eng.getWorkerState(1).?, .Idle);
            try expect.equal(eng.getWorkstationStatus(100).?, .Blocked);
        }
    };

    pub const @"priority" = struct {
        test "assigns to higher priority workstation" {
            resetCallbacks();
            var eng = TestEngine.init(std.testing.allocator);
            defer eng.deinit();

            eng.setFindBestWorker(testFindBestWorker);

            // Two producer workstations
            _ = eng.addStorage(12, .{ .item = .Water }); // IOS 1
            _ = eng.addStorage(13, .{ .item = .Water }); // EOS 1
            _ = eng.addStorage(22, .{ .item = .Water }); // IOS 2
            _ = eng.addStorage(23, .{ .item = .Water }); // EOS 2

            _ = eng.addWorkstation(100, .{
                .ios = &.{12},
                .eos = &.{13},
                .process_duration = 10,
                .priority = .Low,
            });

            _ = eng.addWorkstation(200, .{
                .ios = &.{22},
                .eos = &.{23},
                .process_duration = 10,
                .priority = .High,
            });

            _ = eng.addWorker(1, .{});

            // Worker should be assigned to high priority
            try expect.equal(eng.getWorkstationStatus(200).?, .Active);
            try expect.equal(eng.getWorkstationStatus(100).?, .Queued);
        }
    };

    // ========================================================================
    // Integration Tests
    // ========================================================================

    pub const @"integration: producer workstation" = struct {
        test "completes Process -> Store cycle (no Pickup)" {
            resetCallbacks();
            var eng = TestEngine.init(std.testing.allocator);
            defer eng.deinit();

            eng.setFindBestWorker(testFindBestWorker);

            // Producer workstation (no EIS/IIS)
            _ = eng.addStorage(12, .{ .item = .Water }); // IOS
            _ = eng.addStorage(13, .{ .item = .Water }); // EOS

            _ = eng.addWorker(1, .{});
            _ = eng.addWorkstation(100, .{
                .ios = &.{12},
                .eos = &.{13},
                .process_duration = 3,
            });

            // Process should have started immediately
            try expect.equal(g_process_started_calls, 1);
            try expect.equal(g_pickup_started_calls, 0); // No pickup for producer

            // Run process timer
            var i: u32 = 0;
            while (i < 3) : (i += 1) {
                eng.update();
            }

            // Process complete, IOS filled
            try expect.equal(g_process_complete_calls, 1);
            try expect.equal(eng.getStorageQuantity(12, .Water), 1);

            // Store should have started
            try expect.equal(g_store_started_calls, 1);

            // Complete store
            eng.notifyStoreComplete(1);

            // Water should be in EOS
            try expect.equal(eng.getStorageQuantity(12, .Water), 0);
            try expect.equal(eng.getStorageQuantity(13, .Water), 1);

            // Worker released and cycle counted
            try expect.equal(g_worker_released_calls, 1);
            try expect.equal(eng.getCyclesCompleted(100), 1);
        }
    };

    pub const @"integration: multi-item recipe" = struct {
        test "requires ALL recipe items to start" {
            resetCallbacks();
            var eng = TestEngine.init(std.testing.allocator);
            defer eng.deinit();

            eng.setFindBestWorker(testFindBestWorker);

            // Kitchen with multi-item recipe (2 ingredients)
            // Need separate storages for each item type
            _ = eng.addStorage(10, .{ .item = .Vegetable }); // EIS for vegetable
            _ = eng.addStorage(11, .{ .item = .Meat }); // EIS for meat
            _ = eng.addStorage(20, .{ .item = .Vegetable }); // IIS for vegetable
            _ = eng.addStorage(21, .{ .item = .Meat }); // IIS for meat
            _ = eng.addStorage(12, .{ .item = .Meal }); // IOS
            _ = eng.addStorage(13, .{ .item = .Meal }); // EOS

            _ = eng.addWorker(1, .{});
            _ = eng.addWorkstation(100, .{
                .eis = &.{ 10, 11 }, // Both EIS storages
                .iis = &.{ 20, 21 }, // Both IIS storages (recipe: 1 veg + 1 meat)
                .ios = &.{12},
                .eos = &.{13},
                .process_duration = 5,
            });

            // Blocked - no items
            try expect.equal(eng.getWorkstationStatus(100).?, .Blocked);

            // Add vegetable - still blocked (need meat)
            _ = eng.addToStorage(10, .Vegetable, 1);
            try expect.equal(eng.getWorkstationStatus(100).?, .Blocked);

            // Add meat - now has full recipe (1 of each), should start
            _ = eng.addToStorage(11, .Meat, 1);
            try expect.equal(eng.getWorkstationStatus(100).?, .Active);
        }
    };

    pub const @"integration: transport" = struct {
        test "starts when destination has space" {
            resetCallbacks();
            var eng = TestEngine.init(std.testing.allocator);
            defer eng.deinit();

            eng.setFindBestWorker(testFindBestWorker);

            // Source with items
            _ = eng.addStorage(10, .{ .item = .Water });

            // Destination with space
            _ = eng.addStorage(20, .{ .item = .Water });

            // Add transport
            _ = eng.addTransport(.{
                .from = 10,
                .to = 20,
                .item = .Water,
            });

            _ = eng.addWorker(1, .{});

            // Add item to source
            _ = eng.addToStorage(10, .Water, 1);

            // Transport should start
            try expect.equal(g_transport_started_calls, 1);
            try expect.equal(eng.getWorkerState(1).?, .Working);
        }

        test "feeds workstation via transport chain" {
            resetCallbacks();
            var eng = TestEngine.init(std.testing.allocator);
            defer eng.deinit();

            eng.setFindBestWorker(testFindBestWorker);

            // Garden (source)
            _ = eng.addStorage(1, .{ .item = .Vegetable });

            // Kitchen storages
            _ = eng.addStorage(10, .{ .item = .Vegetable }); // EIS
            _ = eng.addStorage(11, .{ .item = .Vegetable }); // IIS
            _ = eng.addStorage(12, .{ .item = .Meal }); // IOS
            _ = eng.addStorage(13, .{ .item = .Meal }); // EOS

            // Transport from garden to kitchen EIS
            _ = eng.addTransport(.{
                .from = 1,
                .to = 10,
                .item = .Vegetable,
            });

            // Kitchen workstation
            _ = eng.addWorkstation(100, .{
                .eis = &.{10},
                .iis = &.{11},
                .ios = &.{12},
                .eos = &.{13},
                .process_duration = 5,
            });

            _ = eng.addWorker(1, .{});

            // Kitchen blocked - no vegetables
            try expect.equal(eng.getWorkstationStatus(100).?, .Blocked);

            // Add vegetable to garden
            _ = eng.addToStorage(1, .Vegetable, 1);

            // Transport should start
            try expect.equal(g_transport_started_calls, 1);

            // Complete transport
            eng.notifyTransportComplete(1);

            // Vegetable now in kitchen EIS
            try expect.equal(eng.getStorageQuantity(10, .Vegetable), 1);

            // Kitchen should start (pickup)
            try expect.equal(g_pickup_started_calls, 1);
            try expect.equal(eng.getWorkstationStatus(100).?, .Active);
        }
    };

    pub const @"integration: multiple workers" = struct {
        test "assigns multiple workers to different workstations" {
            resetCallbacks();
            var eng = TestEngine.init(std.testing.allocator);
            defer eng.deinit();

            eng.setFindBestWorker(testFindBestWorker);

            // Two producer workstations
            _ = eng.addStorage(12, .{ .item = .Water }); // IOS 1
            _ = eng.addStorage(13, .{ .item = .Water }); // EOS 1
            _ = eng.addStorage(22, .{ .item = .Water }); // IOS 2
            _ = eng.addStorage(23, .{ .item = .Water }); // EOS 2

            _ = eng.addWorkstation(100, .{
                .ios = &.{12},
                .eos = &.{13},
                .process_duration = 10,
            });

            _ = eng.addWorkstation(200, .{
                .ios = &.{22},
                .eos = &.{23},
                .process_duration = 10,
            });

            // Add two workers
            _ = eng.addWorker(1, .{});
            _ = eng.addWorker(2, .{});

            // Both workstations should be active
            try expect.equal(eng.getWorkstationStatus(100).?, .Active);
            try expect.equal(eng.getWorkstationStatus(200).?, .Active);
            try expect.equal(g_process_started_calls, 2);
        }

        test "worker takes next available work after completion" {
            resetCallbacks();
            var eng = TestEngine.init(std.testing.allocator);
            defer eng.deinit();

            eng.setFindBestWorker(testFindBestWorker);

            // Two producer workstations
            _ = eng.addStorage(12, .{ .item = .Water }); // IOS 1
            _ = eng.addStorage(13, .{ .item = .Water }); // EOS 1
            _ = eng.addStorage(22, .{ .item = .Water }); // IOS 2
            _ = eng.addStorage(23, .{ .item = .Water }); // EOS 2

            _ = eng.addWorkstation(100, .{
                .ios = &.{12},
                .eos = &.{13},
                .process_duration = 1,
            });

            _ = eng.addWorkstation(200, .{
                .ios = &.{22},
                .eos = &.{23},
                .process_duration = 1,
            });

            // Only one worker for two workstations
            _ = eng.addWorker(1, .{});

            // First workstation active, second queued
            try expect.equal(eng.getWorkstationStatus(100).?, .Active);
            try expect.equal(eng.getWorkstationStatus(200).?, .Queued);
            try expect.equal(g_process_started_calls, 1);

            // Complete first cycle
            eng.update(); // Process
            eng.notifyStoreComplete(1);

            // Worker should now be on second workstation
            try expect.equal(eng.getWorkstationStatus(200).?, .Active);
            try expect.equal(g_process_started_calls, 2);
        }
    };

    pub const @"integration: continuous production" = struct {
        test "producer cycles continuously while EOS has space" {
            resetCallbacks();
            var eng = TestEngine.init(std.testing.allocator);
            defer eng.deinit();

            eng.setFindBestWorker(testFindBestWorker);

            // Producer with room for multiple items
            _ = eng.addStorage(12, .{ .item = .Water }); // IOS
            _ = eng.addStorage(13, .{ .item = .Water }); // EOS

            _ = eng.addWorker(1, .{});
            _ = eng.addWorkstation(100, .{
                .ios = &.{12},
                .eos = &.{13},
                .process_duration = 1,
            });

            // Complete 3 cycles
            var cycle: u32 = 0;
            while (cycle < 3) : (cycle += 1) {
                try expect.equal(eng.getWorkstationStatus(100).?, .Active);
                eng.update(); // Process
                eng.notifyStoreComplete(1);
            }

            // EOS has accumulated 3 water
            try expect.equal(eng.getStorageQuantity(13, .Water), 3);
            try expect.equal(eng.getCyclesCompleted(100), 3);

            // Workstation continues (no capacity limit)
            try expect.equal(eng.getWorkstationStatus(100).?, .Active);
        }
    };

    // ========================================================================
    // Multiple EIS/EOS Tests
    // ========================================================================

    pub const @"integration: multiple EIS" = struct {
        test "workstation picks from any EIS with item" {
            resetCallbacks();
            var eng = TestEngine.init(std.testing.allocator);
            defer eng.deinit();

            eng.setFindBestWorker(testFindBestWorker);

            // Two EIS storages for same item type
            _ = eng.addStorage(10, .{ .item = .Vegetable }); // EIS 1
            _ = eng.addStorage(20, .{ .item = .Vegetable }); // EIS 2
            _ = eng.addStorage(11, .{ .item = .Vegetable }); // IIS
            _ = eng.addStorage(12, .{ .item = .Meal }); // IOS
            _ = eng.addStorage(13, .{ .item = .Meal }); // EOS

            _ = eng.addWorker(1, .{});
            _ = eng.addWorkstation(100, .{
                .eis = &.{ 10, 20 }, // Multiple EIS
                .iis = &.{11},
                .ios = &.{12},
                .eos = &.{13},
                .process_duration = 1,
            });

            // Add item only to second EIS (1 for recipe)
            _ = eng.addToStorage(20, .Vegetable, 1);

            // Workstation should start (second EIS has item)
            try expect.equal(eng.getWorkstationStatus(100).?, .Active);
            try expect.equal(g_pickup_started_calls, 1);

            // Complete pickup - item from EIS 2 should transfer to IIS
            eng.notifyPickupComplete(1);
            try expect.equal(eng.getStorageQuantity(20, .Vegetable), 0);
            try expect.equal(eng.getStorageQuantity(11, .Vegetable), 1);
        }

        test "workstation blocked when no EIS has required items" {
            resetCallbacks();
            var eng = TestEngine.init(std.testing.allocator);
            defer eng.deinit();

            eng.setFindBestWorker(testFindBestWorker);

            // Two EIS storages with multi-item recipe
            _ = eng.addStorage(10, .{ .item = .Vegetable }); // EIS 1 for vegetable
            _ = eng.addStorage(20, .{ .item = .Meat }); // EIS 2 for meat
            _ = eng.addStorage(11, .{ .item = .Vegetable }); // IIS for vegetable
            _ = eng.addStorage(21, .{ .item = .Meat }); // IIS for meat
            _ = eng.addStorage(12, .{ .item = .Meal }); // IOS
            _ = eng.addStorage(13, .{ .item = .Meal }); // EOS

            _ = eng.addWorker(1, .{});
            _ = eng.addWorkstation(100, .{
                .eis = &.{ 10, 20 }, // Multiple EIS (one per item type)
                .iis = &.{ 11, 21 }, // Multiple IIS (recipe needs both)
                .ios = &.{12},
                .eos = &.{13},
                .process_duration = 1,
            });

            // Add vegetable to EIS 1 - still need meat
            _ = eng.addToStorage(10, .Vegetable, 1);

            // Workstation should be blocked (missing meat)
            try expect.equal(eng.getWorkstationStatus(100).?, .Blocked);

            // Add meat to EIS 2 - now has all items
            _ = eng.addToStorage(20, .Meat, 1);

            // Now should be active
            try expect.equal(eng.getWorkstationStatus(100).?, .Active);
        }
    };

    pub const @"integration: multiple EOS" = struct {
        test "workstation stores to first EOS with matching type" {
            resetCallbacks();
            var eng = TestEngine.init(std.testing.allocator);
            defer eng.deinit();

            eng.setFindBestWorker(testFindBestWorker);

            // Two EOS storages
            _ = eng.addStorage(12, .{ .item = .Water }); // IOS
            _ = eng.addStorage(13, .{ .item = .Water }); // EOS 1
            _ = eng.addStorage(23, .{ .item = .Water }); // EOS 2

            _ = eng.addWorker(1, .{});
            _ = eng.addWorkstation(100, .{
                .ios = &.{12},
                .eos = &.{ 13, 23 }, // Multiple EOS
                .process_duration = 1,
            });

            // Complete first cycle
            eng.update();
            eng.notifyStoreComplete(1);

            // Water should be in first EOS
            try expect.equal(eng.getStorageQuantity(13, .Water), 1);
            try expect.equal(eng.getStorageQuantity(23, .Water), 0);
        }

    };

    // ========================================================================
    // Transfer Failure Tests
    // ========================================================================

    pub const @"integration: transfer failure handling" = struct {
        test "blocks workstation when EIS loses items before pickup complete" {
            resetCallbacks();
            var eng = TestEngine.init(std.testing.allocator);
            defer eng.deinit();

            eng.setFindBestWorker(testFindBestWorker);

            // Setup kitchen
            _ = eng.addStorage(10, .{ .item = .Vegetable }); // EIS
            _ = eng.addStorage(11, .{ .item = .Vegetable }); // IIS
            _ = eng.addStorage(12, .{ .item = .Meal }); // IOS
            _ = eng.addStorage(13, .{ .item = .Meal }); // EOS

            _ = eng.addWorker(1, .{});
            _ = eng.addWorkstation(100, .{
                .eis = &.{10},
                .iis = &.{11},
                .ios = &.{12},
                .eos = &.{13},
                .process_duration = 5,
            });

            // Add ingredient to start (need 1 for recipe)
            _ = eng.addToStorage(10, .Vegetable, 1);
            try expect.equal(eng.getWorkstationStatus(100).?, .Active);
            try expect.equal(g_pickup_started_calls, 1);

            // Simulate item being removed while worker is en route
            _ = eng.removeFromStorage(10, .Vegetable, 1);

            // Notify pickup complete - transfer should fail
            eng.notifyPickupComplete(1);

            // Workstation should be blocked, worker released
            try expect.equal(eng.getWorkstationStatus(100).?, .Blocked);
            try expect.equal(eng.getWorkerState(1).?, .Idle);

            // IIS should still be empty (no partial transfer)
            try expect.equal(eng.getStorageQuantity(11, .Vegetable), 0);
        }
    };

};
