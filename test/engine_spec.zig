//! Engine spec - tests for the pure state machine task engine
const std = @import("std");
const zspec = @import("zspec");
const tasks = @import("labelle_tasks");

const Item = enum { Flour, Water, Dough, Bread };

pub const Engine = zspec.describe("Engine", struct {
    pub const initialization = zspec.describe("initialization", struct {
        pub fn @"creates empty engine"() !void {
            const TestHooks = struct {};
            var engine = tasks.Engine(u32, Item, TestHooks).init(std.testing.allocator, .{});
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
            var engine = tasks.Engine(u32, Item, TestHooks).init(std.testing.allocator, .{});
            defer engine.deinit();

            try engine.addStorage(1, .Flour);

            try std.testing.expect(engine.getStorageHasItem(1).? == true);
            try std.testing.expect(engine.getStorageItemType(1).? == .Flour);
        }

        pub fn @"adds empty storage"() !void {
            const TestHooks = struct {};
            var engine = tasks.Engine(u32, Item, TestHooks).init(std.testing.allocator, .{});
            defer engine.deinit();

            try engine.addStorage(1, null);

            try std.testing.expect(engine.getStorageHasItem(1).? == false);
            try std.testing.expect(engine.getStorageItemType(1) == null);
        }

        pub fn @"updates storage on item_added"() !void {
            const TestHooks = struct {};
            var engine = tasks.Engine(u32, Item, TestHooks).init(std.testing.allocator, .{});
            defer engine.deinit();

            try engine.addStorage(1, null);
            _ = engine.itemAdded(1, .Water);

            try std.testing.expect(engine.getStorageHasItem(1).? == true);
            try std.testing.expect(engine.getStorageItemType(1).? == .Water);
        }
    });

    pub const worker = zspec.describe("worker", struct {
        pub fn @"adds worker in idle state"() !void {
            const TestHooks = struct {};
            var engine = tasks.Engine(u32, Item, TestHooks).init(std.testing.allocator, .{});
            defer engine.deinit();

            try engine.addWorker(10);

            try std.testing.expect(engine.getWorkerState(10).? == .Idle);
        }
    });

    pub const workstation = zspec.describe("workstation", struct {
        pub fn @"adds workstation with storages"() !void {
            const TestHooks = struct {};
            var engine = tasks.Engine(u32, Item, TestHooks).init(std.testing.allocator, .{});
            defer engine.deinit();

            try engine.addStorage(1, .Flour);
            try engine.addStorage(2, null);
            try engine.addStorage(3, null);
            try engine.addStorage(4, null);

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
            var engine = tasks.Engine(u32, Item, TestHooks).init(std.testing.allocator, .{});
            defer engine.deinit();

            try engine.addStorage(1, null); // EIS empty
            try engine.addStorage(2, null);
            try engine.addStorage(3, null);
            try engine.addStorage(4, null);

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
            );
            defer engine.deinit();

            try engine.addStorage(1, .Flour);
            try engine.addStorage(2, null);
            try engine.addStorage(3, null);
            try engine.addStorage(4, null);

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
});
