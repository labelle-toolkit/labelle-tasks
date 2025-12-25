//! labelle-tasks Hook System
//!
//! A type-safe, comptime-based hook/event system for labelle-tasks.
//! Compatible with labelle-engine's hook system.
//!
//! ## Overview
//!
//! The hook system allows games to register callbacks for task engine lifecycle events
//! (step started, step completed, worker assigned, etc.) with zero runtime overhead.
//!
//! ## Usage
//!
//! Define a hook handler struct with functions matching hook names:
//!
//! ```zig
//! const MyTaskHooks = struct {
//!     pub fn step_started(payload: tasks.HookPayload) void {
//!         const info = payload.step_started;
//!         std.log.info("Worker {d} started step at workstation {d}", .{
//!             info.worker_id, info.workstation_id,
//!         });
//!     }
//!
//!     pub fn step_completed(payload: tasks.HookPayload) void {
//!         const info = payload.step_completed;
//!         std.log.info("Step completed: {}", .{info.step.type});
//!     }
//! };
//!
//! // Create a dispatcher
//! const Dispatcher = tasks.TasksHookDispatcher(MyTaskHooks);
//!
//! // Create engine with dispatcher
//! var engine = tasks.EngineWithHooks(u32, Dispatcher).init(allocator);
//! ```
//!
//! ## Integration with labelle-engine
//!
//! The hook system is designed to integrate with labelle-engine's hook system:
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
//!         pub fn frame_start(_: engine.HookPayload) void {
//!             // Update task engine
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

pub const StepType = root.StepType;
pub const StepDef = root.StepDef;
pub const Priority = root.Priority;

/// Built-in hooks for task engine lifecycle events.
/// Games can register handlers for any of these hooks.
pub const TasksHook = enum {
    // Step lifecycle
    step_started,
    step_completed,

    // Worker lifecycle
    worker_assigned,
    worker_released,

    // Workstation lifecycle
    workstation_blocked,
    workstation_queued,
    workstation_activated,

    // Cycle lifecycle
    cycle_completed,
};

/// Step information for step lifecycle hooks.
pub fn StepInfo(comptime GameId: type) type {
    return struct {
        /// The game's ID for the worker.
        worker_id: GameId,
        /// The game's ID for the workstation.
        workstation_id: GameId,
        /// The step definition.
        step: StepDef,
    };
}

/// Worker assignment information.
pub fn WorkerAssignmentInfo(comptime GameId: type) type {
    return struct {
        /// The game's ID for the worker.
        worker_id: GameId,
        /// The game's ID for the workstation.
        workstation_id: GameId,
    };
}

/// Worker release information.
pub fn WorkerReleaseInfo(comptime GameId: type) type {
    return struct {
        /// The game's ID for the worker.
        worker_id: GameId,
        /// The game's ID for the workstation the worker was released from.
        workstation_id: GameId,
    };
}

/// Workstation status change information.
pub fn WorkstationStatusInfo(comptime GameId: type) type {
    return struct {
        /// The game's ID for the workstation.
        workstation_id: GameId,
        /// The workstation's priority.
        priority: Priority,
    };
}

/// Cycle completion information.
pub fn CycleInfo(comptime GameId: type) type {
    return struct {
        /// The game's ID for the workstation.
        workstation_id: GameId,
        /// The game's ID for the worker who completed the cycle.
        worker_id: GameId,
        /// Number of cycles completed (including this one).
        cycles_completed: u32,
    };
}

/// Type-safe payload union for task hooks.
/// Each hook type has its corresponding payload type.
/// Parameterized by game's entity ID type.
pub fn HookPayload(comptime GameId: type) type {
    return union(TasksHook) {
        step_started: StepInfo(GameId),
        step_completed: StepInfo(GameId),

        worker_assigned: WorkerAssignmentInfo(GameId),
        worker_released: WorkerReleaseInfo(GameId),

        workstation_blocked: WorkstationStatusInfo(GameId),
        workstation_queued: WorkstationStatusInfo(GameId),
        workstation_activated: WorkstationStatusInfo(GameId),

        cycle_completed: CycleInfo(GameId),
    };
}

/// Creates a hook dispatcher from a comptime hook map.
///
/// The HookMap should be a struct type where each public declaration is a
/// function matching the signature for that hook (e.g., `step_started`, `step_completed`).
///
/// Example:
/// ```zig
/// const MyHooks = struct {
///     pub fn step_started(payload: tasks.HookPayload(u32)) void {
///         const info = payload.step_started;
///         std.log.info("Step started!", .{});
///     }
/// };
///
/// const Dispatcher = tasks.HookDispatcher(u32, MyHooks);
/// Dispatcher.emit(.{ .step_started = .{ ... } });
/// ```
pub fn HookDispatcher(
    comptime GameId: type,
    comptime HookMap: type,
) type {
    const PayloadType = HookPayload(GameId);

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
pub fn EmptyDispatcher(comptime GameId: type) type {
    return HookDispatcher(GameId, struct {});
}

/// Convenience type for creating a task hook dispatcher.
/// Equivalent to `HookDispatcher(GameId, HookMap)`.
pub fn TasksHookDispatcher(comptime GameId: type, comptime HookMap: type) type {
    return HookDispatcher(GameId, HookMap);
}

/// Merges multiple hook handler structs into one composite dispatcher.
/// When a hook is emitted, all matching handlers from all structs are called in order.
///
/// Example:
/// ```zig
/// const GameTaskHooks = struct {
///     pub fn step_completed(payload: tasks.HookPayload(u32)) void {
///         std.log.info("Game: step completed!", .{});
///     }
/// };
///
/// const AnalyticsHooks = struct {
///     pub fn step_completed(payload: tasks.HookPayload(u32)) void {
///         // Track analytics
///     }
/// };
///
/// // Merge - both handlers will be called
/// const AllHooks = tasks.MergeTasksHooks(u32, .{ GameTaskHooks, AnalyticsHooks });
/// ```
pub fn MergeTasksHooks(
    comptime GameId: type,
    comptime handler_structs: anytype,
) type {
    const PayloadType = HookPayload(GameId);

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

test "HookDispatcher emits to registered handlers" {
    const TestHooks = struct {
        var step_started_count: u32 = 0;
        var last_worker_id: u32 = 0;

        pub fn step_started(payload: HookPayload(u32)) void {
            const info = payload.step_started;
            step_started_count += 1;
            last_worker_id = info.worker_id;
        }
    };

    const Dispatcher = HookDispatcher(u32, TestHooks);

    // Reset state
    TestHooks.step_started_count = 0;
    TestHooks.last_worker_id = 0;

    // Emit event
    Dispatcher.emit(.{ .step_started = .{
        .worker_id = 42,
        .workstation_id = 1,
        .step = .{ .type = .Pickup },
    } });

    try std.testing.expectEqual(@as(u32, 1), TestHooks.step_started_count);
    try std.testing.expectEqual(@as(u32, 42), TestHooks.last_worker_id);
}

test "HookDispatcher ignores unhandled hooks" {
    const TestHooks = struct {
        var count: u32 = 0;

        pub fn step_started(_: HookPayload(u32)) void {
            count += 1;
        }
        // step_completed is not handled
    };

    const Dispatcher = HookDispatcher(u32, TestHooks);

    TestHooks.count = 0;

    // This should not crash even though step_completed is not handled
    Dispatcher.emit(.{ .step_completed = .{
        .worker_id = 1,
        .workstation_id = 1,
        .step = .{ .type = .Cook },
    } });

    try std.testing.expectEqual(@as(u32, 0), TestHooks.count);
}

test "MergeTasksHooks calls all handlers" {
    const Hooks1 = struct {
        var called: bool = false;

        pub fn step_completed(_: HookPayload(u32)) void {
            called = true;
        }
    };

    const Hooks2 = struct {
        var called: bool = false;

        pub fn step_completed(_: HookPayload(u32)) void {
            called = true;
        }
    };

    const Merged = MergeTasksHooks(u32, .{ Hooks1, Hooks2 });

    // Reset state
    Hooks1.called = false;
    Hooks2.called = false;

    Merged.emit(.{ .step_completed = .{
        .worker_id = 1,
        .workstation_id = 1,
        .step = .{ .type = .Store },
    } });

    try std.testing.expect(Hooks1.called);
    try std.testing.expect(Hooks2.called);
}

test "hasHandler returns correct values" {
    const TestHooks = struct {
        pub fn step_started(_: HookPayload(u32)) void {}
        pub fn cycle_completed(_: HookPayload(u32)) void {}
    };

    const Dispatcher = HookDispatcher(u32, TestHooks);

    try std.testing.expect(Dispatcher.hasHandler(.step_started));
    try std.testing.expect(Dispatcher.hasHandler(.cycle_completed));
    try std.testing.expect(!Dispatcher.hasHandler(.step_completed));
    try std.testing.expect(!Dispatcher.hasHandler(.worker_assigned));
}

test "handlerCount returns correct count" {
    const TestHooks = struct {
        pub fn step_started(_: HookPayload(u32)) void {}
        pub fn step_completed(_: HookPayload(u32)) void {}
        pub fn cycle_completed(_: HookPayload(u32)) void {}
    };

    const Dispatcher = HookDispatcher(u32, TestHooks);

    try std.testing.expectEqual(@as(comptime_int, 3), Dispatcher.handlerCount());
}

test "EmptyDispatcher has no handlers" {
    const Dispatcher = EmptyDispatcher(u32);

    try std.testing.expectEqual(@as(comptime_int, 0), Dispatcher.handlerCount());
    try std.testing.expect(!Dispatcher.hasHandler(.step_started));
}
