//! labelle-tasks: Pure state machine task orchestration engine
//!
//! This module provides a task orchestration engine that tracks abstract workflow
//! state and emits hooks to notify the game of events. The engine never mutates
//! game state directly - it only updates its internal abstract state.
//!
//! ## Quick Start
//!
//! ```zig
//! const tasks = @import("labelle-tasks");
//!
//! const Item = enum { Flour, Bread };
//!
//! // Define hooks to receive from task engine
//! const MyHooks = struct {
//!     pub fn process_completed(payload: anytype) void {
//!         // Game handles entity transformation
//!     }
//!     pub fn cycle_completed(payload: anytype) void {
//!         // Cycle finished
//!     }
//! };
//!
//! // Create engine
//! var engine = tasks.Engine(u32, Item, MyHooks).init(allocator, .{});
//! defer engine.deinit();
//!
//! // Register entities
//! engine.addStorage(eis_id, .Flour);
//! engine.addStorage(iis_id, null);
//! engine.addStorage(ios_id, null);
//! engine.addStorage(eos_id, null);
//! engine.addWorkstation(ws_id, .{ .eis = &.{eis_id}, .iis = &.{iis_id}, ... });
//! engine.addWorker(worker_id);
//!
//! // Game notifies engine of events
//! engine.handle(.{ .worker_available = .{ .worker_id = worker_id } });
//! engine.handle(.{ .pickup_completed = .{ .worker_id = worker_id } });
//! engine.handle(.{ .work_completed = .{ .workstation_id = ws_id } });
//! engine.handle(.{ .store_completed = .{ .worker_id = worker_id } });
//! ```
//!
//! ## Workflow
//!
//! Items flow through storages: EIS → IIS (Pickup) → IOS (Process) → EOS (Store)
//!
//! - **EIS**: External Input Storage - source of raw materials
//! - **IIS**: Internal Input Storage - recipe inputs
//! - **IOS**: Internal Output Storage - recipe outputs
//! - **EOS**: External Output Storage - finished products
//!
//! ## Architecture
//!
//! The engine is a pure state machine:
//! - Tracks abstract state (has_item, item_type, current_step, assigned_worker)
//! - Receives notifications from game via handle(GameHookPayload)
//! - Emits hooks to game via TaskHookPayload
//! - Never mutates game state (no entity references, no timers)
//!
//! Game owns:
//! - Entity lifecycle (prefabs, creation, destruction)
//! - Work timing (timers, accumulated work)
//! - Movement/pathfinding
//! - All ECS state

const engine_mod = @import("engine.zig");
const hooks_mod = @import("hooks.zig");

// === Core Engine ===

/// Pure state machine task orchestration engine.
/// Generic over GameId (entity identifier), Item (item enum), and TaskHooks (hook receiver).
pub const Engine = engine_mod.Engine;

/// Convenience alias for Engine with hooks.
pub const EngineWithHooks = engine_mod.EngineWithHooks;

// === Hooks ===

/// Payload for events emitted by task engine to game.
/// Game subscribes to these hooks to react to workflow events.
pub const TaskHookPayload = hooks_mod.TaskHookPayload;

/// Payload for events sent by game to task engine.
/// Game calls engine.handle() with these payloads.
pub const GameHookPayload = hooks_mod.GameHookPayload;

/// Hook dispatcher for calling comptime hook methods.
pub const HookDispatcher = hooks_mod.HookDispatcher;

/// Empty hooks struct for engines that don't need hooks.
pub const NoHooks = hooks_mod.NoHooks;

// === Logging Hooks ===

const logging_hooks_mod = @import("logging_hooks.zig");

/// Default logging implementation for all task engine hooks.
/// Use directly or merge with custom hooks using MergeHooks.
pub const LoggingHooks = logging_hooks_mod.LoggingHooks;

/// Merges two hook structs, with Primary taking precedence over Fallback.
/// Use to compose custom hooks with LoggingHooks for default logging.
///
/// Example:
/// ```zig
/// const MyHooks = struct {
///     pub fn store_started(payload: anytype) void {
///         // Custom behavior
///     }
/// };
/// const Hooks = tasks.MergeHooks(MyHooks, tasks.LoggingHooks);
/// ```
pub const MergeHooks = logging_hooks_mod.MergeHooks;

// === Hooks Namespace (backward compatibility) ===

/// Namespace for hook-related types and utilities.
/// Provides backward compatibility with existing code that uses `labelle_tasks.hooks.*`
pub const hooks = struct {
    pub const TaskHookPayload = hooks_mod.TaskHookPayload;
    pub const GameHookPayload = hooks_mod.GameHookPayload;
    pub const HookDispatcher = hooks_mod.HookDispatcher;
    pub const NoHooks = hooks_mod.NoHooks;

    /// Alias for TaskHookPayload (backward compatibility)
    pub fn HookPayload(comptime GameId: type, comptime Item: type) type {
        return hooks_mod.TaskHookPayload(GameId, Item);
    }

    /// Merges multiple hook structs into a single struct.
    /// For the new pure state machine architecture, this simply returns the first
    /// non-empty hook struct from the tuple, as hooks are now handled locally.
    ///
    /// Usage:
    /// ```zig
    /// const MergedHooks = tasks.hooks.MergeTasksHooks(u32, Item, .{ HooksA, HooksB });
    /// ```
    pub fn MergeTasksHooks(
        comptime GameId: type,
        comptime Item: type,
        comptime hook_structs: anytype,
    ) type {
        _ = GameId;
        _ = Item;

        const info = @typeInfo(@TypeOf(hook_structs));
        if (info != .@"struct") {
            @compileError("MergeTasksHooks expects a tuple of hook structs");
        }

        const fields = info.@"struct".fields;
        if (fields.len == 0) {
            return hooks_mod.NoHooks;
        }

        // Return the first hook struct type
        // In the new architecture, each script manages its own hooks internally
        return fields[0].type;
    }
};

// === Enums ===

const state_mod = @import("state.zig");

/// Worker state in the task engine.
pub const WorkerState = engine_mod.WorkerState;

/// Workstation status in the task pipeline.
pub const WorkstationStatus = engine_mod.WorkstationStatus;

/// Current step in the workstation cycle.
pub const StepType = engine_mod.StepType;

/// Priority levels for workstations and storages.
pub const Priority = engine_mod.Priority;

/// Storage role in the workflow (EIS, IIS, IOS, EOS).
pub const StorageRole = state_mod.StorageRole;

// === ECS Integration (RFC #28) ===

const ecs_bridge = @import("ecs_bridge.zig");
const components_mod = @import("components.zig");
const context_mod = @import("context.zig");

/// Helper to reduce game integration boilerplate.
/// Manages task engine lifecycle, vtable wrapping, and movement queue.
///
/// Example:
/// ```zig
/// const tasks = @import("labelle-tasks");
///
/// const MyHooks = struct {
///     pub fn store_started(payload: anytype) void {
///         const pos = getStoragePosition(payload.storage_id);
///         Context.queueMovement(payload.worker_id, pos.x, pos.y, .store);
///     }
/// };
///
/// pub const Context = tasks.TaskEngineContext(u64, Item, MyHooks);
///
/// // In game_init hook:
/// Context.init(allocator, getEntityDistance) catch return;
///
/// // In game_deinit hook:
/// Context.deinit();
/// ```
pub fn TaskEngineContext(comptime GameId: type, comptime Item: type, comptime Hooks: type) type {
    return context_mod.TaskEngineContext(GameId, Item, Hooks);
}

/// Type-erased interface for ECS operations.
pub fn EcsInterface(comptime GameId: type, comptime Item: type) type {
    return ecs_bridge.EcsInterface(GameId, Item);
}

/// Set the ECS interface for auto-registering components.
/// Call this during game initialization after creating the task engine.
///
/// Example:
/// ```zig
/// var task_engine = tasks.Engine(u64, Item, Hooks).init(allocator, .{});
/// tasks.setEngineInterface(u64, Item, task_engine.interface());
/// ```
pub fn setEngineInterface(comptime GameId: type, comptime Item: type, iface: EcsInterface(GameId, Item)) void {
    ecs_bridge.InterfaceStorage(GameId, Item).setInterface(iface);
}

/// Clear the ECS interface (for cleanup).
pub fn clearEngineInterface(comptime GameId: type, comptime Item: type) void {
    ecs_bridge.InterfaceStorage(GameId, Item).clearInterface();
}

/// Storage component for the task engine.
/// Auto-registers with task engine when added to an entity.
pub fn Storage(comptime Item: type) type {
    return components_mod.Storage(Item);
}

/// Worker component for the task engine.
/// Auto-registers with task engine when added to an entity.
pub fn Worker(comptime Item: type) type {
    return components_mod.Worker(Item);
}

/// Dangling item component for the task engine.
/// Auto-registers with task engine when added to an entity.
pub fn DanglingItem(comptime Item: type) type {
    return components_mod.DanglingItem(Item);
}

/// Workstation component for the task engine.
/// Auto-registers with task engine when added to an entity.
/// Nested Storage components will auto-attach via parent reference.
pub fn Workstation(comptime Item: type) type {
    return components_mod.Workstation(Item);
}
