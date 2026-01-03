//! labelle-tasks core: Pure state machine task orchestration engine
//!
//! This module exports the core engine and hooks without ECS integration.
//! Use this for testing or when you don't need auto-registering components.

const engine_mod = @import("engine.zig");
const hooks_mod = @import("hooks.zig");
const state_mod = @import("state.zig");

// === Core Engine ===

/// Pure state machine task orchestration engine.
pub const Engine = engine_mod.Engine;

/// Convenience alias for Engine with hooks.
pub const EngineWithHooks = engine_mod.EngineWithHooks;

// === Hooks ===

/// Payload for events emitted by task engine to game.
pub const TaskHookPayload = hooks_mod.TaskHookPayload;

/// Payload for events sent by game to task engine.
pub const GameHookPayload = hooks_mod.GameHookPayload;

/// Hook dispatcher for calling comptime hook methods.
pub const HookDispatcher = hooks_mod.HookDispatcher;

/// Empty hooks struct for engines that don't need hooks.
pub const NoHooks = hooks_mod.NoHooks;

// === Hooks Namespace (backward compatibility) ===

pub const hooks = struct {
    pub const TaskHookPayload = hooks_mod.TaskHookPayload;
    pub const GameHookPayload = hooks_mod.GameHookPayload;
    pub const HookDispatcher = hooks_mod.HookDispatcher;
    pub const NoHooks = hooks_mod.NoHooks;

    pub fn HookPayload(comptime GameId: type, comptime Item: type) type {
        return hooks_mod.TaskHookPayload(GameId, Item);
    }

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

        return fields[0].type;
    }
};

// === Enums ===

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
