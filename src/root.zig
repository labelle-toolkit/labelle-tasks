//! labelle-tasks: Task orchestration engine for Zig games
//!
//! A self-contained task orchestration engine. Games interact via:
//! - Registering workers and workstations with game entity IDs
//! - Providing callbacks for game-specific logic (pathfinding, animations)
//! - Notifying the engine of game events (step complete, worker idle)
//!
//! Example (callback-based):
//! ```zig
//! var engine = tasks.Engine(u32).init(allocator);
//! defer engine.deinit();
//!
//! // Register callbacks
//! engine.setFindBestWorker(myFindWorkerFn);
//! engine.setOnStepStarted(myStepStartedFn);
//!
//! // Register game entities
//! engine.addWorker(chef_id, .{});
//! engine.addWorkstation(stove_id, .{ .steps = &cooking_steps, .priority = .High });
//!
//! // Game events
//! engine.notifyResourcesAvailable(stove_id);
//! engine.notifyStepComplete(chef_id);
//! ```
//!
//! Example (hook-based, for labelle-engine integration):
//! ```zig
//! const MyTaskHooks = struct {
//!     pub fn step_started(payload: tasks.hooks.HookPayload(u32)) void {
//!         const info = payload.step_started;
//!         std.log.info("Step started!", .{});
//!     }
//! };
//!
//! const Dispatcher = tasks.hooks.HookDispatcher(u32, MyTaskHooks);
//! var engine = tasks.EngineWithHooks(u32, Dispatcher).init(allocator);
//! ```

const std = @import("std");

// ============================================================================
// Engine API
// ============================================================================

const engine_mod = @import("engine.zig");
pub const Engine = engine_mod.Engine;
pub const EngineWithHooks = engine_mod.EngineWithHooks;

// ============================================================================
// Hook System
// ============================================================================

pub const hooks = @import("hooks.zig");

// ============================================================================
// Common Types
// ============================================================================

pub const Priority = enum {
    Low,
    Normal,
    High,
    Critical,
};

pub const StepType = enum {
    Pickup,
    Cook,
    Store,
    Craft,
};

pub const StepDef = struct {
    type: StepType,
};
