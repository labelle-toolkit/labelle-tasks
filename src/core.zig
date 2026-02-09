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

// === Hooks ===

/// Payload for events emitted by task engine to game.
pub const TaskHookPayload = hooks_mod.TaskHookPayload;

/// Payload for events sent by game to task engine.
pub const GameHookPayload = hooks_mod.GameHookPayload;

/// Hook dispatcher for calling comptime hook methods.
pub const HookDispatcher = hooks_mod.HookDispatcher;

/// Empty hooks struct for engines that don't need hooks.
pub const NoHooks = hooks_mod.NoHooks;

/// Recording hooks for testing. Records all dispatched events for assertion.
pub const RecordingHooks = hooks_mod.RecordingHooks;

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
