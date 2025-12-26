const std = @import("std");
const zspec = @import("zspec");
const expect = zspec.expect;
const tasks = @import("labelle_tasks");
const f = @import("factories.zig");

const Priority = tasks.Components.Priority;
const Item = f.Item;
const TestEngine = f.TestEngine;
const IDs = f.IDs;

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

            _ = eng.addWorker(IDs.WORKER_1, .{});
            try expect.notEqual(eng.getWorkerState(IDs.WORKER_1), null);
        }

        test "worker starts as Idle" {
            var eng = TestEngine.init(std.testing.allocator);
            defer eng.deinit();

            _ = eng.addWorker(IDs.WORKER_1, .{});
            try expect.equal(eng.getWorkerState(IDs.WORKER_1).?, .Idle);
        }
    };

    pub const @"addStorage" = struct {
        test "adds a storage" {
            var eng = TestEngine.init(std.testing.allocator);
            defer eng.deinit();

            _ = eng.addStorage(IDs.EIS_VEG, .{ .item = .Vegetable });
            try expect.notEqual(eng.getStorage(IDs.EIS_VEG), null);
        }

        test "storage starts empty" {
            var eng = TestEngine.init(std.testing.allocator);
            defer eng.deinit();

            _ = eng.addStorage(IDs.EIS_VEG, .{ .item = .Vegetable });
            try expect.equal(eng.isEmpty(IDs.EIS_VEG), true);
            try expect.equal(eng.hasItem(IDs.EIS_VEG, .Vegetable), false);
        }

        test "can add item to storage" {
            var eng = TestEngine.init(std.testing.allocator);
            defer eng.deinit();

            _ = eng.addStorage(IDs.EIS_VEG, .{ .item = .Vegetable });

            const added = eng.addToStorage(IDs.EIS_VEG, .Vegetable);
            try expect.equal(added, true);
            try expect.equal(eng.hasItem(IDs.EIS_VEG, .Vegetable), true);
            try expect.equal(eng.isEmpty(IDs.EIS_VEG), false);
        }

        test "cannot add to full storage" {
            var eng = TestEngine.init(std.testing.allocator);
            defer eng.deinit();

            _ = eng.addStorage(IDs.EIS_VEG, .{ .item = .Vegetable });

            _ = eng.addToStorage(IDs.EIS_VEG, .Vegetable);
            const added_again = eng.addToStorage(IDs.EIS_VEG, .Vegetable);
            try expect.equal(added_again, false);
        }
    };

    pub const @"addWorkstation" = struct {
        test "adds a workstation" {
            var eng = TestEngine.init(std.testing.allocator);
            defer eng.deinit();

            f.setupKitchen(&eng, f.KitchenFactory.build(.{}));

            try expect.notEqual(eng.getWorkstationStatus(IDs.WORKSTATION_1), null);
        }

        test "workstation starts as Blocked when inputs needed" {
            var eng = TestEngine.init(std.testing.allocator);
            defer eng.deinit();

            f.setupKitchen(&eng, f.KitchenFactory.build(.{}));

            // Blocked because EIS doesn't have the required item
            try expect.equal(eng.getWorkstationStatus(IDs.WORKSTATION_1).?, .Blocked);
        }

        test "producer workstation starts as Queued" {
            var eng = TestEngine.init(std.testing.allocator);
            defer eng.deinit();

            f.setupProducer(&eng, f.ProducerFactory.build(.{}));

            // Queued because no inputs needed and EOS has space
            try expect.equal(eng.getWorkstationStatus(IDs.WORKSTATION_1).?, .Queued);
        }
    };

    pub const @"automatic workstation start" = struct {
        test "transitions to Queued when EIS has item" {
            f.resetHookCounters();
            var eng = f.createEngine();
            defer eng.deinit();

            f.setupKitchen(&eng, f.KitchenFactory.build(.{}));

            // Initially blocked - no items
            try expect.equal(eng.getWorkstationStatus(IDs.WORKSTATION_1).?, .Blocked);

            // Add vegetable - now has item for recipe
            _ = eng.addToStorage(IDs.EIS_VEG, .Vegetable);
            try expect.equal(eng.getWorkstationStatus(IDs.WORKSTATION_1).?, .Queued);
        }

        test "assigns worker when Queued" {
            f.resetHookCounters();
            var eng = f.createEngine();
            defer eng.deinit();

            _ = eng.addWorker(IDs.WORKER_1, .{});
            f.setupProducer(&eng, f.ProducerFactory.build(.{}));

            // Producer workstation immediately assigns idle worker when added
            try expect.equal(eng.getWorkerState(IDs.WORKER_1).?, .Working);
            try expect.equal(eng.getWorkstationStatus(IDs.WORKSTATION_1).?, .Active);
            try expect.equal(f.g_process_started_calls, 1);
        }
    };

    pub const @"full cycle" = struct {
        test "completes Pickup -> Process -> Store cycle" {
            f.resetHookCounters();
            var eng = f.createEngine();
            defer eng.deinit();

            _ = eng.addWorker(IDs.WORKER_1, .{});
            f.setupKitchen(&eng, f.KitchenFactory.build(.{}));

            // Add ingredient
            _ = eng.addToStorage(IDs.EIS_VEG, .Vegetable);

            // Pickup should have started
            try expect.equal(f.g_pickup_started_calls, 1);

            // Complete pickup
            eng.notifyPickupComplete(IDs.WORKER_1);

            // EIS -> IIS transfer should have happened
            try expect.equal(eng.hasItem(IDs.EIS_VEG, .Vegetable), false);
            try expect.equal(eng.hasItem(IDs.IIS_VEG, .Vegetable), true);

            // Process should have started
            try expect.equal(f.g_process_started_calls, 1);

            // Run 5 ticks for process
            var i: u32 = 0;
            while (i < 5) : (i += 1) {
                eng.update();
            }

            // Process should be complete
            try expect.equal(f.g_process_complete_calls, 1);

            // IIS -> IOS transformation
            try expect.equal(eng.hasItem(IDs.IIS_VEG, .Vegetable), false);
            try expect.equal(eng.hasItem(IDs.IOS_MEAL, .Meal), true);

            // Store should have started
            try expect.equal(f.g_store_started_calls, 1);

            // Complete store
            eng.notifyStoreComplete(IDs.WORKER_1);

            // IOS -> EOS transfer
            try expect.equal(eng.hasItem(IDs.IOS_MEAL, .Meal), false);
            try expect.equal(eng.hasItem(IDs.EOS_MEAL, .Meal), true);

            // Worker should be released
            try expect.equal(f.g_worker_released_calls, 1);
            try expect.equal(eng.getWorkerState(IDs.WORKER_1).?, .Idle);

            // Cycle should be counted
            try expect.equal(eng.getCyclesCompleted(IDs.WORKSTATION_1), 1);
        }
    };

    pub const @"transport" = struct {
        test "transports items between storages" {
            f.resetHookCounters();
            var eng = f.createEngine();
            defer eng.deinit();

            f.setupTransport(&eng, f.TransportFactory.build(.{}));
            _ = eng.addWorker(IDs.WORKER_1, .{});

            // Add item to source
            _ = eng.addToStorage(IDs.SOURCE, .Meal);

            // Transport should start
            try expect.equal(f.g_transport_started_calls, 1);
            try expect.equal(eng.getWorkerState(IDs.WORKER_1).?, .Working);

            // Complete transport
            eng.notifyTransportComplete(IDs.WORKER_1);

            // Item should be transferred
            try expect.equal(eng.hasItem(IDs.SOURCE, .Meal), false);
            try expect.equal(eng.hasItem(IDs.DEST, .Meal), true);

            // Worker should be idle
            try expect.equal(eng.getWorkerState(IDs.WORKER_1).?, .Idle);
        }
    };

    pub const @"abandonWork" = struct {
        test "releases worker from workstation" {
            f.resetHookCounters();
            var eng = f.createEngine();
            defer eng.deinit();

            _ = eng.addWorker(IDs.WORKER_1, .{});
            f.setupKitchen(&eng, f.KitchenFactory.build(.{}));

            // Add ingredient and start
            _ = eng.addToStorage(IDs.EIS_VEG, .Vegetable);

            try expect.equal(eng.getWorkerState(IDs.WORKER_1).?, .Working);

            // Abandon work
            eng.abandonWork(IDs.WORKER_1);

            try expect.equal(eng.getWorkerState(IDs.WORKER_1).?, .Idle);
            try expect.equal(eng.getWorkstationStatus(IDs.WORKSTATION_1).?, .Blocked);
        }
    };

    pub const @"priority" = struct {
        test "assigns to higher priority workstation" {
            f.resetHookCounters();
            var eng = f.createEngine();
            defer eng.deinit();

            // Two producer workstations with different priorities
            f.setupProducer(&eng, f.ProducerFactory.build(.{
                .priority = .Low,
            }));

            f.setupProducer(&eng, f.ProducerFactory.build(.{
                .ios_id = IDs.IOS_WATER_2,
                .eos_id = IDs.EOS_WATER_2,
                .workstation_id = IDs.WORKSTATION_2,
                .priority = .High,
            }));

            _ = eng.addWorker(IDs.WORKER_1, .{});

            // Worker should be assigned to high priority
            try expect.equal(eng.getWorkstationStatus(IDs.WORKSTATION_2).?, .Active);
            try expect.equal(eng.getWorkstationStatus(IDs.WORKSTATION_1).?, .Queued);
        }
    };

    // ========================================================================
    // Integration Tests
    // ========================================================================

    pub const @"integration: producer workstation" = struct {
        test "completes Process -> Store cycle (no Pickup)" {
            f.resetHookCounters();
            var eng = f.createEngine();
            defer eng.deinit();

            _ = eng.addWorker(IDs.WORKER_1, .{});
            f.setupProducer(&eng, f.ProducerFactory.build(.{}));

            // Process should have started immediately
            try expect.equal(f.g_process_started_calls, 1);
            try expect.equal(f.g_pickup_started_calls, 0); // No pickup for producer

            // Run process timer
            var i: u32 = 0;
            while (i < 3) : (i += 1) {
                eng.update();
            }

            // Process complete, IOS filled
            try expect.equal(f.g_process_complete_calls, 1);
            try expect.equal(eng.hasItem(IDs.IOS_WATER, .Water), true);

            // Store should have started
            try expect.equal(f.g_store_started_calls, 1);

            // Complete store
            eng.notifyStoreComplete(IDs.WORKER_1);

            // Water should be in EOS
            try expect.equal(eng.hasItem(IDs.IOS_WATER, .Water), false);
            try expect.equal(eng.hasItem(IDs.EOS_WATER, .Water), true);

            // Worker released and cycle counted
            try expect.equal(f.g_worker_released_calls, 1);
            try expect.equal(eng.getCyclesCompleted(IDs.WORKSTATION_1), 1);
        }
    };

    pub const @"integration: multi-item recipe" = struct {
        test "requires ALL recipe items to start" {
            f.resetHookCounters();
            var eng = f.createEngine();
            defer eng.deinit();

            // Kitchen with multi-item recipe (2 ingredients)
            _ = eng.addStorage(IDs.EIS_VEG, .{ .item = .Vegetable });
            _ = eng.addStorage(IDs.EIS_MEAT, .{ .item = .Meat });
            _ = eng.addStorage(IDs.IIS_VEG, .{ .item = .Vegetable });
            _ = eng.addStorage(IDs.IIS_MEAT, .{ .item = .Meat });
            _ = eng.addStorage(IDs.IOS_MEAL, .{ .item = .Meal });
            _ = eng.addStorage(IDs.EOS_MEAL, .{ .item = .Meal });

            _ = eng.addWorker(IDs.WORKER_1, .{});
            _ = eng.addWorkstation(IDs.WORKSTATION_1, .{
                .eis = &.{ IDs.EIS_VEG, IDs.EIS_MEAT },
                .iis = &.{ IDs.IIS_VEG, IDs.IIS_MEAT },
                .ios = &.{IDs.IOS_MEAL},
                .eos = &.{IDs.EOS_MEAL},
                .process_duration = 5,
            });

            // Blocked - no items
            try expect.equal(eng.getWorkstationStatus(IDs.WORKSTATION_1).?, .Blocked);

            // Add vegetable - still blocked (need meat)
            _ = eng.addToStorage(IDs.EIS_VEG, .Vegetable);
            try expect.equal(eng.getWorkstationStatus(IDs.WORKSTATION_1).?, .Blocked);

            // Add meat - now has full recipe, should start
            _ = eng.addToStorage(IDs.EIS_MEAT, .Meat);
            try expect.equal(eng.getWorkstationStatus(IDs.WORKSTATION_1).?, .Active);
        }
    };

    pub const @"integration: transport" = struct {
        test "starts when destination has space" {
            f.resetHookCounters();
            var eng = f.createEngine();
            defer eng.deinit();

            f.setupTransport(&eng, f.TransportFactory.build(.{ .item = .Water }));
            _ = eng.addWorker(IDs.WORKER_1, .{});

            // Add item to source
            _ = eng.addToStorage(IDs.SOURCE, .Water);

            // Transport should start
            try expect.equal(f.g_transport_started_calls, 1);
            try expect.equal(eng.getWorkerState(IDs.WORKER_1).?, .Working);
        }

        test "feeds workstation via transport chain" {
            f.resetHookCounters();
            var eng = f.createEngine();
            defer eng.deinit();

            // Garden (source)
            _ = eng.addStorage(IDs.GARDEN, .{ .item = .Vegetable });

            // Kitchen with EIS
            f.setupKitchen(&eng, f.KitchenFactory.build(.{}));

            // Transport from garden to kitchen EIS
            _ = eng.addTransport(.{
                .from = IDs.GARDEN,
                .to = IDs.EIS_VEG,
                .item = .Vegetable,
            });

            _ = eng.addWorker(IDs.WORKER_1, .{});

            // Kitchen blocked - no vegetables
            try expect.equal(eng.getWorkstationStatus(IDs.WORKSTATION_1).?, .Blocked);

            // Add vegetable to garden
            _ = eng.addToStorage(IDs.GARDEN, .Vegetable);

            // Transport should start
            try expect.equal(f.g_transport_started_calls, 1);

            // Complete transport
            eng.notifyTransportComplete(IDs.WORKER_1);

            // Vegetable now in kitchen EIS
            try expect.equal(eng.hasItem(IDs.EIS_VEG, .Vegetable), true);

            // Kitchen should start (pickup)
            try expect.equal(f.g_pickup_started_calls, 1);
            try expect.equal(eng.getWorkstationStatus(IDs.WORKSTATION_1).?, .Active);
        }
    };

    pub const @"integration: multiple workers" = struct {
        test "assigns multiple workers to different workstations" {
            f.resetHookCounters();
            var eng = f.createEngine();
            defer eng.deinit();

            // Two producer workstations
            f.setupProducer(&eng, f.ProducerFactory.build(.{
                .process_duration = 10,
            }));

            f.setupProducer(&eng, f.ProducerFactory.build(.{
                .ios_id = IDs.IOS_WATER_2,
                .eos_id = IDs.EOS_WATER_2,
                .workstation_id = IDs.WORKSTATION_2,
                .process_duration = 10,
            }));

            // Add two workers
            _ = eng.addWorker(IDs.WORKER_1, .{});
            _ = eng.addWorker(IDs.WORKER_2, .{});

            // Both workstations should be active
            try expect.equal(eng.getWorkstationStatus(IDs.WORKSTATION_1).?, .Active);
            try expect.equal(eng.getWorkstationStatus(IDs.WORKSTATION_2).?, .Active);
            try expect.equal(f.g_process_started_calls, 2);
        }

        test "worker takes next available work after completion" {
            f.resetHookCounters();
            var eng = f.createEngine();
            defer eng.deinit();

            // Two producer workstations
            f.setupProducer(&eng, f.ProducerFactory.build(.{
                .process_duration = 1,
            }));

            f.setupProducer(&eng, f.ProducerFactory.build(.{
                .ios_id = IDs.IOS_WATER_2,
                .eos_id = IDs.EOS_WATER_2,
                .workstation_id = IDs.WORKSTATION_2,
                .process_duration = 1,
            }));

            // Only one worker for two workstations
            _ = eng.addWorker(IDs.WORKER_1, .{});

            // First workstation active, second queued
            try expect.equal(eng.getWorkstationStatus(IDs.WORKSTATION_1).?, .Active);
            try expect.equal(eng.getWorkstationStatus(IDs.WORKSTATION_2).?, .Queued);
            try expect.equal(f.g_process_started_calls, 1);

            // Complete first cycle
            eng.update(); // Process
            eng.notifyStoreComplete(IDs.WORKER_1);

            // Worker should now be on second workstation
            try expect.equal(eng.getWorkstationStatus(IDs.WORKSTATION_2).?, .Active);
            try expect.equal(f.g_process_started_calls, 2);
        }
    };

    pub const @"integration: single-item storage" = struct {
        test "producer blocks when EOS is full" {
            f.resetHookCounters();
            var eng = f.createEngine();
            defer eng.deinit();

            _ = eng.addWorker(IDs.WORKER_1, .{});
            f.setupProducer(&eng, f.ProducerFactory.build(.{
                .process_duration = 1,
            }));

            // Complete first cycle
            try expect.equal(eng.getWorkstationStatus(IDs.WORKSTATION_1).?, .Active);
            eng.update(); // Process
            eng.notifyStoreComplete(IDs.WORKER_1);

            // EOS now has 1 water (full)
            try expect.equal(eng.hasItem(IDs.EOS_WATER, .Water), true);
            try expect.equal(eng.getCyclesCompleted(IDs.WORKSTATION_1), 1);

            // Workstation should be blocked (EOS full)
            try expect.equal(eng.getWorkstationStatus(IDs.WORKSTATION_1).?, .Blocked);

            // Remove item from EOS
            _ = eng.removeFromStorage(IDs.EOS_WATER, .Water);

            // Workstation should resume
            try expect.equal(eng.getWorkstationStatus(IDs.WORKSTATION_1).?, .Active);
        }
    };

    // ========================================================================
    // Multiple EIS/EOS Tests
    // ========================================================================

    pub const @"integration: multiple EIS" = struct {
        test "workstation picks from any EIS with item" {
            f.resetHookCounters();
            var eng = f.createEngine();
            defer eng.deinit();

            // Two EIS storages for same item type
            _ = eng.addStorage(IDs.EIS_VEG, .{ .item = .Vegetable }); // EIS 1
            _ = eng.addStorage(IDs.EIS_VEG_2, .{ .item = .Vegetable }); // EIS 2
            _ = eng.addStorage(IDs.IIS_VEG, .{ .item = .Vegetable });
            _ = eng.addStorage(IDs.IOS_MEAL, .{ .item = .Meal });
            _ = eng.addStorage(IDs.EOS_MEAL, .{ .item = .Meal });

            _ = eng.addWorker(IDs.WORKER_1, .{});
            _ = eng.addWorkstation(IDs.WORKSTATION_1, .{
                .eis = &.{ IDs.EIS_VEG, IDs.EIS_VEG_2 }, // Multiple EIS
                .iis = &.{IDs.IIS_VEG},
                .ios = &.{IDs.IOS_MEAL},
                .eos = &.{IDs.EOS_MEAL},
                .process_duration = 1,
            });

            // Add item only to second EIS
            _ = eng.addToStorage(IDs.EIS_VEG_2, .Vegetable);

            // Workstation should start (second EIS has item)
            try expect.equal(eng.getWorkstationStatus(IDs.WORKSTATION_1).?, .Active);
            try expect.equal(f.g_pickup_started_calls, 1);

            // Complete pickup - item from EIS 2 should transfer to IIS
            eng.notifyPickupComplete(IDs.WORKER_1);
            try expect.equal(eng.hasItem(IDs.EIS_VEG_2, .Vegetable), false);
            try expect.equal(eng.hasItem(IDs.IIS_VEG, .Vegetable), true);
        }

        test "workstation blocked when no EIS has required items" {
            f.resetHookCounters();
            var eng = f.createEngine();
            defer eng.deinit();

            // Two EIS storages with multi-item recipe
            _ = eng.addStorage(IDs.EIS_VEG, .{ .item = .Vegetable });
            _ = eng.addStorage(IDs.EIS_MEAT, .{ .item = .Meat });
            _ = eng.addStorage(IDs.IIS_VEG, .{ .item = .Vegetable });
            _ = eng.addStorage(IDs.IIS_MEAT, .{ .item = .Meat });
            _ = eng.addStorage(IDs.IOS_MEAL, .{ .item = .Meal });
            _ = eng.addStorage(IDs.EOS_MEAL, .{ .item = .Meal });

            _ = eng.addWorker(IDs.WORKER_1, .{});
            _ = eng.addWorkstation(IDs.WORKSTATION_1, .{
                .eis = &.{ IDs.EIS_VEG, IDs.EIS_MEAT },
                .iis = &.{ IDs.IIS_VEG, IDs.IIS_MEAT },
                .ios = &.{IDs.IOS_MEAL},
                .eos = &.{IDs.EOS_MEAL},
                .process_duration = 1,
            });

            // Add vegetable to EIS 1 - still need meat
            _ = eng.addToStorage(IDs.EIS_VEG, .Vegetable);

            // Workstation should be blocked (missing meat)
            try expect.equal(eng.getWorkstationStatus(IDs.WORKSTATION_1).?, .Blocked);

            // Add meat to EIS 2 - now has all items
            _ = eng.addToStorage(IDs.EIS_MEAT, .Meat);

            // Now should be active
            try expect.equal(eng.getWorkstationStatus(IDs.WORKSTATION_1).?, .Active);
        }
    };

    pub const @"integration: multiple EOS" = struct {
        test "workstation stores to first EOS with matching type" {
            f.resetHookCounters();
            var eng = f.createEngine();
            defer eng.deinit();

            // Producer with two EOS storages
            _ = eng.addStorage(IDs.IOS_WATER, .{ .item = .Water });
            _ = eng.addStorage(IDs.EOS_WATER, .{ .item = .Water }); // EOS 1
            _ = eng.addStorage(IDs.EOS_WATER_2, .{ .item = .Water }); // EOS 2

            _ = eng.addWorker(IDs.WORKER_1, .{});
            _ = eng.addWorkstation(IDs.WORKSTATION_1, .{
                .ios = &.{IDs.IOS_WATER},
                .eos = &.{ IDs.EOS_WATER, IDs.EOS_WATER_2 }, // Multiple EOS
                .process_duration = 1,
            });

            // Complete first cycle
            eng.update();
            eng.notifyStoreComplete(IDs.WORKER_1);

            // Water should be in first EOS
            try expect.equal(eng.hasItem(IDs.EOS_WATER, .Water), true);
            try expect.equal(eng.hasItem(IDs.EOS_WATER_2, .Water), false);
        }
    };

    // ========================================================================
    // Transfer Failure Tests
    // ========================================================================

    pub const @"integration: transfer failure handling" = struct {
        test "blocks workstation when EIS loses items before pickup complete" {
            f.resetHookCounters();
            var eng = f.createEngine();
            defer eng.deinit();

            _ = eng.addWorker(IDs.WORKER_1, .{});
            f.setupKitchen(&eng, f.KitchenFactory.build(.{}));

            // Add ingredient to start
            _ = eng.addToStorage(IDs.EIS_VEG, .Vegetable);
            try expect.equal(eng.getWorkstationStatus(IDs.WORKSTATION_1).?, .Active);
            try expect.equal(f.g_pickup_started_calls, 1);

            // Simulate item being removed while worker is en route
            _ = eng.removeFromStorage(IDs.EIS_VEG, .Vegetable);

            // Notify pickup complete - transfer should fail
            eng.notifyPickupComplete(IDs.WORKER_1);

            // Workstation should be blocked, worker released
            try expect.equal(eng.getWorkstationStatus(IDs.WORKSTATION_1).?, .Blocked);
            try expect.equal(eng.getWorkerState(IDs.WORKER_1).?, .Idle);

            // IIS should still be empty (no partial transfer)
            try expect.equal(eng.hasItem(IDs.IIS_VEG, .Vegetable), false);
        }
    };
};
