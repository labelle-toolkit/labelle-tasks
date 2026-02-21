//! Engine spec - tests for the pure state machine task engine
const std = @import("std");
const zspec = @import("zspec");
const tasks = @import("labelle_tasks");

const Item = enum { Flour, Water, Dough, Bread };

pub const Engine = zspec.describe("Engine", struct {
    pub const initialization = zspec.describe("initialization", struct {
        pub fn @"creates empty engine"() !void {
            const TestHooks = struct {};
            var engine = tasks.Engine(u32, Item, TestHooks).init(std.testing.allocator, .{}, null);
            defer engine.deinit();

            // Engine starts empty
            try std.testing.expect(engine.getStorageHasItem(1) == null);
            try std.testing.expect(engine.getWorkerState(1) == null);
            try std.testing.expect(engine.getWorkstationStatus(1) == null);
        }
    });

    pub const storage = zspec.describe("storage", struct {
        pub fn @"adds storage with item"() !void {
            const TestHooks = struct {};
            var engine = tasks.Engine(u32, Item, TestHooks).init(std.testing.allocator, .{}, null);
            defer engine.deinit();

            try engine.addStorage(1, .{ .role = .eis, .initial_item = .Flour });

            try std.testing.expect(engine.getStorageHasItem(1).? == true);
            try std.testing.expect(engine.getStorageItemType(1).? == .Flour);
        }

        pub fn @"adds empty storage"() !void {
            const TestHooks = struct {};
            var engine = tasks.Engine(u32, Item, TestHooks).init(std.testing.allocator, .{}, null);
            defer engine.deinit();

            try engine.addStorage(1, .{ .role = .eis });

            try std.testing.expect(engine.getStorageHasItem(1).? == false);
            try std.testing.expect(engine.getStorageItemType(1) == null);
        }

        pub fn @"updates storage on item_added"() !void {
            const TestHooks = struct {};
            var engine = tasks.Engine(u32, Item, TestHooks).init(std.testing.allocator, .{}, null);
            defer engine.deinit();

            try engine.addStorage(1, .{ .role = .eis });
            _ = engine.itemAdded(1, .Water);

            try std.testing.expect(engine.getStorageHasItem(1).? == true);
            try std.testing.expect(engine.getStorageItemType(1).? == .Water);
        }
    });

    pub const worker = zspec.describe("worker", struct {
        pub fn @"adds worker in idle state"() !void {
            const TestHooks = struct {};
            var engine = tasks.Engine(u32, Item, TestHooks).init(std.testing.allocator, .{}, null);
            defer engine.deinit();

            try engine.addWorker(10);

            try std.testing.expect(engine.getWorkerState(10).? == .Idle);
        }
    });

    pub const workstation = zspec.describe("workstation", struct {
        pub fn @"adds workstation with storages"() !void {
            const TestHooks = struct {};
            var engine = tasks.Engine(u32, Item, TestHooks).init(std.testing.allocator, .{}, null);
            defer engine.deinit();

            try engine.addStorage(1, .{ .role = .eis, .initial_item = .Flour });
            try engine.addStorage(2, .{ .role = .iis });
            try engine.addStorage(3, .{ .role = .ios });
            try engine.addStorage(4, .{ .role = .eos });

            try engine.addWorkstation(100, .{
                .eis = &.{1},
                .iis = &.{2},
                .ios = &.{3},
                .eos = &.{4},
            });

            // Workstation is queued because it has input and output space
            try std.testing.expect(engine.getWorkstationStatus(100).? == .Queued);
        }

        pub fn @"workstation blocked when no inputs"() !void {
            const TestHooks = struct {};
            var engine = tasks.Engine(u32, Item, TestHooks).init(std.testing.allocator, .{}, null);
            defer engine.deinit();

            try engine.addStorage(1, .{ .role = .eis }); // EIS empty
            try engine.addStorage(2, .{ .role = .iis });
            try engine.addStorage(3, .{ .role = .ios });
            try engine.addStorage(4, .{ .role = .eos });

            try engine.addWorkstation(100, .{
                .eis = &.{1},
                .iis = &.{2},
                .ios = &.{3},
                .eos = &.{4},
            });

            try std.testing.expect(engine.getWorkstationStatus(100).? == .Blocked);
        }
    });

    pub const workflow = zspec.describe("workflow", struct {
        pub fn @"assigns worker when available"() !void {
            var assigned = false;
            const TestHooks = struct {
                assigned_ptr: *bool,

                pub fn worker_assigned(self: *@This(), _: anytype) void {
                    self.assigned_ptr.* = true;
                }
            };

            var engine = tasks.Engine(u32, Item, TestHooks).init(
                std.testing.allocator,
                .{ .assigned_ptr = &assigned },
                null,
            );
            defer engine.deinit();

            try engine.addStorage(1, .{ .role = .eis, .initial_item = .Flour });
            try engine.addStorage(2, .{ .role = .iis });
            try engine.addStorage(3, .{ .role = .ios });
            try engine.addStorage(4, .{ .role = .eos });

            try engine.addWorkstation(100, .{
                .eis = &.{1},
                .iis = &.{2},
                .ios = &.{3},
                .eos = &.{4},
            });

            try engine.addWorker(10);
            _ = engine.workerAvailable(10);

            try std.testing.expect(assigned == true);
            try std.testing.expect(engine.getWorkerState(10).? == .Working);
            try std.testing.expect(engine.getWorkstationStatus(100).? == .Active);
        }

        pub fn @"full workflow cycle: Pickup -> Process -> Store -> Cycle"() !void {
            var cycle_count: u32 = 0;
            const TestHooks = struct {
                cycle_count_ptr: *u32,

                pub fn cycle_completed(self: *@This(), _: anytype) void {
                    self.cycle_count_ptr.* += 1;
                }
            };

            var engine = tasks.Engine(u32, Item, TestHooks).init(
                std.testing.allocator,
                .{ .cycle_count_ptr = &cycle_count },
                null,
            );
            defer engine.deinit();

            // Set up: EIS has Flour, IIS/IOS/EOS empty
            try engine.addStorage(1, .{ .role = .eis, .initial_item = .Flour });
            try engine.addStorage(2, .{ .role = .iis });
            try engine.addStorage(3, .{ .role = .ios });
            try engine.addStorage(4, .{ .role = .eos });

            try engine.addWorkstation(100, .{
                .eis = &.{1},
                .iis = &.{2},
                .ios = &.{3},
                .eos = &.{4},
            });

            try engine.addWorker(10);

            // Worker becomes available → assigned → pickup_started
            _ = engine.workerAvailable(10);
            try std.testing.expect(engine.getWorkerState(10).? == .Working);
            try std.testing.expect(engine.getWorkstationStatus(100).? == .Active);

            // Pickup complete → EIS cleared, IIS filled, process_started
            _ = engine.pickupCompleted(10);
            try std.testing.expect(engine.getStorageHasItem(1).? == false); // EIS cleared
            try std.testing.expect(engine.getStorageHasItem(2).? == true); // IIS filled

            // Work completed → IIS cleared, IOS filled, store_started
            // Game sets IOS item type via process_completed hook
            _ = engine.workCompleted(100);
            try std.testing.expect(engine.getStorageHasItem(2).? == false); // IIS cleared
            try std.testing.expect(engine.getStorageHasItem(3).? == true); // IOS filled

            // Store completed → IOS cleared, EOS filled, cycle complete
            _ = engine.storeCompleted(10);
            try std.testing.expect(engine.getStorageHasItem(3).? == false); // IOS cleared
            try std.testing.expect(engine.getStorageHasItem(4).? == true); // EOS filled

            // Cycle completed
            try std.testing.expectEqual(@as(u32, 1), cycle_count);

            // Worker released and idle
            try std.testing.expect(engine.getWorkerState(10).? == .Idle);
        }

        pub fn @"worker unavailable during active task releases workstation"() !void {
            const TestHooks = struct {};

            var engine = tasks.Engine(u32, Item, TestHooks).init(std.testing.allocator, .{}, null);
            defer engine.deinit();

            try engine.addStorage(1, .{ .role = .eis, .initial_item = .Flour });
            try engine.addStorage(2, .{ .role = .iis });
            try engine.addStorage(3, .{ .role = .ios });
            try engine.addStorage(4, .{ .role = .eos });

            try engine.addWorkstation(100, .{
                .eis = &.{1},
                .iis = &.{2},
                .ios = &.{3},
                .eos = &.{4},
            });

            try engine.addWorker(10);
            _ = engine.workerAvailable(10);

            // Worker is assigned and working
            try std.testing.expect(engine.getWorkerState(10).? == .Working);
            try std.testing.expect(engine.getWorkstationStatus(100).? == .Active);

            // Worker becomes unavailable mid-task
            _ = engine.handle(.{ .worker_unavailable = .{ .worker_id = 10 } });

            // Worker is now unavailable, workstation released back to Queued
            try std.testing.expect(engine.getWorkerState(10).? == .Unavailable);
            try std.testing.expect(engine.getWorkstationStatus(100).? == .Queued);
        }
    });

    pub const attach_storage = zspec.describe("attachStorageToWorkstation", struct {
        pub fn @"attaches storage to workstation after creation"() !void {
            const TestHooks = struct {};
            var engine = tasks.Engine(u32, Item, TestHooks).init(std.testing.allocator, .{}, null);
            defer engine.deinit();

            // Create storages and workstation separately
            try engine.addStorage(1, .{ .role = .eis, .initial_item = .Flour });
            try engine.addStorage(2, .{ .role = .iis });
            try engine.addStorage(3, .{ .role = .ios });
            try engine.addStorage(4, .{ .role = .eos });

            // Create workstation with no storages
            try engine.addWorkstation(100, .{
                .eis = &.{},
                .iis = &.{},
                .ios = &.{},
                .eos = &.{},
            });

            // Workstation is blocked (no storages)
            try std.testing.expect(engine.getWorkstationStatus(100).? == .Blocked);

            // Attach storages one by one
            try engine.attachStorageToWorkstation(1, 100, .eis);
            try engine.attachStorageToWorkstation(2, 100, .iis);
            try engine.attachStorageToWorkstation(3, 100, .ios);
            try engine.attachStorageToWorkstation(4, 100, .eos);

            // After attaching storages, it should be queued (EIS has item, EOS has space)
            // (attachStorageToWorkstation triggers re-evaluation automatically)
            try std.testing.expect(engine.getWorkstationStatus(100).? == .Queued);
        }
    });

    pub const dangling = zspec.describe("dangling items", struct {
        pub fn @"dangling item pickup and delivery"() !void {
            var dangling_pickup_started = false;
            var delivered = false;
            const TestHooks = struct {
                dangling_started_ptr: *bool,
                delivered_ptr: *bool,

                pub fn pickup_dangling_started(self: *@This(), _: anytype) void {
                    self.dangling_started_ptr.* = true;
                }

                pub fn item_delivered(self: *@This(), _: anytype) void {
                    self.delivered_ptr.* = true;
                }
            };

            var engine = tasks.Engine(u32, Item, TestHooks).init(
                std.testing.allocator,
                .{ .dangling_started_ptr = &dangling_pickup_started, .delivered_ptr = &delivered },
                null,
            );
            defer engine.deinit();

            // Set up an empty EIS that accepts Flour
            try engine.addStorage(1, .{ .role = .eis, .accepts = .Flour });
            try engine.addStorage(2, .{ .role = .iis });
            try engine.addStorage(3, .{ .role = .ios });
            try engine.addStorage(4, .{ .role = .eos });

            try engine.addWorkstation(100, .{
                .eis = &.{1},
                .iis = &.{2},
                .ios = &.{3},
                .eos = &.{4},
            });

            // Add worker and make available
            try engine.addWorker(10);
            _ = engine.workerAvailable(10);

            // Worker stays idle (no items in EIS to process)
            try std.testing.expect(engine.getWorkerState(10).? == .Idle);

            // Add dangling item - worker should be dispatched to pick it up
            try engine.addDanglingItem(50, .Flour);

            try std.testing.expect(dangling_pickup_started == true);
            try std.testing.expect(engine.getWorkerState(10).? == .Working);

            // Simulate pickup complete → moves to store phase
            _ = engine.pickupCompleted(10);

            // Simulate store complete → item delivered to EIS
            _ = engine.storeCompleted(10);

            try std.testing.expect(delivered == true);
            try std.testing.expect(engine.getStorageHasItem(1).? == true); // EIS now has item
            try std.testing.expect(engine.getDanglingItemType(50) == null); // Removed from tracking
        }

        pub fn @"multiple workers assigned to multiple dangling items in single call"() !void {
            var assignment_count: u32 = 0;
            const TestHooks = struct {
                count_ptr: *u32,

                pub fn pickup_dangling_started(self: *@This(), _: anytype) void {
                    self.count_ptr.* += 1;
                }
            };

            var engine = tasks.Engine(u32, Item, TestHooks).init(
                std.testing.allocator,
                .{ .count_ptr = &assignment_count },
                null,
            );
            defer engine.deinit();

            // Add 2 workers and make available (no work → stay idle)
            try engine.addWorker(10);
            _ = engine.workerAvailable(10);
            try engine.addWorker(20);
            _ = engine.workerAvailable(20);

            // No EIS yet → dangling items can't be assigned
            try engine.addDanglingItem(50, .Flour);
            try engine.addDanglingItem(51, .Water);

            try std.testing.expectEqual(@as(u32, 0), assignment_count);
            try std.testing.expect(engine.getWorkerState(10).? == .Idle);
            try std.testing.expect(engine.getWorkerState(20).? == .Idle);

            // Now add empty EIS that accept the items
            try engine.addStorage(1, .{ .role = .eis, .accepts = .Flour });
            try engine.addStorage(2, .{ .role = .eis, .accepts = .Water });

            // Single call should assign both workers
            engine.evaluateDanglingItems();

            try std.testing.expectEqual(@as(u32, 2), assignment_count);
            try std.testing.expect(engine.getWorkerState(10).? == .Working);
            try std.testing.expect(engine.getWorkerState(20).? == .Working);
        }

        pub fn @"EIS cleared by workstation pickup triggers dangling item assignment"() !void {
            var dangling_started = false;
            const TestHooks = struct {
                started_ptr: *bool,

                pub fn pickup_dangling_started(self: *@This(), _: anytype) void {
                    self.started_ptr.* = true;
                }
            };

            var engine = tasks.Engine(u32, Item, TestHooks).init(
                std.testing.allocator,
                .{ .started_ptr = &dangling_started },
                null,
            );
            defer engine.deinit();

            // Workstation with a filled EIS
            try engine.addStorage(1, .{ .role = .eis, .initial_item = .Flour, .accepts = .Flour });
            try engine.addStorage(2, .{ .role = .iis });
            try engine.addStorage(3, .{ .role = .ios });
            try engine.addStorage(4, .{ .role = .eos });

            try engine.addWorkstation(100, .{
                .eis = &.{1},
                .iis = &.{2},
                .ios = &.{3},
                .eos = &.{4},
            });

            // Worker 10: gets assigned to workstation pickup (EIS → IIS)
            try engine.addWorker(10);
            _ = engine.workerAvailable(10);
            try std.testing.expect(engine.getWorkerState(10).? == .Working);

            // Worker 20: idle, no work available
            try engine.addWorker(20);
            _ = engine.workerAvailable(20);
            try std.testing.expect(engine.getWorkerState(20).? == .Idle);

            // Add dangling item — EIS is full, so no assignment yet
            try engine.addDanglingItem(50, .Flour);
            try std.testing.expect(dangling_started == false);
            try std.testing.expect(engine.getWorkerState(20).? == .Idle);

            // Worker 10 completes pickup → clears EIS → should trigger dangling assignment
            _ = engine.pickupCompleted(10);

            // Worker 20 should now be assigned to deliver dangling item to the freed EIS
            try std.testing.expect(dangling_started == true);
            try std.testing.expect(engine.getWorkerState(20).? == .Working);
        }
    });

    pub const producer = zspec.describe("producer workstation", struct {
        pub fn @"producer completes cycle without EIS"() !void {
            var cycle_count: u32 = 0;
            const TestHooks = struct {
                cycle_count_ptr: *u32,

                pub fn cycle_completed(self: *@This(), _: anytype) void {
                    self.cycle_count_ptr.* += 1;
                }
            };

            var engine = tasks.Engine(u32, Item, TestHooks).init(
                std.testing.allocator,
                .{ .cycle_count_ptr = &cycle_count },
                null,
            );
            defer engine.deinit();

            // Producer has no EIS - just IOS and EOS
            try engine.addStorage(3, .{ .role = .ios });
            try engine.addStorage(4, .{ .role = .eos });

            try engine.addWorkstation(100, .{
                .eis = &.{},
                .iis = &.{},
                .ios = &.{3},
                .eos = &.{4},
            });

            try engine.addWorker(10);
            _ = engine.workerAvailable(10);

            // Producer goes straight to Process (no pickup needed)
            try std.testing.expect(engine.getWorkerState(10).? == .Working);

            // Work completed → IOS filled
            _ = engine.workCompleted(100);
            try std.testing.expect(engine.getStorageHasItem(3).? == true);

            // Store completed → IOS→EOS, cycle complete
            _ = engine.storeCompleted(10);
            try std.testing.expect(engine.getStorageHasItem(3).? == false);
            try std.testing.expect(engine.getStorageHasItem(4).? == true);
            try std.testing.expectEqual(@as(u32, 1), cycle_count);
            try std.testing.expect(engine.getWorkerState(10).? == .Idle);
        }
    });

    pub const item_removal = zspec.describe("item removal", struct {
        pub fn @"item_removed clears storage state"() !void {
            const TestHooks = struct {};
            var engine = tasks.Engine(u32, Item, TestHooks).init(std.testing.allocator, .{}, null);
            defer engine.deinit();

            try engine.addStorage(1, .{ .role = .eis, .initial_item = .Flour });
            try std.testing.expect(engine.getStorageHasItem(1).? == true);

            _ = engine.itemRemoved(1);
            try std.testing.expect(engine.getStorageHasItem(1).? == false);
            try std.testing.expect(engine.getStorageItemType(1) == null);
        }

        pub fn @"item_removed unblocks workstation"() !void {
            const TestHooks = struct {};
            var engine = tasks.Engine(u32, Item, TestHooks).init(std.testing.allocator, .{}, null);
            defer engine.deinit();

            // Full EOS blocks workstation
            try engine.addStorage(1, .{ .role = .eis, .initial_item = .Flour });
            try engine.addStorage(2, .{ .role = .iis });
            try engine.addStorage(3, .{ .role = .ios });
            try engine.addStorage(4, .{ .role = .eos, .initial_item = .Bread }); // EOS full

            try engine.addWorkstation(100, .{
                .eis = &.{1},
                .iis = &.{2},
                .ios = &.{3},
                .eos = &.{4},
            });

            try std.testing.expect(engine.getWorkstationStatus(100).? == .Blocked);

            // Remove item from EOS → workstation becomes Queued
            _ = engine.itemRemoved(4);
            try std.testing.expect(engine.getWorkstationStatus(100).? == .Queued);
        }
    });

    pub const worker_lifecycle = zspec.describe("worker lifecycle", struct {
        pub fn @"worker_removed releases from workstation"() !void {
            const TestHooks = struct {};
            var engine = tasks.Engine(u32, Item, TestHooks).init(std.testing.allocator, .{}, null);
            defer engine.deinit();

            try engine.addStorage(1, .{ .role = .eis, .initial_item = .Flour });
            try engine.addStorage(2, .{ .role = .iis });
            try engine.addStorage(3, .{ .role = .ios });
            try engine.addStorage(4, .{ .role = .eos });

            try engine.addWorkstation(100, .{
                .eis = &.{1},
                .iis = &.{2},
                .ios = &.{3},
                .eos = &.{4},
            });

            try engine.addWorker(10);
            _ = engine.workerAvailable(10);

            try std.testing.expect(engine.getWorkstationStatus(100).? == .Active);

            // Remove worker entirely
            _ = engine.handle(.{ .worker_removed = .{ .worker_id = 10 } });

            try std.testing.expect(engine.getWorkerState(10) == null); // Worker gone
            try std.testing.expect(engine.getWorkstationStatus(100).? == .Queued); // WS released
        }

        pub fn @"workstation disabled releases worker"() !void {
            const TestHooks = struct {};
            var engine = tasks.Engine(u32, Item, TestHooks).init(std.testing.allocator, .{}, null);
            defer engine.deinit();

            try engine.addStorage(1, .{ .role = .eis, .initial_item = .Flour });
            try engine.addStorage(2, .{ .role = .iis });
            try engine.addStorage(3, .{ .role = .ios });
            try engine.addStorage(4, .{ .role = .eos });

            try engine.addWorkstation(100, .{
                .eis = &.{1},
                .iis = &.{2},
                .ios = &.{3},
                .eos = &.{4},
            });

            try engine.addWorker(10);
            _ = engine.workerAvailable(10);

            try std.testing.expect(engine.getWorkerState(10).? == .Working);

            // Disable workstation
            _ = engine.handle(.{ .workstation_disabled = .{ .workstation_id = 100 } });

            try std.testing.expect(engine.getWorkerState(10).? == .Idle);
            try std.testing.expect(engine.getWorkstationStatus(100).? == .Blocked);
        }
    });

    pub const edge_cases = zspec.describe("edge cases", struct {
        pub fn @"redundant worker_available on working worker is ignored"() !void {
            var assign_count: u32 = 0;
            const TestHooks = struct {
                count_ptr: *u32,

                pub fn worker_assigned(self: *@This(), _: anytype) void {
                    self.count_ptr.* += 1;
                }
            };

            var engine = tasks.Engine(u32, Item, TestHooks).init(
                std.testing.allocator,
                .{ .count_ptr = &assign_count },
                null,
            );
            defer engine.deinit();

            try engine.addStorage(1, .{ .role = .eis, .initial_item = .Flour });
            try engine.addStorage(2, .{ .role = .iis });
            try engine.addStorage(3, .{ .role = .ios });
            try engine.addStorage(4, .{ .role = .eos });

            try engine.addWorkstation(100, .{
                .eis = &.{1},
                .iis = &.{2},
                .ios = &.{3},
                .eos = &.{4},
            });

            try engine.addWorker(10);
            try std.testing.expect(engine.workerAvailable(10));

            try std.testing.expect(engine.getWorkerState(10).? == .Working);
            try std.testing.expectEqual(@as(u32, 1), assign_count);

            // Redundant call — should be ignored since worker is already working
            try std.testing.expect(engine.workerAvailable(10));

            try std.testing.expect(engine.getWorkerState(10).? == .Working);
            try std.testing.expectEqual(@as(u32, 1), assign_count); // no second assignment
        }

        pub fn @"store_completed on worker without workstation recovers to idle"() !void {
            var released = false;
            const TestHooks = struct {
                released_ptr: *bool,

                pub fn worker_released(self: *@This(), _: anytype) void {
                    self.released_ptr.* = true;
                }
            };

            var engine = tasks.Engine(u32, Item, TestHooks).init(
                std.testing.allocator,
                .{ .released_ptr = &released },
                null,
            );
            defer engine.deinit();

            try engine.addWorker(10);
            try std.testing.expect(engine.workerAvailable(10));

            // Manually set worker to Working but with no assigned workstation
            // This simulates the reentrancy scenario from handlers.zig:425
            engine.workers.getPtr(10).?.state = .Working;
            engine.markWorkerBusy(10);

            // storeCompleted recovers gracefully — sets worker idle and dispatches
            // worker_released, returning success (true) rather than an error
            try std.testing.expect(engine.storeCompleted(10));

            // Worker should recover to idle
            try std.testing.expect(engine.getWorkerState(10).? == .Idle);
            try std.testing.expect(released == true);
        }

        pub fn @"multiple workers compete for one workstation"() !void {
            var assign_count: u32 = 0;
            const TestHooks = struct {
                count_ptr: *u32,

                pub fn worker_assigned(self: *@This(), _: anytype) void {
                    self.count_ptr.* += 1;
                }
            };

            var engine = tasks.Engine(u32, Item, TestHooks).init(
                std.testing.allocator,
                .{ .count_ptr = &assign_count },
                null,
            );
            defer engine.deinit();

            try engine.addStorage(1, .{ .role = .eis, .initial_item = .Flour });
            try engine.addStorage(2, .{ .role = .iis });
            try engine.addStorage(3, .{ .role = .ios });
            try engine.addStorage(4, .{ .role = .eos });

            try engine.addWorkstation(100, .{
                .eis = &.{1},
                .iis = &.{2},
                .ios = &.{3},
                .eos = &.{4},
            });

            // Add 3 workers — only 1 workstation available
            try engine.addWorker(10);
            try engine.addWorker(20);
            try engine.addWorker(30);
            try std.testing.expect(engine.workerAvailable(10));
            try std.testing.expect(engine.workerAvailable(20));
            try std.testing.expect(engine.workerAvailable(30));

            // Only one should be assigned
            try std.testing.expectEqual(@as(u32, 1), assign_count);
            try std.testing.expect(engine.getWorkstationStatus(100).? == .Active);

            // One working, two idle
            var working: u32 = 0;
            var idle: u32 = 0;
            for ([_]u32{ 10, 20, 30 }) |wid| {
                switch (engine.getWorkerState(wid).?) {
                    .Working => working += 1,
                    .Idle => idle += 1,
                    .Unavailable => return error.UnexpectedState,
                }
            }
            try std.testing.expectEqual(@as(u32, 1), working);
            try std.testing.expectEqual(@as(u32, 2), idle);
        }

        pub fn @"cycle restart when conditions are met continues immediately"() !void {
            const Recorder = tasks.RecordingHooks(u32, Item);
            var hooks: Recorder = .{};
            hooks.init(std.testing.allocator);

            var engine = tasks.Engine(u32, Item, Recorder).init(
                std.testing.allocator,
                hooks,
                null,
            );
            defer engine.deinit();
            defer engine.dispatcher.hooks.deinit();

            try engine.addStorage(1, .{ .role = .eis, .initial_item = .Flour });
            try engine.addStorage(2, .{ .role = .iis });
            try engine.addStorage(3, .{ .role = .ios });
            try engine.addStorage(4, .{ .role = .eos });

            try engine.addWorkstation(100, .{
                .eis = &.{1},
                .iis = &.{2},
                .ios = &.{3},
                .eos = &.{4},
            });

            try engine.addWorker(10);
            try std.testing.expect(engine.workerAvailable(10));

            // Complete first cycle
            try std.testing.expect(engine.pickupCompleted(10));
            try std.testing.expect(engine.workCompleted(100));
            try std.testing.expect(engine.storeCompleted(10));

            // After first cycle, EOS 4 is full so workstation can't restart — worker released
            try std.testing.expect(engine.getWorkerState(10).? == .Idle);

            // Clear events before triggering re-evaluation
            engine.dispatcher.hooks.clear();

            // Clear EOS and refill EIS so workstation can operate again.
            // Assignment happens during reevaluateAffectedWorkstations inside itemAdded.
            try std.testing.expect(engine.itemRemoved(4));
            try std.testing.expect(engine.itemAdded(1, .Flour));

            // Worker should be assigned via reevaluation
            try std.testing.expect(engine.getWorkerState(10).? == .Working);
            _ = try engine.dispatcher.hooks.expectNext(.workstation_queued);
            _ = try engine.dispatcher.hooks.expectNext(.worker_assigned);
            _ = try engine.dispatcher.hooks.expectNext(.workstation_activated);
            _ = try engine.dispatcher.hooks.expectNext(.pickup_started);
        }

        pub fn @"immediate cycle restart when EOS has space and EIS has items"() !void {
            var cycle_count: u32 = 0;
            const TestHooks = struct {
                cycle_count_ptr: *u32,

                pub fn cycle_completed(self: *@This(), _: anytype) void {
                    self.cycle_count_ptr.* += 1;
                }
            };

            var engine = tasks.Engine(u32, Item, TestHooks).init(
                std.testing.allocator,
                .{ .cycle_count_ptr = &cycle_count },
                null,
            );
            defer engine.deinit();

            // Setup with 2 EOS slots so second cycle can proceed
            try engine.addStorage(1, .{ .role = .eis, .initial_item = .Flour });
            try engine.addStorage(2, .{ .role = .iis });
            try engine.addStorage(3, .{ .role = .ios });
            try engine.addStorage(4, .{ .role = .eos });
            try engine.addStorage(6, .{ .role = .eos }); // Extra EOS

            try engine.addWorkstation(100, .{
                .eis = &.{1},
                .iis = &.{2},
                .ios = &.{3},
                .eos = &.{ 4, 6 },
            });

            try engine.addWorker(10);
            try std.testing.expect(engine.workerAvailable(10));

            // Complete first cycle
            try std.testing.expect(engine.pickupCompleted(10));
            try std.testing.expect(engine.workCompleted(100));

            // Before store completes, add item back to EIS so next cycle is possible
            try std.testing.expect(engine.itemAdded(1, .Flour));

            try std.testing.expect(engine.storeCompleted(10));

            try std.testing.expectEqual(@as(u32, 1), cycle_count);
            // Worker should stay working (immediate restart)
            try std.testing.expect(engine.getWorkerState(10).? == .Working);
        }

        pub fn @"item_added to full storage returns false"() !void {
            const TestHooks = struct {};
            var engine = tasks.Engine(u32, Item, TestHooks).init(std.testing.allocator, .{}, null);
            defer engine.deinit();

            try engine.addStorage(1, .{ .role = .eis, .initial_item = .Flour });

            // Adding to a full storage should fail
            const result = engine.itemAdded(1, .Water);
            try std.testing.expect(result == false);
            // Original item should be preserved
            try std.testing.expect(engine.getStorageItemType(1).? == .Flour);
        }

        pub fn @"handle returns false for unknown entities"() !void {
            const TestHooks = struct {};
            var engine = tasks.Engine(u32, Item, TestHooks).init(std.testing.allocator, .{}, null);
            defer engine.deinit();

            // All of these reference entities that don't exist
            try std.testing.expect(engine.handle(.{ .item_added = .{ .storage_id = 999, .item = .Flour } }) == false);
            try std.testing.expect(engine.handle(.{ .item_removed = .{ .storage_id = 999 } }) == false);
            try std.testing.expect(engine.handle(.{ .worker_available = .{ .worker_id = 999 } }) == false);
            try std.testing.expect(engine.handle(.{ .worker_unavailable = .{ .worker_id = 999 } }) == false);
            try std.testing.expect(engine.handle(.{ .pickup_completed = .{ .worker_id = 999 } }) == false);
            try std.testing.expect(engine.handle(.{ .work_completed = .{ .workstation_id = 999 } }) == false);
            try std.testing.expect(engine.handle(.{ .store_completed = .{ .worker_id = 999 } }) == false);
        }

        pub fn @"workstation removed while worker is active releases worker"() !void {
            var released = false;
            const TestHooks = struct {
                released_ptr: *bool,

                pub fn worker_released(self: *@This(), _: anytype) void {
                    self.released_ptr.* = true;
                }
            };

            var engine = tasks.Engine(u32, Item, TestHooks).init(
                std.testing.allocator,
                .{ .released_ptr = &released },
                null,
            );
            defer engine.deinit();

            try engine.addStorage(1, .{ .role = .eis, .initial_item = .Flour });
            try engine.addStorage(2, .{ .role = .iis });
            try engine.addStorage(3, .{ .role = .ios });
            try engine.addStorage(4, .{ .role = .eos });

            try engine.addWorkstation(100, .{
                .eis = &.{1},
                .iis = &.{2},
                .ios = &.{3},
                .eos = &.{4},
            });

            try engine.addWorker(10);
            try std.testing.expect(engine.workerAvailable(10));

            try std.testing.expect(engine.getWorkerState(10).? == .Working);
            try std.testing.expect(engine.getWorkstationStatus(100).? == .Active);

            // Remove workstation while worker is active
            try std.testing.expect(engine.handle(.{ .workstation_removed = .{ .workstation_id = 100 } }));

            try std.testing.expect(engine.getWorkerState(10).? == .Idle);
            try std.testing.expect(engine.getWorkstationStatus(100) == null); // gone
            try std.testing.expect(released == true);
        }

        pub fn @"dangling item disappears during pickup triggers recovery"() !void {
            const TestHooks = struct {};

            var engine = tasks.Engine(u32, Item, TestHooks).init(std.testing.allocator, .{}, null);
            defer engine.deinit();

            try engine.addStorage(1, .{ .role = .eis, .accepts = .Flour });
            try engine.addStorage(2, .{ .role = .iis });
            try engine.addStorage(3, .{ .role = .ios });
            try engine.addStorage(4, .{ .role = .eos });

            try engine.addWorkstation(100, .{
                .eis = &.{1},
                .iis = &.{2},
                .ios = &.{3},
                .eos = &.{4},
            });

            try engine.addWorker(10);
            try std.testing.expect(engine.workerAvailable(10));

            // Add dangling item — worker dispatched to pick it up
            try engine.addDanglingItem(50, .Flour);
            try std.testing.expect(engine.getWorkerState(10).? == .Working);

            // Dangling item despawned before pickup completes
            engine.removeDanglingItem(50);

            // pickup_completed should handle the missing item and recover
            try std.testing.expect(engine.pickupCompleted(10) == false); // error returned

            // Worker should recover to idle
            try std.testing.expect(engine.getWorkerState(10).? == .Idle);
        }

        pub fn @"dangling item disappears during store triggers recovery"() !void {
            const TestHooks = struct {};

            var engine = tasks.Engine(u32, Item, TestHooks).init(std.testing.allocator, .{}, null);
            defer engine.deinit();

            try engine.addStorage(1, .{ .role = .eis, .accepts = .Flour });
            try engine.addStorage(2, .{ .role = .iis });
            try engine.addStorage(3, .{ .role = .ios });
            try engine.addStorage(4, .{ .role = .eos });

            try engine.addWorkstation(100, .{
                .eis = &.{1},
                .iis = &.{2},
                .ios = &.{3},
                .eos = &.{4},
            });

            try engine.addWorker(10);
            try std.testing.expect(engine.workerAvailable(10));

            try engine.addDanglingItem(50, .Flour);
            try std.testing.expect(engine.getWorkerState(10).? == .Working);

            // Complete pickup
            try std.testing.expect(engine.pickupCompleted(10));

            // Now remove the dangling item before store completes
            engine.removeDanglingItem(50);

            // store_completed should recover
            try std.testing.expect(engine.storeCompleted(10) == false);

            // Worker should recover to idle
            try std.testing.expect(engine.getWorkerState(10).? == .Idle);
        }

        pub fn @"two dangling items compete for one EIS"() !void {
            var assignment_count: u32 = 0;
            const TestHooks = struct {
                count_ptr: *u32,

                pub fn pickup_dangling_started(self: *@This(), _: anytype) void {
                    self.count_ptr.* += 1;
                }
            };

            var engine = tasks.Engine(u32, Item, TestHooks).init(
                std.testing.allocator,
                .{ .count_ptr = &assignment_count },
                null,
            );
            defer engine.deinit();

            // Only one empty EIS
            try engine.addStorage(1, .{ .role = .eis, .accepts = .Flour });

            // Two workers, two dangling items
            try engine.addWorker(10);
            try engine.addWorker(20);
            try std.testing.expect(engine.workerAvailable(10));
            try std.testing.expect(engine.workerAvailable(20));

            try engine.addDanglingItem(50, .Flour);
            try engine.addDanglingItem(51, .Flour);

            // Only one should be assigned (only one EIS slot)
            try std.testing.expectEqual(@as(u32, 1), assignment_count);
        }

        pub fn @"pickup_completed with multiple IIS fills them sequentially"() !void {
            const TestHooks = struct {};
            var engine = tasks.Engine(u32, Item, TestHooks).init(std.testing.allocator, .{}, null);
            defer engine.deinit();

            // Two EIS with items, two IIS (recipe needs 2 ingredients)
            try engine.addStorage(1, .{ .role = .eis, .initial_item = .Flour });
            try engine.addStorage(5, .{ .role = .eis, .initial_item = .Water });
            try engine.addStorage(2, .{ .role = .iis });
            try engine.addStorage(6, .{ .role = .iis });
            try engine.addStorage(3, .{ .role = .ios });
            try engine.addStorage(4, .{ .role = .eos });

            try engine.addWorkstation(100, .{
                .eis = &.{ 1, 5 },
                .iis = &.{ 2, 6 },
                .ios = &.{3},
                .eos = &.{4},
            });

            try engine.addWorker(10);
            try std.testing.expect(engine.workerAvailable(10));

            // First pickup — fills IIS 2, but IIS 6 still empty → needs another pickup
            try std.testing.expect(engine.pickupCompleted(10));
            try std.testing.expect(engine.getStorageHasItem(2).? == true);
            try std.testing.expect(engine.getStorageHasItem(6).? == false);

            // Second pickup — fills IIS 6, both IIS full → process starts
            try std.testing.expect(engine.pickupCompleted(10));
            try std.testing.expect(engine.getStorageHasItem(2).? == true);
            try std.testing.expect(engine.getStorageHasItem(6).? == true);
        }

        pub fn @"worker becomes unavailable then available again gets reassigned"() !void {
            var assign_count: u32 = 0;
            const TestHooks = struct {
                count_ptr: *u32,

                pub fn worker_assigned(self: *@This(), _: anytype) void {
                    self.count_ptr.* += 1;
                }
            };

            var engine = tasks.Engine(u32, Item, TestHooks).init(
                std.testing.allocator,
                .{ .count_ptr = &assign_count },
                null,
            );
            defer engine.deinit();

            try engine.addStorage(1, .{ .role = .eis, .initial_item = .Flour });
            try engine.addStorage(2, .{ .role = .iis });
            try engine.addStorage(3, .{ .role = .ios });
            try engine.addStorage(4, .{ .role = .eos });

            try engine.addWorkstation(100, .{
                .eis = &.{1},
                .iis = &.{2},
                .ios = &.{3},
                .eos = &.{4},
            });

            try engine.addWorker(10);
            try std.testing.expect(engine.workerAvailable(10));
            try std.testing.expectEqual(@as(u32, 1), assign_count);

            // Worker goes unavailable (eating/sleeping)
            try std.testing.expect(engine.handle(.{ .worker_unavailable = .{ .worker_id = 10 } }));
            try std.testing.expect(engine.getWorkerState(10).? == .Unavailable);
            try std.testing.expect(engine.getWorkstationStatus(100).? == .Queued);

            // Worker comes back
            try std.testing.expect(engine.workerAvailable(10));
            try std.testing.expect(engine.getWorkerState(10).? == .Working);
            try std.testing.expectEqual(@as(u32, 2), assign_count);
        }

        pub fn @"multiple IOS stores are handled sequentially"() !void {
            var cycle_count: u32 = 0;
            const TestHooks = struct {
                cycle_count_ptr: *u32,

                pub fn cycle_completed(self: *@This(), _: anytype) void {
                    self.cycle_count_ptr.* += 1;
                }
            };

            var engine = tasks.Engine(u32, Item, TestHooks).init(
                std.testing.allocator,
                .{ .cycle_count_ptr = &cycle_count },
                null,
            );
            defer engine.deinit();

            // Producer with 2 IOS and 2 EOS
            try engine.addStorage(3, .{ .role = .ios });
            try engine.addStorage(7, .{ .role = .ios });
            try engine.addStorage(4, .{ .role = .eos });
            try engine.addStorage(8, .{ .role = .eos });

            try engine.addWorkstation(100, .{
                .eis = &.{},
                .iis = &.{},
                .ios = &.{ 3, 7 },
                .eos = &.{ 4, 8 },
            });

            try engine.addWorker(10);
            try std.testing.expect(engine.workerAvailable(10));

            // Work completed fills both IOS
            try std.testing.expect(engine.workCompleted(100));
            try std.testing.expect(engine.getStorageHasItem(3).? == true);
            try std.testing.expect(engine.getStorageHasItem(7).? == true);

            // First store — moves one IOS to EOS
            try std.testing.expect(engine.storeCompleted(10));
            try std.testing.expectEqual(@as(u32, 0), cycle_count); // not done yet

            // Second store — moves remaining IOS to EOS, cycle completes
            try std.testing.expect(engine.storeCompleted(10));
            try std.testing.expectEqual(@as(u32, 1), cycle_count);
        }

        pub fn @"storage_cleared removes storage from engine tracking"() !void {
            const TestHooks = struct {};
            var engine = tasks.Engine(u32, Item, TestHooks).init(std.testing.allocator, .{}, null);
            defer engine.deinit();

            try engine.addStorage(1, .{ .role = .eis, .initial_item = .Flour });
            try std.testing.expect(engine.getStorageHasItem(1).? == true);

            try std.testing.expect(engine.handle(.{ .storage_cleared = .{ .storage_id = 1 } }));

            // Storage should be completely gone
            try std.testing.expect(engine.getStorageHasItem(1) == null);
        }

        pub fn @"worker removed during dangling item delivery cleans up"() !void {
            const TestHooks = struct {};
            var engine = tasks.Engine(u32, Item, TestHooks).init(std.testing.allocator, .{}, null);
            defer engine.deinit();

            try engine.addStorage(1, .{ .role = .eis, .accepts = .Flour });
            try engine.addWorker(10);
            try std.testing.expect(engine.workerAvailable(10));

            try engine.addDanglingItem(50, .Flour);
            try std.testing.expect(engine.getWorkerState(10).? == .Working);

            // Remove worker while delivering
            try std.testing.expect(engine.handle(.{ .worker_removed = .{ .worker_id = 10 } }));
            try std.testing.expect(engine.getWorkerState(10) == null); // gone

            // Dangling item is still tracked (no worker to deliver it)
            try std.testing.expect(engine.getDanglingItemType(50).? == .Flour);
        }

        pub fn @"producer immediate cycle restart with space"() !void {
            var cycle_count: u32 = 0;
            const TestHooks = struct {
                cycle_count_ptr: *u32,

                pub fn cycle_completed(self: *@This(), _: anytype) void {
                    self.cycle_count_ptr.* += 1;
                }
            };

            var engine = tasks.Engine(u32, Item, TestHooks).init(
                std.testing.allocator,
                .{ .cycle_count_ptr = &cycle_count },
                null,
            );
            defer engine.deinit();

            // Producer with 2 EOS — can do 2 cycles
            try engine.addStorage(3, .{ .role = .ios });
            try engine.addStorage(4, .{ .role = .eos });
            try engine.addStorage(8, .{ .role = .eos });

            try engine.addWorkstation(100, .{
                .eis = &.{},
                .iis = &.{},
                .ios = &.{3},
                .eos = &.{ 4, 8 },
            });

            try engine.addWorker(10);
            try std.testing.expect(engine.workerAvailable(10));

            // First cycle
            try std.testing.expect(engine.workCompleted(100));
            try std.testing.expect(engine.storeCompleted(10));
            try std.testing.expectEqual(@as(u32, 1), cycle_count);

            // Worker should immediately start second cycle (EOS 8 still empty)
            try std.testing.expect(engine.getWorkerState(10).? == .Working);

            // Second cycle
            try std.testing.expect(engine.workCompleted(100));
            try std.testing.expect(engine.storeCompleted(10));
            try std.testing.expectEqual(@as(u32, 2), cycle_count);

            // No more EOS space — worker should be released
            try std.testing.expect(engine.getWorkerState(10).? == .Idle);
        }

        pub fn @"pickup_completed on worker not in pickup step returns false"() !void {
            const TestHooks = struct {};
            var engine = tasks.Engine(u32, Item, TestHooks).init(std.testing.allocator, .{}, null);
            defer engine.deinit();

            try engine.addStorage(1, .{ .role = .eis, .initial_item = .Flour });
            try engine.addStorage(2, .{ .role = .iis });
            try engine.addStorage(3, .{ .role = .ios });
            try engine.addStorage(4, .{ .role = .eos });

            try engine.addWorkstation(100, .{
                .eis = &.{1},
                .iis = &.{2},
                .ios = &.{3},
                .eos = &.{4},
            });

            try engine.addWorker(10);
            try std.testing.expect(engine.workerAvailable(10));

            // Complete pickup → now in Process step
            try std.testing.expect(engine.pickupCompleted(10));

            // Calling pickup_completed again on a worker not in the pickup step should fail
            try std.testing.expect(engine.handle(.{ .pickup_completed = .{ .worker_id = 10 } }) == false);
        }

        pub fn @"work_completed on workstation not in process step returns false"() !void {
            const TestHooks = struct {};
            var engine = tasks.Engine(u32, Item, TestHooks).init(std.testing.allocator, .{}, null);
            defer engine.deinit();

            try engine.addStorage(1, .{ .role = .eis, .initial_item = .Flour });
            try engine.addStorage(2, .{ .role = .iis });
            try engine.addStorage(3, .{ .role = .ios });
            try engine.addStorage(4, .{ .role = .eos });

            try engine.addWorkstation(100, .{
                .eis = &.{1},
                .iis = &.{2},
                .ios = &.{3},
                .eos = &.{4},
            });

            try engine.addWorker(10);
            try std.testing.expect(engine.workerAvailable(10));

            // Workstation is in Pickup step, not Process
            try std.testing.expect(engine.handle(.{ .work_completed = .{ .workstation_id = 100 } }) == false);
        }

        pub fn @"removeWorkstation cleans up reverse index"() !void {
            const TestHooks = struct {};
            var engine = tasks.Engine(u32, Item, TestHooks).init(std.testing.allocator, .{}, null);
            defer engine.deinit();

            try engine.addStorage(1, .{ .role = .eis, .initial_item = .Flour });
            try engine.addStorage(2, .{ .role = .iis });
            try engine.addStorage(3, .{ .role = .ios });
            try engine.addStorage(4, .{ .role = .eos });

            try engine.addWorkstation(100, .{
                .eis = &.{1},
                .iis = &.{2},
                .ios = &.{3},
                .eos = &.{4},
            });

            // Verify reverse index exists
            try std.testing.expect(engine.storage_to_workstations.get(1) != null);

            engine.removeWorkstation(100);

            // Reverse index should be cleaned up
            try std.testing.expect(engine.storage_to_workstations.get(1) == null);
            try std.testing.expect(engine.getWorkstationStatus(100) == null);
        }
    });

    pub const priority = zspec.describe("priority-based selection", struct {
        pub fn @"selectEis picks highest priority EIS"() !void {
            const TestHooks = struct {};
            var engine = tasks.Engine(u32, Item, TestHooks).init(std.testing.allocator, .{}, null);
            defer engine.deinit();

            // Two EIS with items: id=1 Low priority, id=5 High priority
            try engine.addStorage(1, .{ .role = .eis, .initial_item = .Flour, .priority = .Low });
            try engine.addStorage(5, .{ .role = .eis, .initial_item = .Water, .priority = .High });
            try engine.addStorage(2, .{ .role = .iis });
            try engine.addStorage(3, .{ .role = .ios });
            try engine.addStorage(4, .{ .role = .eos });

            try engine.addWorkstation(100, .{
                .eis = &.{ 1, 5 },
                .iis = &.{2},
                .ios = &.{3},
                .eos = &.{4},
            });

            // Should pick EIS id=5 (High priority) over id=1 (Low priority)
            const selected = engine.selectEis(100);
            try std.testing.expectEqual(@as(?u32, 5), selected);
        }

        pub fn @"selectEos picks highest priority EOS"() !void {
            const TestHooks = struct {};
            var engine = tasks.Engine(u32, Item, TestHooks).init(std.testing.allocator, .{}, null);
            defer engine.deinit();

            try engine.addStorage(1, .{ .role = .eis, .initial_item = .Flour });
            try engine.addStorage(2, .{ .role = .iis });
            try engine.addStorage(3, .{ .role = .ios });
            // Two empty EOS: id=4 Normal priority, id=6 Critical priority
            try engine.addStorage(4, .{ .role = .eos, .priority = .Normal });
            try engine.addStorage(6, .{ .role = .eos, .priority = .Critical });

            try engine.addWorkstation(100, .{
                .eis = &.{1},
                .iis = &.{2},
                .ios = &.{3},
                .eos = &.{ 4, 6 },
            });

            // Should pick EOS id=6 (Critical priority) over id=4 (Normal)
            const selected = engine.selectEos(100);
            try std.testing.expectEqual(@as(?u32, 6), selected);
        }

        pub fn @"higher priority workstation gets worker first"() !void {
            var assigned_ws: ?u32 = null;
            const TestHooks = struct {
                assigned_ws_ptr: *?u32,

                pub fn worker_assigned(self: *@This(), payload: anytype) void {
                    // Record first assignment only
                    if (self.assigned_ws_ptr.* == null) {
                        self.assigned_ws_ptr.* = payload.workstation_id;
                    }
                }
            };

            var engine = tasks.Engine(u32, Item, TestHooks).init(
                std.testing.allocator,
                .{ .assigned_ws_ptr = &assigned_ws },
                null,
            );
            defer engine.deinit();

            // Two workstations: ws=100 Low, ws=200 Critical
            try engine.addStorage(1, .{ .role = .eis, .initial_item = .Flour });
            try engine.addStorage(2, .{ .role = .iis });
            try engine.addStorage(3, .{ .role = .ios });
            try engine.addStorage(4, .{ .role = .eos });

            try engine.addStorage(11, .{ .role = .eis, .initial_item = .Water });
            try engine.addStorage(12, .{ .role = .iis });
            try engine.addStorage(13, .{ .role = .ios });
            try engine.addStorage(14, .{ .role = .eos });

            try engine.addWorkstation(100, .{
                .eis = &.{1},
                .iis = &.{2},
                .ios = &.{3},
                .eos = &.{4},
                .priority = .Low,
            });

            try engine.addWorkstation(200, .{
                .eis = &.{11},
                .iis = &.{12},
                .ios = &.{13},
                .eos = &.{14},
                .priority = .Critical,
            });

            // Only one worker - should go to Critical workstation (200)
            try engine.addWorker(10);
            _ = engine.workerAvailable(10);

            try std.testing.expectEqual(@as(?u32, 200), assigned_ws);
            try std.testing.expect(engine.getWorkstationStatus(200).? == .Active);
            try std.testing.expect(engine.getWorkstationStatus(100).? == .Queued);
        }
    });

    pub const introspection = zspec.describe("introspection API", struct {
        pub fn @"getStorageInfo returns full storage state"() !void {
            const TestHooks = struct {};
            var engine = tasks.Engine(u32, Item, TestHooks).init(std.testing.allocator, .{}, null);
            defer engine.deinit();

            try engine.addStorage(1, .{ .role = .eis, .initial_item = .Flour, .accepts = .Flour, .priority = .High });

            const info = engine.getStorageInfo(1).?;
            try std.testing.expectEqual(true, info.has_item);
            try std.testing.expectEqual(Item.Flour, info.item_type.?);
            try std.testing.expectEqual(tasks.StorageRole.eis, info.role);
            try std.testing.expectEqual(Item.Flour, info.accepts.?);
            try std.testing.expectEqual(tasks.Priority.High, info.priority);
        }

        pub fn @"getStorageInfo returns null for unknown storage"() !void {
            const TestHooks = struct {};
            var engine = tasks.Engine(u32, Item, TestHooks).init(std.testing.allocator, .{}, null);
            defer engine.deinit();

            try std.testing.expectEqual(null, engine.getStorageInfo(999));
        }

        pub fn @"getWorkerInfo returns full worker state"() !void {
            const TestHooks = struct {};
            var engine = tasks.Engine(u32, Item, TestHooks).init(std.testing.allocator, .{}, null);
            defer engine.deinit();

            try engine.addStorage(1, .{ .role = .eis, .initial_item = .Flour });
            try engine.addStorage(2, .{ .role = .iis });
            try engine.addStorage(3, .{ .role = .ios });
            try engine.addStorage(4, .{ .role = .eos });

            try engine.addWorkstation(100, .{
                .eis = &.{1},
                .iis = &.{2},
                .ios = &.{3},
                .eos = &.{4},
            });

            try engine.addWorker(10);

            // Before assignment
            const idle_info = engine.getWorkerInfo(10).?;
            try std.testing.expectEqual(tasks.WorkerState.Idle, idle_info.state);
            try std.testing.expectEqual(null, idle_info.assigned_workstation);
            try std.testing.expectEqual(false, idle_info.has_dangling_task);

            // After assignment
            _ = engine.workerAvailable(10);
            const working_info = engine.getWorkerInfo(10).?;
            try std.testing.expectEqual(tasks.WorkerState.Working, working_info.state);
            try std.testing.expectEqual(@as(u32, 100), working_info.assigned_workstation.?);
        }

        pub fn @"getWorkstationInfo returns full workstation state"() !void {
            const TestHooks = struct {};
            var engine = tasks.Engine(u32, Item, TestHooks).init(std.testing.allocator, .{}, null);
            defer engine.deinit();

            try engine.addStorage(1, .{ .role = .eis, .initial_item = .Flour });
            try engine.addStorage(2, .{ .role = .iis });
            try engine.addStorage(3, .{ .role = .ios });
            try engine.addStorage(4, .{ .role = .eos });

            try engine.addWorkstation(100, .{
                .eis = &.{1},
                .iis = &.{2},
                .ios = &.{3},
                .eos = &.{4},
                .priority = .Critical,
            });

            const info = engine.getWorkstationInfo(100).?;
            try std.testing.expectEqual(tasks.WorkstationStatus.Queued, info.status);
            try std.testing.expectEqual(null, info.assigned_worker);
            try std.testing.expectEqual(tasks.Priority.Critical, info.priority);
            try std.testing.expectEqual(@as(usize, 1), info.eis_count);
            try std.testing.expectEqual(@as(usize, 1), info.iis_count);
            try std.testing.expectEqual(@as(usize, 1), info.ios_count);
            try std.testing.expectEqual(@as(usize, 1), info.eos_count);
            try std.testing.expectEqual(@as(u32, 0), info.cycles_completed);
        }

        pub fn @"isStorageFull works correctly"() !void {
            const TestHooks = struct {};
            var engine = tasks.Engine(u32, Item, TestHooks).init(std.testing.allocator, .{}, null);
            defer engine.deinit();

            try engine.addStorage(1, .{ .role = .eis, .initial_item = .Flour });
            try engine.addStorage(2, .{ .role = .eis });

            try std.testing.expectEqual(true, engine.isStorageFull(1));
            try std.testing.expectEqual(false, engine.isStorageFull(2));
            try std.testing.expectEqual(false, engine.isStorageFull(999)); // unknown returns false
        }

        pub fn @"getWorkerAssignment tracks assignment correctly"() !void {
            const TestHooks = struct {};
            var engine = tasks.Engine(u32, Item, TestHooks).init(std.testing.allocator, .{}, null);
            defer engine.deinit();

            try engine.addStorage(1, .{ .role = .eis, .initial_item = .Flour });
            try engine.addStorage(2, .{ .role = .iis });
            try engine.addStorage(3, .{ .role = .ios });
            try engine.addStorage(4, .{ .role = .eos });

            try engine.addWorkstation(100, .{
                .eis = &.{1},
                .iis = &.{2},
                .ios = &.{3},
                .eos = &.{4},
            });

            try engine.addWorker(10);

            // Not assigned yet
            try std.testing.expectEqual(null, engine.getWorkerAssignment(10));

            _ = engine.workerAvailable(10);
            try std.testing.expectEqual(@as(u32, 100), engine.getWorkerAssignment(10).?);

            // Unknown worker
            try std.testing.expectEqual(null, engine.getWorkerAssignment(999));
        }

        pub fn @"getCounts returns correct entity counts"() !void {
            const TestHooks = struct {};
            var engine = tasks.Engine(u32, Item, TestHooks).init(std.testing.allocator, .{}, null);
            defer engine.deinit();

            var counts = engine.getCounts();
            try std.testing.expectEqual(@as(usize, 0), counts.storages);
            try std.testing.expectEqual(@as(usize, 0), counts.workers);

            try engine.addStorage(1, .{ .role = .eis, .initial_item = .Flour });
            try engine.addStorage(2, .{ .role = .iis });
            try engine.addStorage(3, .{ .role = .ios });
            try engine.addStorage(4, .{ .role = .eos });
            try engine.addWorkstation(100, .{
                .eis = &.{1},
                .iis = &.{2},
                .ios = &.{3},
                .eos = &.{4},
            });
            try engine.addWorker(10);
            try engine.addWorker(20);

            counts = engine.getCounts();
            try std.testing.expectEqual(@as(usize, 4), counts.storages);
            try std.testing.expectEqual(@as(usize, 2), counts.workers);
            try std.testing.expectEqual(@as(usize, 1), counts.workstations);
            try std.testing.expectEqual(@as(usize, 0), counts.dangling_items);
            try std.testing.expectEqual(@as(usize, 2), counts.idle_workers);
            try std.testing.expectEqual(@as(usize, 1), counts.queued_workstations);
        }

        pub fn @"dumpState writes diagnostic output"() !void {
            const TestHooks = struct {};
            var engine = tasks.Engine(u32, Item, TestHooks).init(std.testing.allocator, .{}, null);
            defer engine.deinit();

            try engine.addStorage(1, .{ .role = .eis, .initial_item = .Flour });
            try engine.addStorage(2, .{ .role = .iis });
            try engine.addStorage(3, .{ .role = .ios });
            try engine.addStorage(4, .{ .role = .eos });
            try engine.addWorkstation(100, .{
                .eis = &.{1},
                .iis = &.{2},
                .ios = &.{3},
                .eos = &.{4},
            });
            try engine.addWorker(10);

            var buf: [4096]u8 = undefined;
            var stream = std.io.fixedBufferStream(&buf);
            try engine.dumpState(stream.writer());

            const output = stream.getWritten();
            // Verify it contains key information
            try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "Task Engine State"));
            try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "Storages: 4"));
            try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "Workers: 1"));
            try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "Workstations: 1"));
        }

        pub fn @"getWorkerInfo detects dangling task"() !void {
            const TestHooks = struct {};
            var engine = tasks.Engine(u32, Item, TestHooks).init(std.testing.allocator, .{}, null);
            defer engine.deinit();

            try engine.addStorage(1, .{ .role = .eis, .accepts = .Flour });
            try engine.addWorker(10);
            _ = engine.workerAvailable(10);

            // Before dangling assignment
            try std.testing.expectEqual(false, engine.getWorkerInfo(10).?.has_dangling_task);

            // Add dangling item — worker gets assigned
            try engine.addDanglingItem(50, .Flour);
            try std.testing.expectEqual(true, engine.getWorkerInfo(10).?.has_dangling_task);
        }

        pub fn @"workstation info updates after cycle"() !void {
            const TestHooks = struct {};
            var engine = tasks.Engine(u32, Item, TestHooks).init(std.testing.allocator, .{}, null);
            defer engine.deinit();

            try engine.addStorage(1, .{ .role = .eis, .initial_item = .Flour });
            try engine.addStorage(2, .{ .role = .iis });
            try engine.addStorage(3, .{ .role = .ios });
            try engine.addStorage(4, .{ .role = .eos });

            try engine.addWorkstation(100, .{
                .eis = &.{1},
                .iis = &.{2},
                .ios = &.{3},
                .eos = &.{4},
            });

            try engine.addWorker(10);
            _ = engine.workerAvailable(10);

            try std.testing.expectEqual(tasks.WorkstationStatus.Active, engine.getWorkstationInfo(100).?.status);
            try std.testing.expectEqual(@as(u32, 10), engine.getWorkstationInfo(100).?.assigned_worker.?);

            // Complete full cycle
            _ = engine.pickupCompleted(10);
            _ = engine.workCompleted(100);
            _ = engine.storeCompleted(10);

            try std.testing.expectEqual(@as(u32, 1), engine.getWorkstationInfo(100).?.cycles_completed);
        }
    });

    pub const standalone_storages = zspec.describe("standalone storages", struct {
        pub fn @"registers standalone storage"() !void {
            const Recorder = tasks.RecordingHooks(u32, Item);
            var hooks: Recorder = .{};
            hooks.init(std.testing.allocator);
            var engine = tasks.Engine(u32, Item, Recorder).init(std.testing.allocator, hooks, null);
            defer engine.deinit();
            defer engine.dispatcher.hooks.deinit();

            try engine.addStorage(1, .{ .role = .standalone, .accepts = .Bread });

            try std.testing.expect(engine.isStandalone(1));
            try std.testing.expectEqual(false, engine.getStorageHasItem(1).?);
        }

        pub fn @"item_added on standalone dispatches standalone_item_added"() !void {
            const Recorder = tasks.RecordingHooks(u32, Item);
            var hooks: Recorder = .{};
            hooks.init(std.testing.allocator);
            var engine = tasks.Engine(u32, Item, Recorder).init(std.testing.allocator, hooks, null);
            defer engine.deinit();
            defer engine.dispatcher.hooks.deinit();

            try engine.addStorage(1, .{ .role = .standalone, .accepts = .Bread });
            _ = engine.itemAdded(1, .Bread);

            const evt = try engine.dispatcher.hooks.expectNext(.standalone_item_added);
            try std.testing.expectEqual(@as(u32, 1), evt.storage_id);
            try std.testing.expectEqual(Item.Bread, evt.item);
        }

        pub fn @"item_removed on standalone dispatches standalone_item_removed"() !void {
            const Recorder = tasks.RecordingHooks(u32, Item);
            var hooks: Recorder = .{};
            hooks.init(std.testing.allocator);
            var engine = tasks.Engine(u32, Item, Recorder).init(std.testing.allocator, hooks, null);
            defer engine.deinit();
            defer engine.dispatcher.hooks.deinit();

            try engine.addStorage(1, .{ .role = .standalone, .accepts = .Bread, .initial_item = .Bread });
            _ = engine.itemRemoved(1);

            const evt = try engine.dispatcher.hooks.expectNext(.standalone_item_removed);
            try std.testing.expectEqual(@as(u32, 1), evt.storage_id);
        }

        pub fn @"dangling item prefers EIS over standalone"() !void {
            const Recorder = tasks.RecordingHooks(u32, Item);
            var hooks: Recorder = .{};
            hooks.init(std.testing.allocator);
            var engine = tasks.Engine(u32, Item, Recorder).init(std.testing.allocator, hooks, null);
            defer engine.deinit();
            defer engine.dispatcher.hooks.deinit();

            // Register both EIS and standalone that accept Flour
            try engine.addStorage(10, .{ .role = .eis, .accepts = .Flour });
            try engine.addStorage(20, .{ .role = .standalone, .accepts = .Flour });
            try engine.addWorker(1);
            _ = engine.workerAvailable(1);

            // Add dangling item — should go to EIS (10), not standalone (20)
            try engine.addDanglingItem(100, .Flour);

            const evt = try engine.dispatcher.hooks.expectNext(.pickup_dangling_started);
            try std.testing.expectEqual(@as(u32, 10), evt.target_storage_id);
        }

        pub fn @"dangling item falls back to standalone when no EIS"() !void {
            const Recorder = tasks.RecordingHooks(u32, Item);
            var hooks: Recorder = .{};
            hooks.init(std.testing.allocator);
            var engine = tasks.Engine(u32, Item, Recorder).init(std.testing.allocator, hooks, null);
            defer engine.deinit();
            defer engine.dispatcher.hooks.deinit();

            // Only standalone storage, no EIS
            try engine.addStorage(20, .{ .role = .standalone, .accepts = .Flour });
            try engine.addWorker(1);
            _ = engine.workerAvailable(1);

            // Add dangling item — should go to standalone (20)
            try engine.addDanglingItem(100, .Flour);

            const evt = try engine.dispatcher.hooks.expectNext(.pickup_dangling_started);
            try std.testing.expectEqual(@as(u32, 20), evt.target_storage_id);
        }

        pub fn @"standalone in workstation EIS list enables workstation"() !void {
            const Recorder = tasks.RecordingHooks(u32, Item);
            var hooks: Recorder = .{};
            hooks.init(std.testing.allocator);
            var engine = tasks.Engine(u32, Item, Recorder).init(std.testing.allocator, hooks, null);
            defer engine.deinit();
            defer engine.dispatcher.hooks.deinit();

            // Standalone storage as workstation input
            try engine.addStorage(10, .{ .role = .standalone, .accepts = .Flour });
            try engine.addStorage(20, .{ .role = .iis });
            try engine.addStorage(30, .{ .role = .ios });
            try engine.addStorage(40, .{ .role = .eos });

            try engine.addWorkstation(100, .{
                .eis = &.{10},
                .iis = &.{20},
                .ios = &.{30},
                .eos = &.{40},
            });

            // Workstation should be Blocked (no item in standalone)
            try std.testing.expectEqual(tasks.WorkstationStatus.Blocked, engine.getWorkstationStatus(100).?);

            // Add item to standalone — workstation should become Queued
            _ = engine.itemAdded(10, .Flour);
            try std.testing.expectEqual(tasks.WorkstationStatus.Queued, engine.getWorkstationStatus(100).?);
        }
    });

    pub const eos_transport = zspec.describe("EOS transport", struct {
        pub fn @"EOS item triggers transport to empty EIS"() !void {
            const Recorder = tasks.RecordingHooks(u32, Item);
            var hooks: Recorder = .{};
            hooks.init(std.testing.allocator);
            var engine = tasks.Engine(u32, Item, Recorder).init(std.testing.allocator, hooks, null);
            defer engine.deinit();
            defer engine.dispatcher.hooks.deinit();

            // Setup: EOS with Bread, empty EIS that accepts Bread, idle worker
            try engine.addStorage(1, .{ .role = .eos, .initial_item = .Bread });
            try engine.addStorage(2, .{ .role = .eis, .accepts = .Bread });
            try engine.addWorker(10);

            // Worker becomes available — should trigger transport
            _ = engine.workerAvailable(10);

            // Should see transport_started
            const evt = try engine.dispatcher.hooks.expectNext(.transport_started);
            try std.testing.expectEqual(@as(u32, 10), evt.worker_id);
            try std.testing.expectEqual(@as(u32, 1), evt.from_storage_id);
            try std.testing.expectEqual(@as(u32, 2), evt.to_storage_id);
            try std.testing.expectEqual(Item.Bread, evt.item);

            // Worker should be Working
            try std.testing.expectEqual(tasks.WorkerState.Working, engine.getWorkerState(10).?);

            // Destination should be reserved
            try std.testing.expect(engine.isStorageReserved(2));
        }

        pub fn @"full transport cycle"() !void {
            const Recorder = tasks.RecordingHooks(u32, Item);
            var hooks: Recorder = .{};
            hooks.init(std.testing.allocator);
            var engine = tasks.Engine(u32, Item, Recorder).init(std.testing.allocator, hooks, null);
            defer engine.deinit();
            defer engine.dispatcher.hooks.deinit();

            try engine.addStorage(1, .{ .role = .eos, .initial_item = .Bread });
            try engine.addStorage(2, .{ .role = .eis, .accepts = .Bread });
            try engine.addWorker(10);
            _ = engine.workerAvailable(10);

            // transport_started already dispatched
            _ = try engine.dispatcher.hooks.expectNext(.transport_started);

            // Pickup completed — EOS should be cleared
            _ = engine.transportPickupCompleted(10);
            try std.testing.expectEqual(false, engine.getStorageHasItem(1).?);

            // Delivery completed — destination should have item
            _ = engine.transportDeliveryCompleted(10);
            try std.testing.expectEqual(true, engine.getStorageHasItem(2).?);
            try std.testing.expectEqual(Item.Bread, engine.getStorageItemType(2).?);

            // Worker should be idle
            try std.testing.expectEqual(tasks.WorkerState.Idle, engine.getWorkerState(10).?);

            // Reservation should be released
            try std.testing.expect(!engine.isStorageReserved(2));

            // transport_completed hook should have fired
            const evt = try engine.dispatcher.hooks.expectNext(.transport_completed);
            try std.testing.expectEqual(@as(u32, 10), evt.worker_id);
            try std.testing.expectEqual(@as(u32, 2), evt.to_storage_id);
        }

        pub fn @"transport prefers EIS over standalone"() !void {
            const Recorder = tasks.RecordingHooks(u32, Item);
            var hooks: Recorder = .{};
            hooks.init(std.testing.allocator);
            var engine = tasks.Engine(u32, Item, Recorder).init(std.testing.allocator, hooks, null);
            defer engine.deinit();
            defer engine.dispatcher.hooks.deinit();

            try engine.addStorage(1, .{ .role = .eos, .initial_item = .Bread });
            try engine.addStorage(2, .{ .role = .eis, .accepts = .Bread });
            try engine.addStorage(3, .{ .role = .standalone, .accepts = .Bread });
            try engine.addWorker(10);
            _ = engine.workerAvailable(10);

            // Should target EIS (2), not standalone (3)
            const evt = try engine.dispatcher.hooks.expectNext(.transport_started);
            try std.testing.expectEqual(@as(u32, 2), evt.to_storage_id);
        }

        pub fn @"transport falls back to standalone when no EIS"() !void {
            const Recorder = tasks.RecordingHooks(u32, Item);
            var hooks: Recorder = .{};
            hooks.init(std.testing.allocator);
            var engine = tasks.Engine(u32, Item, Recorder).init(std.testing.allocator, hooks, null);
            defer engine.deinit();
            defer engine.dispatcher.hooks.deinit();

            try engine.addStorage(1, .{ .role = .eos, .initial_item = .Bread });
            try engine.addStorage(3, .{ .role = .standalone, .accepts = .Bread });
            try engine.addWorker(10);
            _ = engine.workerAvailable(10);

            // Should target standalone (3)
            const evt = try engine.dispatcher.hooks.expectNext(.transport_started);
            try std.testing.expectEqual(@as(u32, 3), evt.to_storage_id);
        }

        pub fn @"reservation prevents double assignment"() !void {
            const Recorder = tasks.RecordingHooks(u32, Item);
            var hooks: Recorder = .{};
            hooks.init(std.testing.allocator);
            var engine = tasks.Engine(u32, Item, Recorder).init(std.testing.allocator, hooks, null);
            defer engine.deinit();
            defer engine.dispatcher.hooks.deinit();

            // Two EOS with items, only one EIS
            try engine.addStorage(1, .{ .role = .eos, .initial_item = .Bread });
            try engine.addStorage(2, .{ .role = .eos, .initial_item = .Bread });
            try engine.addStorage(3, .{ .role = .eis, .accepts = .Bread });
            try engine.addWorker(10);
            try engine.addWorker(11);
            _ = engine.workerAvailable(10);
            _ = engine.workerAvailable(11);

            // Only one transport should be assigned (EIS 3 is reserved after first)
            var transport_count: usize = 0;
            for (engine.dispatcher.hooks.events.items) |event| {
                if (event == .transport_started) transport_count += 1;
            }
            try std.testing.expectEqual(@as(usize, 1), transport_count);
        }

        pub fn @"transport cancelled on worker unavailable"() !void {
            const Recorder = tasks.RecordingHooks(u32, Item);
            var hooks: Recorder = .{};
            hooks.init(std.testing.allocator);
            var engine = tasks.Engine(u32, Item, Recorder).init(std.testing.allocator, hooks, null);
            defer engine.deinit();
            defer engine.dispatcher.hooks.deinit();

            try engine.addStorage(1, .{ .role = .eos, .initial_item = .Bread });
            try engine.addStorage(2, .{ .role = .eis, .accepts = .Bread });
            try engine.addWorker(10);
            _ = engine.workerAvailable(10);

            // Transport started
            _ = try engine.dispatcher.hooks.expectNext(.transport_started);

            // Worker becomes unavailable
            _ = engine.handle(.{ .worker_unavailable = .{ .worker_id = 10 } });

            // transport_cancelled should fire
            const evt = try engine.dispatcher.hooks.expectNext(.transport_cancelled);
            try std.testing.expectEqual(@as(u32, 10), evt.worker_id);

            // Reservation should be released
            try std.testing.expect(!engine.isStorageReserved(2));
        }

        pub fn @"no transport when no destination available"() !void {
            const Recorder = tasks.RecordingHooks(u32, Item);
            var hooks: Recorder = .{};
            hooks.init(std.testing.allocator);
            var engine = tasks.Engine(u32, Item, Recorder).init(std.testing.allocator, hooks, null);
            defer engine.deinit();
            defer engine.dispatcher.hooks.deinit();

            // EOS with Bread but no matching destination
            try engine.addStorage(1, .{ .role = .eos, .initial_item = .Bread });
            try engine.addStorage(2, .{ .role = .eis, .accepts = .Water }); // Wrong type
            try engine.addWorker(10);
            _ = engine.workerAvailable(10);

            // Worker should stay idle — no transport
            try std.testing.expectEqual(tasks.WorkerState.Idle, engine.getWorkerState(10).?);

            // No transport_started events
            var transport_count: usize = 0;
            for (engine.dispatcher.hooks.events.items) |event| {
                if (event == .transport_started) transport_count += 1;
            }
            try std.testing.expectEqual(@as(usize, 0), transport_count);
        }

        pub fn @"transport triggered after workstation store_completed"() !void {
            const Recorder = tasks.RecordingHooks(u32, Item);
            var hooks: Recorder = .{};
            hooks.init(std.testing.allocator);
            var engine = tasks.Engine(u32, Item, Recorder).init(std.testing.allocator, hooks, null);
            defer engine.deinit();
            defer engine.dispatcher.hooks.deinit();

            // Workstation setup: EIS(Flour filled) → IIS → IOS → EOS
            try engine.addStorage(1, .{ .role = .eis, .initial_item = .Flour });
            try engine.addStorage(2, .{ .role = .iis });
            try engine.addStorage(3, .{ .role = .ios });
            try engine.addStorage(4, .{ .role = .eos });

            // Second EIS to receive the transported Bread
            try engine.addStorage(5, .{ .role = .eis, .accepts = .Bread });

            try engine.addWorkstation(100, .{
                .eis = &.{1},
                .iis = &.{2},
                .ios = &.{3},
                .eos = &.{4},
            });

            try engine.addWorker(10);
            _ = engine.workerAvailable(10);

            // Complete workstation cycle
            _ = engine.pickupCompleted(10);
            // Set IOS item type (game does this via process_completed hook)
            _ = engine.itemAdded(3, .Bread);
            _ = engine.workCompleted(100);
            _ = engine.storeCompleted(10);

            // After store_completed, worker is released and EOS has Bread
            // Worker should be assigned transport to move Bread from EOS(4) to EIS(5)
            var transport_count: usize = 0;
            for (engine.dispatcher.hooks.events.items) |event| {
                if (event == .transport_started) transport_count += 1;
            }
            try std.testing.expectEqual(@as(usize, 1), transport_count);
        }

        pub fn @"transport re-routes when destination is full on delivery"() !void {
            const Recorder = tasks.RecordingHooks(u32, Item);
            var hooks: Recorder = .{};
            hooks.init(std.testing.allocator);
            var engine = tasks.Engine(u32, Item, Recorder).init(std.testing.allocator, hooks, null);
            defer engine.deinit();
            defer engine.dispatcher.hooks.deinit();

            // EOS with Bread, two possible destinations
            try engine.addStorage(1, .{ .role = .eos, .initial_item = .Bread });
            try engine.addStorage(2, .{ .role = .eis, .accepts = .Bread }); // destination 1
            try engine.addStorage(3, .{ .role = .eis, .accepts = .Bread }); // destination 2

            try engine.addWorker(10);
            _ = engine.workerAvailable(10);

            // Worker should be assigned transport
            try std.testing.expectEqual(tasks.WorkerState.Working, engine.getWorkerState(10).?);

            // Complete pickup — clears EOS
            _ = engine.transportPickupCompleted(10);
            try std.testing.expect(!engine.isStorageFull(1));

            // Simulate destination becoming full before delivery (race condition)
            // Find which destination was chosen and fill it
            const w_data = engine.workers.get(10).?;
            const dest = w_data.transport_task.?.to_storage_id;
            if (engine.storages.getPtr(dest)) |s| {
                s.has_item = true;
                s.item_type = .Bread;
            }

            // Deliver — should re-route to the other destination
            _ = engine.transportDeliveryCompleted(10);

            // Worker should still be working (re-routed, not cancelled)
            try std.testing.expectEqual(tasks.WorkerState.Working, engine.getWorkerState(10).?);

            // Should have a new transport_started event for the re-route
            var transport_started_count: usize = 0;
            for (engine.dispatcher.hooks.events.items) |event| {
                if (event == .transport_started) transport_started_count += 1;
            }
            // Two transport_started events: original + re-route
            try std.testing.expectEqual(@as(usize, 2), transport_started_count);

            // The new transport_task should point to the other destination
            const new_task = engine.workers.get(10).?.transport_task.?;
            const other_dest: u32 = if (dest == 2) 3 else 2;
            try std.testing.expectEqual(other_dest, new_task.to_storage_id);
            // from_storage_id should be the full destination (worker's current position)
            try std.testing.expectEqual(dest, new_task.from_storage_id);
        }

        pub fn @"transport cancelled when destination full and no re-route available"() !void {
            const Recorder = tasks.RecordingHooks(u32, Item);
            var hooks: Recorder = .{};
            hooks.init(std.testing.allocator);
            var engine = tasks.Engine(u32, Item, Recorder).init(std.testing.allocator, hooks, null);
            defer engine.deinit();
            defer engine.dispatcher.hooks.deinit();

            // EOS with Bread, only one destination
            try engine.addStorage(1, .{ .role = .eos, .initial_item = .Bread });
            try engine.addStorage(2, .{ .role = .eis, .accepts = .Bread });

            try engine.addWorker(10);
            _ = engine.workerAvailable(10);

            // Complete pickup
            _ = engine.transportPickupCompleted(10);

            // Fill the destination before delivery
            if (engine.storages.getPtr(2)) |s| {
                s.has_item = true;
                s.item_type = .Bread;
            }

            // Deliver — no re-route available, should cancel
            _ = engine.transportDeliveryCompleted(10);

            // Worker should be idle (transport cancelled)
            try std.testing.expectEqual(tasks.WorkerState.Idle, engine.getWorkerState(10).?);

            // transport_cancelled should fire
            var cancelled_count: usize = 0;
            for (engine.dispatcher.hooks.events.items) |event| {
                if (event == .transport_cancelled) cancelled_count += 1;
            }
            try std.testing.expectEqual(@as(usize, 1), cancelled_count);

            // Reservation should be released
            try std.testing.expect(!engine.isStorageReserved(2));
        }
    });
});
