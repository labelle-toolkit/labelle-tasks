//! labelle-tasks: Task orchestration engine for Zig games
//!
//! A self-contained task orchestration engine. Games interact via:
//! - Registering workers and workstations with game entity IDs
//! - Providing callbacks for game-specific logic (pathfinding, animations)
//! - Notifying the engine of game events (step complete, worker idle)
//!
//! Example:
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

const std = @import("std");

// ============================================================================
// Engine API
// ============================================================================

pub const Engine = @import("engine.zig").Engine;

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
