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
});
