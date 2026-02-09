//! Hooks spec - tests for hook payloads and dispatcher
const std = @import("std");
const zspec = @import("zspec");
const tasks = @import("labelle_tasks");

const Item = enum { Flour, Bread };

pub const Hooks = zspec.describe("Hooks", struct {
    pub const TaskHookPayload = zspec.describe("TaskHookPayload", struct {
        pub fn @"creates pickup_started payload"() !void {
            const Payload = tasks.TaskHookPayload(u32, Item);
            const payload = Payload{ .pickup_started = .{
                .worker_id = 1,
                .storage_id = 2,
                .item = .Flour,
            } };
            try std.testing.expectEqual(@as(u32, 1), payload.pickup_started.worker_id);
            try std.testing.expectEqual(@as(u32, 2), payload.pickup_started.storage_id);
            try std.testing.expectEqual(Item.Flour, payload.pickup_started.item);
        }
    });

    pub const GameHookPayload = zspec.describe("GameHookPayload", struct {
        pub fn @"creates item_added payload"() !void {
            const Payload = tasks.GameHookPayload(u32, Item);
            const payload = Payload{ .item_added = .{
                .storage_id = 1,
                .item = .Flour,
            } };
            try std.testing.expectEqual(@as(u32, 1), payload.item_added.storage_id);
            try std.testing.expectEqual(Item.Flour, payload.item_added.item);
        }
    });

    pub const HookDispatcher = zspec.describe("HookDispatcher", struct {
        pub fn @"calls hook method when defined"() !void {
            var called = false;

            const TestHooks = struct {
                called_ptr: *bool,

                pub fn pickup_started(self: *@This(), payload: anytype) void {
                    _ = payload;
                    self.called_ptr.* = true;
                }
            };

            const hooks = TestHooks{ .called_ptr = &called };
            var dispatcher = tasks.HookDispatcher(u32, Item, TestHooks).init(hooks);

            dispatcher.dispatch(.{ .pickup_started = .{
                .worker_id = 1,
                .storage_id = 2,
                .item = .Flour,
            } });

            try std.testing.expect(called);
        }

        pub fn @"ignores missing hooks"() !void {
            const EmptyHooks = struct {};

            const hooks = EmptyHooks{};
            var dispatcher = tasks.HookDispatcher(u32, Item, EmptyHooks).init(hooks);

            // Should not crash - just ignores missing hook
            dispatcher.dispatch(.{ .pickup_started = .{
                .worker_id = 1,
                .storage_id = 2,
                .item = .Flour,
            } });

            // If we get here without crashing, the test passes
            try std.testing.expect(true);
        }
    });

    pub const RecordingHooksSpec = zspec.describe("RecordingHooks", struct {
        pub fn @"records dispatched events"() !void {
            const Recorder = tasks.RecordingHooks(u32, Item);
            var hooks: Recorder = .{};
            hooks.init(std.testing.allocator);
            defer hooks.deinit();

            var engine = tasks.Engine(u32, Item, Recorder).init(
                std.testing.allocator,
                hooks,
                null,
            );
            defer engine.deinit();

            // Set up a simple workflow
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

            // Clear events from setup
            engine.dispatcher.hooks.clear();

            // Trigger worker_available which should assign worker
            _ = engine.workerAvailable(10);

            // Should have recorded worker_assigned, workstation_activated, pickup_started
            const assigned = try engine.dispatcher.hooks.expectNext(.worker_assigned);
            try std.testing.expectEqual(@as(u32, 10), assigned.worker_id);
            try std.testing.expectEqual(@as(u32, 100), assigned.workstation_id);

            _ = try engine.dispatcher.hooks.expectNext(.workstation_activated);
            _ = try engine.dispatcher.hooks.expectNext(.pickup_started);
        }

        pub fn @"expectEmpty succeeds when no events"() !void {
            const Recorder = tasks.RecordingHooks(u32, Item);
            var hooks: Recorder = .{};
            hooks.init(std.testing.allocator);
            defer hooks.deinit();

            try hooks.expectEmpty();
        }
    });
});
