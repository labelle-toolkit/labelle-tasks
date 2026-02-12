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
});
