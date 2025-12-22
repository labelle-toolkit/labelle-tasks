const std = @import("std");
const zspec = @import("zspec");
const expect = zspec.expect;
const tasks = @import("labelle_tasks");

const Priority = tasks.Components.Priority;

// Test Item type
const Item = enum { Vegetable, Meat, Meal, Water };

// Engine type alias
const TestEngine = tasks.Engine(u32, Item);
const Slot = TestEngine.Slot;

// ============================================================================
// Test Callbacks
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

fn testOnPickupStarted(
    worker_id: u32,
    workstation_id: u32,
    eis_id: u32,
) void {
    _ = worker_id;
    _ = workstation_id;
    _ = eis_id;
    g_pickup_started_calls += 1;
}

fn testOnProcessStarted(
    worker_id: u32,
    workstation_id: u32,
) void {
    _ = worker_id;
    _ = workstation_id;
    g_process_started_calls += 1;
}

fn testOnProcessComplete(
    worker_id: u32,
    workstation_id: u32,
) void {
    _ = worker_id;
    _ = workstation_id;
    g_process_complete_calls += 1;
}

fn testOnStoreStarted(
    worker_id: u32,
    workstation_id: u32,
    eos_id: u32,
) void {
    _ = worker_id;
    _ = workstation_id;
    _ = eos_id;
    g_store_started_calls += 1;
}

fn testOnWorkerReleased(
    worker_id: u32,
    workstation_id: u32,
) void {
    _ = worker_id;
    _ = workstation_id;
    g_worker_released_calls += 1;
}

fn testOnTransportStarted(
    worker_id: u32,
    from_id: u32,
    to_id: u32,
    item: Item,
) void {
    _ = worker_id;
    _ = from_id;
    _ = to_id;
    _ = item;
    g_transport_started_calls += 1;
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

            const slots = [_]Slot{
                .{ .item = .Vegetable, .capacity = 10 },
            };
            _ = eng.addStorage(100, .{ .slots = &slots });

            const storage = eng.getStorage(100);
            try expect.notEqual(storage, null);
        }

        test "storage starts empty" {
            var eng = TestEngine.init(std.testing.allocator);
            defer eng.deinit();

            const slots = [_]Slot{
                .{ .item = .Vegetable, .capacity = 10 },
            };
            _ = eng.addStorage(100, .{ .slots = &slots });

            try expect.equal(eng.getStorageQuantity(100, .Vegetable), 0);
        }

        test "can add items to storage" {
            var eng = TestEngine.init(std.testing.allocator);
            defer eng.deinit();

            const slots = [_]Slot{
                .{ .item = .Vegetable, .capacity = 10 },
            };
            _ = eng.addStorage(100, .{ .slots = &slots });

            const added = eng.addToStorage(100, .Vegetable, 5);
            try expect.equal(added, 5);
            try expect.equal(eng.getStorageQuantity(100, .Vegetable), 5);
        }

        test "respects capacity limit" {
            var eng = TestEngine.init(std.testing.allocator);
            defer eng.deinit();

            const slots = [_]Slot{
                .{ .item = .Vegetable, .capacity = 3 },
            };
            _ = eng.addStorage(100, .{ .slots = &slots });

            const added = eng.addToStorage(100, .Vegetable, 5);
            try expect.equal(added, 3);
            try expect.equal(eng.getStorageQuantity(100, .Vegetable), 3);
        }
    };

    pub const @"addWorkstation" = struct {
        test "adds a workstation" {
            var eng = TestEngine.init(std.testing.allocator);
            defer eng.deinit();

            // Create storages
            const eis_slots = [_]Slot{.{ .item = .Vegetable, .capacity = 10 }};
            const iis_slots = [_]Slot{.{ .item = .Vegetable, .capacity = 2 }};
            const ios_slots = [_]Slot{.{ .item = .Meal, .capacity = 1 }};
            const eos_slots = [_]Slot{.{ .item = .Meal, .capacity = 4 }};

            _ = eng.addStorage(10, .{ .slots = &eis_slots });
            _ = eng.addStorage(11, .{ .slots = &iis_slots });
            _ = eng.addStorage(12, .{ .slots = &ios_slots });
            _ = eng.addStorage(13, .{ .slots = &eos_slots });

            _ = eng.addWorkstation(100, .{
                .eis = 10,
                .iis = 11,
                .ios = 12,
                .eos = 13,
                .process_duration = 10,
            });

            const status = eng.getWorkstationStatus(100);
            try expect.notEqual(status, null);
        }

        test "workstation starts as Blocked when inputs needed" {
            var eng = TestEngine.init(std.testing.allocator);
            defer eng.deinit();

            // Workstation with IIS requirement needs inputs
            const eis_slots = [_]Slot{.{ .item = .Vegetable, .capacity = 10 }};
            const iis_slots = [_]Slot{.{ .item = .Vegetable, .capacity = 2 }};
            const ios_slots = [_]Slot{.{ .item = .Meal, .capacity = 1 }};
            const eos_slots = [_]Slot{.{ .item = .Meal, .capacity = 4 }};

            _ = eng.addStorage(10, .{ .slots = &eis_slots });
            _ = eng.addStorage(11, .{ .slots = &iis_slots });
            _ = eng.addStorage(12, .{ .slots = &ios_slots });
            _ = eng.addStorage(13, .{ .slots = &eos_slots });

            _ = eng.addWorkstation(100, .{
                .eis = 10,
                .iis = 11,
                .ios = 12,
                .eos = 13,
                .process_duration = 10,
            });

            const status = eng.getWorkstationStatus(100);
            // Blocked because EIS doesn't have the required recipe
            try expect.equal(status.?, .Blocked);
        }

        test "producer workstation starts as Queued" {
            var eng = TestEngine.init(std.testing.allocator);
            defer eng.deinit();

            // Producer with no inputs needed
            const ios_slots = [_]Slot{.{ .item = .Water, .capacity = 1 }};
            const eos_slots = [_]Slot{.{ .item = .Water, .capacity = 4 }};

            _ = eng.addStorage(12, .{ .slots = &ios_slots });
            _ = eng.addStorage(13, .{ .slots = &eos_slots });

            _ = eng.addWorkstation(100, .{
                .ios = 12,
                .eos = 13,
                .process_duration = 10,
            });

            const status = eng.getWorkstationStatus(100);
            // Queued because no inputs needed and EOS has space
            try expect.equal(status.?, .Queued);
        }
    };

    pub const @"automatic workstation start" = struct {
        test "transitions to Queued when EIS has recipe" {
            resetCallbacks();
            var eng = TestEngine.init(std.testing.allocator);
            defer eng.deinit();

            // Create storages for kitchen
            const eis_slots = [_]Slot{
                .{ .item = .Vegetable, .capacity = 10 },
                .{ .item = .Meat, .capacity = 10 },
            };
            const iis_slots = [_]Slot{
                .{ .item = .Vegetable, .capacity = 2 },
                .{ .item = .Meat, .capacity = 1 },
            };
            const ios_slots = [_]Slot{.{ .item = .Meal, .capacity = 1 }};
            const eos_slots = [_]Slot{.{ .item = .Meal, .capacity = 4 }};

            _ = eng.addStorage(10, .{ .slots = &eis_slots });
            _ = eng.addStorage(11, .{ .slots = &iis_slots });
            _ = eng.addStorage(12, .{ .slots = &ios_slots });
            _ = eng.addStorage(13, .{ .slots = &eos_slots });

            _ = eng.addWorkstation(100, .{
                .eis = 10,
                .iis = 11,
                .ios = 12,
                .eos = 13,
                .process_duration = 10,
            });

            // Add items to EIS - not enough yet
            _ = eng.addToStorage(10, .Vegetable, 1);
            try expect.equal(eng.getWorkstationStatus(100).?, .Blocked);

            // Add more items - still not enough meat
            _ = eng.addToStorage(10, .Vegetable, 1);
            try expect.equal(eng.getWorkstationStatus(100).?, .Blocked);

            // Add meat - now has full recipe
            _ = eng.addToStorage(10, .Meat, 1);
            try expect.equal(eng.getWorkstationStatus(100).?, .Queued);
        }

        test "assigns worker when Queued" {
            resetCallbacks();
            var eng = TestEngine.init(std.testing.allocator);
            defer eng.deinit();

            eng.setFindBestWorker(testFindBestWorker);
            eng.setOnProcessStarted(testOnProcessStarted);

            // Create simple producer (no EIS/IIS)
            const ios_slots = [_]Slot{.{ .item = .Water, .capacity = 1 }};
            const eos_slots = [_]Slot{.{ .item = .Water, .capacity = 4 }};

            _ = eng.addStorage(12, .{ .slots = &ios_slots });
            _ = eng.addStorage(13, .{ .slots = &eos_slots });

            _ = eng.addWorker(1, .{});
            _ = eng.addWorkstation(100, .{
                .ios = 12,
                .eos = 13,
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
            eng.setOnPickupStarted(testOnPickupStarted);
            eng.setOnProcessStarted(testOnProcessStarted);
            eng.setOnProcessComplete(testOnProcessComplete);
            eng.setOnStoreStarted(testOnStoreStarted);
            eng.setOnWorkerReleased(testOnWorkerReleased);

            // Create storages for kitchen
            const eis_slots = [_]Slot{
                .{ .item = .Vegetable, .capacity = 10 },
                .{ .item = .Meat, .capacity = 10 },
            };
            const iis_slots = [_]Slot{
                .{ .item = .Vegetable, .capacity = 2 },
                .{ .item = .Meat, .capacity = 1 },
            };
            const ios_slots = [_]Slot{.{ .item = .Meal, .capacity = 1 }};
            const eos_slots = [_]Slot{.{ .item = .Meal, .capacity = 4 }};

            _ = eng.addStorage(10, .{ .slots = &eis_slots });
            _ = eng.addStorage(11, .{ .slots = &iis_slots });
            _ = eng.addStorage(12, .{ .slots = &ios_slots });
            _ = eng.addStorage(13, .{ .slots = &eos_slots });

            _ = eng.addWorker(1, .{});
            _ = eng.addWorkstation(100, .{
                .eis = 10,
                .iis = 11,
                .ios = 12,
                .eos = 13,
                .process_duration = 5,
            });

            // Add ingredients
            _ = eng.addToStorage(10, .Vegetable, 2);
            _ = eng.addToStorage(10, .Meat, 1);

            // Pickup should have started
            try expect.equal(g_pickup_started_calls, 1);

            // Complete pickup
            eng.notifyPickupComplete(1);

            // EIS -> IIS transfer should have happened
            try expect.equal(eng.getStorageQuantity(10, .Vegetable), 0);
            try expect.equal(eng.getStorageQuantity(10, .Meat), 0);
            try expect.equal(eng.getStorageQuantity(11, .Vegetable), 2);
            try expect.equal(eng.getStorageQuantity(11, .Meat), 1);

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
            try expect.equal(eng.getStorageQuantity(11, .Meat), 0);
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
            eng.setOnTransportStarted(testOnTransportStarted);

            // Source storage
            const source_slots = [_]Slot{.{ .item = .Meal, .capacity = 4 }};
            _ = eng.addStorage(10, .{ .slots = &source_slots });

            // Destination storage
            const dest_slots = [_]Slot{.{ .item = .Meal, .capacity = 4 }};
            _ = eng.addStorage(20, .{ .slots = &dest_slots });

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
            eng.setOnPickupStarted(testOnPickupStarted);

            // Create storages
            const eis_slots = [_]Slot{.{ .item = .Vegetable, .capacity = 10 }};
            const iis_slots = [_]Slot{.{ .item = .Vegetable, .capacity = 2 }};
            const ios_slots = [_]Slot{.{ .item = .Meal, .capacity = 1 }};
            const eos_slots = [_]Slot{.{ .item = .Meal, .capacity = 4 }};

            _ = eng.addStorage(10, .{ .slots = &eis_slots });
            _ = eng.addStorage(11, .{ .slots = &iis_slots });
            _ = eng.addStorage(12, .{ .slots = &ios_slots });
            _ = eng.addStorage(13, .{ .slots = &eos_slots });

            _ = eng.addWorker(1, .{});
            _ = eng.addWorkstation(100, .{
                .eis = 10,
                .iis = 11,
                .ios = 12,
                .eos = 13,
                .process_duration = 10,
            });

            // Add ingredients and start
            _ = eng.addToStorage(10, .Vegetable, 2);

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
            const ios_slots = [_]Slot{.{ .item = .Water, .capacity = 1 }};
            const eos_slots = [_]Slot{.{ .item = .Water, .capacity = 4 }};

            _ = eng.addStorage(12, .{ .slots = &ios_slots });
            _ = eng.addStorage(13, .{ .slots = &eos_slots });
            _ = eng.addStorage(22, .{ .slots = &ios_slots });
            _ = eng.addStorage(23, .{ .slots = &eos_slots });

            _ = eng.addWorkstation(100, .{
                .ios = 12,
                .eos = 13,
                .process_duration = 10,
                .priority = .Low,
            });

            _ = eng.addWorkstation(200, .{
                .ios = 22,
                .eos = 23,
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
            eng.setOnProcessStarted(testOnProcessStarted);
            eng.setOnProcessComplete(testOnProcessComplete);
            eng.setOnStoreStarted(testOnStoreStarted);
            eng.setOnWorkerReleased(testOnWorkerReleased);

            // Producer workstation (no EIS/IIS)
            const ios_slots = [_]Slot{.{ .item = .Water, .capacity = 1 }};
            const eos_slots = [_]Slot{.{ .item = .Water, .capacity = 4 }};

            _ = eng.addStorage(12, .{ .slots = &ios_slots });
            _ = eng.addStorage(13, .{ .slots = &eos_slots });

            _ = eng.addWorker(1, .{});
            _ = eng.addWorkstation(100, .{
                .ios = 12,
                .eos = 13,
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

            // Kitchen with multi-item recipe
            const eis_slots = [_]Slot{
                .{ .item = .Vegetable, .capacity = 10 },
                .{ .item = .Meat, .capacity = 10 },
                .{ .item = .Water, .capacity = 10 },
            };
            const iis_slots = [_]Slot{
                .{ .item = .Vegetable, .capacity = 2 },
                .{ .item = .Meat, .capacity = 1 },
                .{ .item = .Water, .capacity = 1 },
            };
            const ios_slots = [_]Slot{.{ .item = .Meal, .capacity = 1 }};
            const eos_slots = [_]Slot{.{ .item = .Meal, .capacity = 4 }};

            _ = eng.addStorage(10, .{ .slots = &eis_slots });
            _ = eng.addStorage(11, .{ .slots = &iis_slots });
            _ = eng.addStorage(12, .{ .slots = &ios_slots });
            _ = eng.addStorage(13, .{ .slots = &eos_slots });

            _ = eng.addWorker(1, .{});
            _ = eng.addWorkstation(100, .{
                .eis = 10,
                .iis = 11,
                .ios = 12,
                .eos = 13,
                .process_duration = 5,
            });

            // Blocked - no items
            try expect.equal(eng.getWorkstationStatus(100).?, .Blocked);

            // Add vegetable - still blocked (need meat and water)
            _ = eng.addToStorage(10, .Vegetable, 2);
            try expect.equal(eng.getWorkstationStatus(100).?, .Blocked);

            // Add meat - still blocked (need water)
            _ = eng.addToStorage(10, .Meat, 1);
            try expect.equal(eng.getWorkstationStatus(100).?, .Blocked);

            // Add water - now has full recipe, should start
            _ = eng.addToStorage(10, .Water, 1);
            try expect.equal(eng.getWorkstationStatus(100).?, .Active);
        }
    };

    pub const @"integration: EOS full blocking" = struct {
        test "blocks when EOS is full" {
            resetCallbacks();
            var eng = TestEngine.init(std.testing.allocator);
            defer eng.deinit();

            eng.setFindBestWorker(testFindBestWorker);

            // Producer with tiny EOS
            const ios_slots = [_]Slot{.{ .item = .Water, .capacity = 1 }};
            const eos_slots = [_]Slot{.{ .item = .Water, .capacity = 1 }}; // Only 1 slot

            _ = eng.addStorage(12, .{ .slots = &ios_slots });
            _ = eng.addStorage(13, .{ .slots = &eos_slots });

            _ = eng.addWorker(1, .{});
            _ = eng.addWorkstation(100, .{
                .ios = 12,
                .eos = 13,
                .process_duration = 1,
            });

            // First cycle starts
            try expect.equal(eng.getWorkstationStatus(100).?, .Active);

            // Complete first cycle
            eng.update(); // Process
            eng.notifyStoreComplete(1);

            // EOS is now full (1/1)
            try expect.equal(eng.getStorageQuantity(13, .Water), 1);

            // Workstation should be blocked - EOS full
            try expect.equal(eng.getWorkstationStatus(100).?, .Blocked);
        }

        test "unblocks when EOS freed" {
            resetCallbacks();
            var eng = TestEngine.init(std.testing.allocator);
            defer eng.deinit();

            eng.setFindBestWorker(testFindBestWorker);

            // Producer with tiny EOS
            const ios_slots = [_]Slot{.{ .item = .Water, .capacity = 1 }};
            const eos_slots = [_]Slot{.{ .item = .Water, .capacity = 1 }};

            _ = eng.addStorage(12, .{ .slots = &ios_slots });
            _ = eng.addStorage(13, .{ .slots = &eos_slots });

            _ = eng.addWorker(1, .{});
            _ = eng.addWorkstation(100, .{
                .ios = 12,
                .eos = 13,
                .process_duration = 1,
            });

            // Complete first cycle to fill EOS
            eng.update();
            eng.notifyStoreComplete(1);

            // Blocked due to full EOS
            try expect.equal(eng.getWorkstationStatus(100).?, .Blocked);

            // Remove item from EOS (simulating consumption)
            _ = eng.removeFromStorage(13, .Water, 1);

            // Need to trigger readiness check
            // This happens when we try to reassign the idle worker
            eng.notifyWorkerIdle(1);

            // Should restart now
            try expect.equal(eng.getWorkstationStatus(100).?, .Active);
        }
    };

    pub const @"integration: transport" = struct {
        test "doesn't transport when destination full" {
            resetCallbacks();
            var eng = TestEngine.init(std.testing.allocator);
            defer eng.deinit();

            eng.setFindBestWorker(testFindBestWorker);
            eng.setOnTransportStarted(testOnTransportStarted);

            // Source with items
            const source_slots = [_]Slot{.{ .item = .Water, .capacity = 4 }};
            _ = eng.addStorage(10, .{ .slots = &source_slots });

            // Destination already full
            const dest_slots = [_]Slot{.{ .item = .Water, .capacity = 1 }};
            _ = eng.addStorage(20, .{ .slots = &dest_slots });

            // Fill destination
            _ = eng.addToStorage(20, .Water, 1);

            // Add transport
            _ = eng.addTransport(.{
                .from = 10,
                .to = 20,
                .item = .Water,
            });

            _ = eng.addWorker(1, .{});

            // Add item to source
            _ = eng.addToStorage(10, .Water, 1);

            // Transport should NOT start - destination full
            try expect.equal(g_transport_started_calls, 0);
            try expect.equal(eng.getWorkerState(1).?, .Idle);
        }

        test "starts when destination has space" {
            resetCallbacks();
            var eng = TestEngine.init(std.testing.allocator);
            defer eng.deinit();

            eng.setFindBestWorker(testFindBestWorker);
            eng.setOnTransportStarted(testOnTransportStarted);

            // Source with items
            const source_slots = [_]Slot{.{ .item = .Water, .capacity = 4 }};
            _ = eng.addStorage(10, .{ .slots = &source_slots });

            // Destination with space
            const dest_slots = [_]Slot{.{ .item = .Water, .capacity = 4 }};
            _ = eng.addStorage(20, .{ .slots = &dest_slots });

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
            eng.setOnPickupStarted(testOnPickupStarted);
            eng.setOnTransportStarted(testOnTransportStarted);

            // Garden (source)
            const garden_slots = [_]Slot{.{ .item = .Vegetable, .capacity = 10 }};
            _ = eng.addStorage(1, .{ .slots = &garden_slots });

            // Kitchen storages
            const eis_slots = [_]Slot{.{ .item = .Vegetable, .capacity = 10 }};
            const iis_slots = [_]Slot{.{ .item = .Vegetable, .capacity = 1 }};
            const ios_slots = [_]Slot{.{ .item = .Meal, .capacity = 1 }};
            const eos_slots = [_]Slot{.{ .item = .Meal, .capacity = 4 }};

            _ = eng.addStorage(10, .{ .slots = &eis_slots });
            _ = eng.addStorage(11, .{ .slots = &iis_slots });
            _ = eng.addStorage(12, .{ .slots = &ios_slots });
            _ = eng.addStorage(13, .{ .slots = &eos_slots });

            // Transport from garden to kitchen EIS
            _ = eng.addTransport(.{
                .from = 1,
                .to = 10,
                .item = .Vegetable,
            });

            // Kitchen workstation
            _ = eng.addWorkstation(100, .{
                .eis = 10,
                .iis = 11,
                .ios = 12,
                .eos = 13,
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
            eng.setOnProcessStarted(testOnProcessStarted);

            // Two producer workstations
            const ios_slots = [_]Slot{.{ .item = .Water, .capacity = 1 }};
            const eos_slots = [_]Slot{.{ .item = .Water, .capacity = 4 }};

            _ = eng.addStorage(12, .{ .slots = &ios_slots });
            _ = eng.addStorage(13, .{ .slots = &eos_slots });
            _ = eng.addStorage(22, .{ .slots = &ios_slots });
            _ = eng.addStorage(23, .{ .slots = &eos_slots });

            _ = eng.addWorkstation(100, .{
                .ios = 12,
                .eos = 13,
                .process_duration = 10,
            });

            _ = eng.addWorkstation(200, .{
                .ios = 22,
                .eos = 23,
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
            eng.setOnProcessStarted(testOnProcessStarted);

            // Two producer workstations
            const ios_slots = [_]Slot{.{ .item = .Water, .capacity = 1 }};
            const eos_slots = [_]Slot{.{ .item = .Water, .capacity = 4 }};

            _ = eng.addStorage(12, .{ .slots = &ios_slots });
            _ = eng.addStorage(13, .{ .slots = &eos_slots });
            _ = eng.addStorage(22, .{ .slots = &ios_slots });
            _ = eng.addStorage(23, .{ .slots = &eos_slots });

            _ = eng.addWorkstation(100, .{
                .ios = 12,
                .eos = 13,
                .process_duration = 1,
            });

            _ = eng.addWorkstation(200, .{
                .ios = 22,
                .eos = 23,
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
            eng.setOnProcessStarted(testOnProcessStarted);

            // Producer with room for multiple items
            const ios_slots = [_]Slot{.{ .item = .Water, .capacity = 1 }};
            const eos_slots = [_]Slot{.{ .item = .Water, .capacity = 3 }};

            _ = eng.addStorage(12, .{ .slots = &ios_slots });
            _ = eng.addStorage(13, .{ .slots = &eos_slots });

            _ = eng.addWorker(1, .{});
            _ = eng.addWorkstation(100, .{
                .ios = 12,
                .eos = 13,
                .process_duration = 1,
            });

            // Complete 3 cycles
            var cycle: u32 = 0;
            while (cycle < 3) : (cycle += 1) {
                try expect.equal(eng.getWorkstationStatus(100).?, .Active);
                eng.update(); // Process
                eng.notifyStoreComplete(1);
            }

            // EOS should now be full
            try expect.equal(eng.getStorageQuantity(13, .Water), 3);
            try expect.equal(eng.getCyclesCompleted(100), 3);

            // Should be blocked now
            try expect.equal(eng.getWorkstationStatus(100).?, .Blocked);
        }
    };
};
