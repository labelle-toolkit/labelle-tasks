//! labelle-tasks Hook System
//!
//! A type-safe, comptime-based hook/event system for labelle-tasks.
//! Compatible with labelle-engine's hook system.
//!
//! ## Overview
//!
//! The hook system allows games to observe task engine lifecycle events
//! (pickup started, process completed, worker assigned, etc.) with zero runtime overhead.
//!
//! ## Usage
//!
//! Define a hook handler struct with functions matching hook names:
//!
//! ```zig
//! const MyTaskHooks = struct {
//!     pub fn pickup_started(payload: tasks.hooks.HookPayload(u32, Item)) void {
//!         const info = payload.pickup_started;
//!         std.log.info("Worker {d} picking up from EIS {d}", .{
//!             info.worker_id, info.eis_id,
//!         });
//!     }
//!
//!     pub fn cycle_completed(payload: tasks.hooks.HookPayload(u32, Item)) void {
//!         const info = payload.cycle_completed;
//!         std.log.info("Cycle {d} completed!", .{info.cycles_completed});
//!     }
//! };
//!
//! // Create a dispatcher
//! const Dispatcher = tasks.hooks.HookDispatcher(u32, Item, MyTaskHooks);
//!
//! // Create engine with dispatcher
//! var engine = tasks.EngineWithHooks(u32, Item, Dispatcher).init(allocator);
//! ```
//!
//! ## Integration with labelle-engine
//!
//! The hook system integrates with labelle-engine's hook patterns:
//!
//! ```zig
//! const engine = @import("labelle-engine");
//! const tasks = @import("labelle-tasks");
//!
//! // Plugin that listens to engine hooks and uses task engine
//! const TasksPlugin = struct {
//!     pub const EngineHooks = struct {
//!         pub fn game_init(_: engine.HookPayload) void {
//!             // Initialize task engine
//!         }
//!
//!         pub fn frame_start(payload: engine.HookPayload) void {
//!             // Call task_engine.update(payload.frame_start.dt)
//!         }
//!     };
//! };
//!
//! // Merge with game hooks
//! const AllHooks = engine.MergeEngineHooks(.{ GameHooks, TasksPlugin.EngineHooks });
//! const Game = engine.GameWith(AllHooks);
//! ```

const std = @import("std");
const root = @import("root.zig");

pub const Priority = root.Components.Priority;
pub const StepType = root.Components.StepType;

/// Built-in hooks for task engine lifecycle events.
/// Games can register handlers for any of these hooks.
pub const TasksHook = enum {
    // Step lifecycle
    pickup_started,
    process_started,
    process_completed,
    store_started,

    // Worker lifecycle
    worker_assigned,
    worker_released,

    // Workstation lifecycle
    workstation_blocked,
    workstation_queued,
    workstation_activated,

    // Transport lifecycle
    transport_started,
    transport_completed,

    // Cycle lifecycle
    cycle_completed,
};

/// Pickup step information.
pub fn PickupInfo(comptime GameId: type) type {
    return struct {
        worker_id: GameId,
        workstation_id: GameId,
        eis_id: GameId,
    };
}

/// Process step information.
pub fn ProcessInfo(comptime GameId: type) type {
    return struct {
        worker_id: GameId,
        workstation_id: GameId,
    };
}

/// Store step information.
pub fn StoreInfo(comptime GameId: type) type {
    return struct {
        worker_id: GameId,
        workstation_id: GameId,
        eos_id: GameId,
    };
}

/// Worker assignment information.
pub fn WorkerAssignmentInfo(comptime GameId: type) type {
    return struct {
        worker_id: GameId,
        workstation_id: ?GameId, // null for transport assignments
    };
}

/// Worker release information.
pub fn WorkerReleaseInfo(comptime GameId: type) type {
    return struct {
        worker_id: GameId,
        workstation_id: GameId,
    };
}

/// Workstation status change information.
pub fn WorkstationStatusInfo(comptime GameId: type) type {
    return struct {
        workstation_id: GameId,
        priority: Priority,
    };
}

/// Transport information.
pub fn TransportInfo(comptime GameId: type, comptime Item: type) type {
    return struct {
        worker_id: GameId,
        from_storage_id: GameId,
        to_storage_id: GameId,
        item: Item,
    };
}

/// Cycle completion information.
pub fn CycleInfo(comptime GameId: type) type {
    return struct {
        workstation_id: GameId,
        worker_id: GameId,
        cycles_completed: u32,
    };
}

/// Type-safe payload union for task hooks.
/// Each hook type has its corresponding payload type.
/// Parameterized by game's entity ID type and Item type.
pub fn HookPayload(comptime GameId: type, comptime Item: type) type {
    return union(TasksHook) {
        pickup_started: PickupInfo(GameId),
        process_started: ProcessInfo(GameId),
        process_completed: ProcessInfo(GameId),
        store_started: StoreInfo(GameId),

        worker_assigned: WorkerAssignmentInfo(GameId),
        worker_released: WorkerReleaseInfo(GameId),

        workstation_blocked: WorkstationStatusInfo(GameId),
        workstation_queued: WorkstationStatusInfo(GameId),
        workstation_activated: WorkstationStatusInfo(GameId),

        transport_started: TransportInfo(GameId, Item),
        transport_completed: TransportInfo(GameId, Item),

        cycle_completed: CycleInfo(GameId),
    };
}

/// Creates a hook dispatcher from a comptime hook map.
///
/// The HookMap should be a struct type where each public declaration is a
/// function matching the signature for that hook (e.g., `pickup_started`, `cycle_completed`).
///
/// Example:
/// ```zig
/// const MyHooks = struct {
///     pub fn pickup_started(payload: tasks.hooks.HookPayload(u32, Item)) void {
///         const info = payload.pickup_started;
///         std.log.info("Pickup started!", .{});
///     }
/// };
///
/// const Dispatcher = tasks.hooks.HookDispatcher(u32, Item, MyHooks);
/// Dispatcher.emit(.{ .pickup_started = .{ ... } });
/// ```
pub fn HookDispatcher(
    comptime GameId: type,
    comptime Item: type,
    comptime HookMap: type,
) type {
    const PayloadType = HookPayload(GameId, Item);

    return struct {
        const Self = @This();

        /// The hook enum type this dispatcher handles.
        pub const Hook = TasksHook;

        /// The payload union type this dispatcher handles.
        pub const Payload = PayloadType;

        /// The hook handler map type.
        pub const Handlers = HookMap;

        /// Emit a hook event. Resolved entirely at comptime - no runtime overhead.
        ///
        /// If no handler is registered for the hook, this is a no-op.
        pub inline fn emit(payload: PayloadType) void {
            switch (payload) {
                inline else => |_, tag| {
                    const hook_name = @tagName(tag);
                    if (@hasDecl(HookMap, hook_name)) {
                        const handler = @field(HookMap, hook_name);
                        handler(payload);
                    }
                },
            }
        }

        /// Check at comptime if a hook has a handler registered.
        pub fn hasHandler(comptime hook: TasksHook) bool {
            return @hasDecl(HookMap, @tagName(hook));
        }

        /// Get the number of hooks that have handlers registered.
        pub fn handlerCount() comptime_int {
            var count: comptime_int = 0;
            for (std.enums.values(TasksHook)) |hook| {
                if (@hasDecl(HookMap, @tagName(hook))) {
                    count += 1;
                }
            }
            return count;
        }
    };
}

/// An empty hook dispatcher with no handlers.
/// Useful as a default when no hooks are needed.
pub fn EmptyDispatcher(comptime GameId: type, comptime Item: type) type {
    return HookDispatcher(GameId, Item, struct {});
}

/// Convenience type for creating a task hook dispatcher.
/// Equivalent to `HookDispatcher(GameId, Item, HookMap)`.
pub fn TasksHookDispatcher(comptime GameId: type, comptime Item: type, comptime HookMap: type) type {
    return HookDispatcher(GameId, Item, HookMap);
}

/// Merges multiple hook handler structs into one composite dispatcher.
/// When a hook is emitted, all matching handlers from all structs are called in order.
///
/// Example:
/// ```zig
/// const GameTaskHooks = struct {
///     pub fn cycle_completed(payload: tasks.hooks.HookPayload(u32, Item)) void {
///         std.log.info("Game: cycle completed!", .{});
///     }
/// };
///
/// const AnalyticsHooks = struct {
///     pub fn cycle_completed(payload: tasks.hooks.HookPayload(u32, Item)) void {
///         // Track analytics
///     }
/// };
///
/// // Merge - both handlers will be called
/// const AllHooks = tasks.hooks.MergeTasksHooks(u32, Item, .{ GameTaskHooks, AnalyticsHooks });
/// ```
pub fn MergeTasksHooks(
    comptime GameId: type,
    comptime Item: type,
    comptime handler_structs: anytype,
) type {
    const PayloadType = HookPayload(GameId, Item);

    return struct {
        const Self = @This();

        /// The hook enum type this dispatcher handles.
        pub const Hook = TasksHook;

        /// The payload union type this dispatcher handles.
        pub const Payload = PayloadType;

        /// Emit a hook event to all registered handlers.
        /// Handlers are called in the order the structs appear in handler_structs.
        pub inline fn emit(payload: PayloadType) void {
            switch (payload) {
                inline else => |_, tag| {
                    const hook_name = @tagName(tag);
                    inline for (handler_structs) |H| {
                        if (@hasDecl(H, hook_name)) {
                            const handler = @field(H, hook_name);
                            handler(payload);
                        }
                    }
                },
            }
        }

        /// Check at comptime if any handler struct has a handler for this hook.
        pub fn hasHandler(comptime hook: TasksHook) bool {
            inline for (handler_structs) |H| {
                if (@hasDecl(H, @tagName(hook))) {
                    return true;
                }
            }
            return false;
        }

        /// Get the number of unique hooks that have at least one handler registered.
        pub fn handlerCount() comptime_int {
            var count: comptime_int = 0;
            for (std.enums.values(TasksHook)) |hook| {
                if (hasHandler(hook)) {
                    count += 1;
                }
            }
            return count;
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

const TestItem = enum { Apple, Bread };

test "HookDispatcher emits to registered handlers" {
    const TestHooks = struct {
        var pickup_count: u32 = 0;
        var last_worker_id: u32 = 0;

        pub fn pickup_started(payload: HookPayload(u32, TestItem)) void {
            const info = payload.pickup_started;
            pickup_count += 1;
            last_worker_id = info.worker_id;
        }
    };

    const Dispatcher = HookDispatcher(u32, TestItem, TestHooks);

    // Reset state
    TestHooks.pickup_count = 0;
    TestHooks.last_worker_id = 0;

    // Emit event
    Dispatcher.emit(.{ .pickup_started = .{
        .worker_id = 42,
        .workstation_id = 1,
        .eis_id = 100,
    } });

    try std.testing.expectEqual(@as(u32, 1), TestHooks.pickup_count);
    try std.testing.expectEqual(@as(u32, 42), TestHooks.last_worker_id);
}

test "HookDispatcher ignores unhandled hooks" {
    const TestHooks = struct {
        var count: u32 = 0;

        pub fn pickup_started(_: HookPayload(u32, TestItem)) void {
            count += 1;
        }
        // process_started is not handled
    };

    const Dispatcher = HookDispatcher(u32, TestItem, TestHooks);

    TestHooks.count = 0;

    // This should not crash even though process_started is not handled
    Dispatcher.emit(.{ .process_started = .{
        .worker_id = 1,
        .workstation_id = 1,
    } });

    try std.testing.expectEqual(@as(u32, 0), TestHooks.count);
}

test "MergeTasksHooks calls all handlers" {
    const Hooks1 = struct {
        var called: bool = false;

        pub fn cycle_completed(_: HookPayload(u32, TestItem)) void {
            called = true;
        }
    };

    const Hooks2 = struct {
        var called: bool = false;

        pub fn cycle_completed(_: HookPayload(u32, TestItem)) void {
            called = true;
        }
    };

    const Merged = MergeTasksHooks(u32, TestItem, .{ Hooks1, Hooks2 });

    // Reset state
    Hooks1.called = false;
    Hooks2.called = false;

    Merged.emit(.{ .cycle_completed = .{
        .workstation_id = 1,
        .worker_id = 1,
        .cycles_completed = 1,
    } });

    try std.testing.expect(Hooks1.called);
    try std.testing.expect(Hooks2.called);
}

test "hasHandler returns correct values" {
    const TestHooks = struct {
        pub fn pickup_started(_: HookPayload(u32, TestItem)) void {}
        pub fn cycle_completed(_: HookPayload(u32, TestItem)) void {}
    };

    const Dispatcher = HookDispatcher(u32, TestItem, TestHooks);

    try std.testing.expect(Dispatcher.hasHandler(.pickup_started));
    try std.testing.expect(Dispatcher.hasHandler(.cycle_completed));
    try std.testing.expect(!Dispatcher.hasHandler(.process_started));
    try std.testing.expect(!Dispatcher.hasHandler(.worker_assigned));
}

test "handlerCount returns correct count" {
    const TestHooks = struct {
        pub fn pickup_started(_: HookPayload(u32, TestItem)) void {}
        pub fn process_completed(_: HookPayload(u32, TestItem)) void {}
        pub fn cycle_completed(_: HookPayload(u32, TestItem)) void {}
    };

    const Dispatcher = HookDispatcher(u32, TestItem, TestHooks);

    try std.testing.expectEqual(@as(comptime_int, 3), Dispatcher.handlerCount());
}

test "EmptyDispatcher has no handlers" {
    const Dispatcher = EmptyDispatcher(u32, TestItem);

    try std.testing.expectEqual(@as(comptime_int, 0), Dispatcher.handlerCount());
    try std.testing.expect(!Dispatcher.hasHandler(.pickup_started));
}

test "transport hooks work correctly" {
    const TestHooks = struct {
        var transport_started_count: u32 = 0;
        var last_item: ?TestItem = null;

        pub fn transport_started(payload: HookPayload(u32, TestItem)) void {
            const info = payload.transport_started;
            transport_started_count += 1;
            last_item = info.item;
        }
    };

    const Dispatcher = HookDispatcher(u32, TestItem, TestHooks);

    TestHooks.transport_started_count = 0;
    TestHooks.last_item = null;

    Dispatcher.emit(.{ .transport_started = .{
        .worker_id = 1,
        .from_storage_id = 100,
        .to_storage_id = 200,
        .item = .Apple,
    } });

    try std.testing.expectEqual(@as(u32, 1), TestHooks.transport_started_count);
    try std.testing.expectEqual(TestItem.Apple, TestHooks.last_item.?);
}
