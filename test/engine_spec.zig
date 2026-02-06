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
    });

    pub const dangling_items = zspec.describe("dangling_items", struct {
        pub fn @"evaluateDanglingItems propagates allocation errors"() !void {
            const TestHooks = struct {};

            // Use a failing allocator that fails after a set number of allocations
            var failing_alloc = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 100 });

            var engine = tasks.Engine(u32, Item, TestHooks).init(failing_alloc.allocator(), .{}, null);
            defer engine.deinit();

            // Set up: register a worker and a dangling item with an empty EIS
            try engine.addStorage(1, .{ .role = .eis }); // empty EIS
            try engine.addWorker(10);
            _ = engine.workerAvailable(10);

            // Now make the allocator fail on the next allocation
            // (getIdleWorkers will try to allocate an ArrayList)
            failing_alloc.fail_index = 0;

            // evaluateDanglingItems should propagate the error, not silently swallow it
            try std.testing.expectError(error.OutOfMemory, engine.evaluateDanglingItems());
        }

        pub fn @"addDanglingItem propagates evaluateDanglingItems errors"() !void {
            const TestHooks = struct {};
            var failing_alloc = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 100 });

            var engine = tasks.Engine(u32, Item, TestHooks).init(failing_alloc.allocator(), .{}, null);
            defer engine.deinit();

            try engine.addStorage(1, .{ .role = .eis }); // empty EIS
            try engine.addWorker(10);
            _ = engine.workerAvailable(10);

            // Make allocator fail on getIdleWorkers inside evaluateDanglingItems
            failing_alloc.fail_index = 0;

            // addDanglingItem should propagate the error from evaluateDanglingItems
            try std.testing.expectError(error.OutOfMemory, engine.addDanglingItem(99, .Flour));
        }
    });

});
