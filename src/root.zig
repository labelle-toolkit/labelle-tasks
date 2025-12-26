//! labelle-tasks: Comptime workstation task system for labelle-engine
//!
//! This module provides a task orchestration system using comptime-sized
//! workstation types. Each workstation variant is a distinct ECS component
//! with fixed storage array sizes.
//!
//! ## Quick Start
//!
//! ```zig
//! const tasks = @import("labelle-tasks");
//!
//! // Define workstation types in your game
//! pub const KitchenWorkstation = tasks.TaskWorkstation(2, 2, 1, 1);
//! pub const WellWorkstation = tasks.TaskWorkstation(0, 0, 1, 1);
//!
//! // Register as ECS components alongside TaskWorkstationBinding
//! ```
//!
//! ## Workflow
//!
//! Items flow through storages: EIS → IIS (Pickup) → IOS (Process) → EOS (Store)
//!
//! - **EIS**: External Input Storage - source of raw materials
//! - **IIS**: Internal Input Storage - recipe inputs (define ingredient count)
//! - **IOS**: Internal Output Storage - recipe outputs
//! - **EOS**: External Output Storage - finished products

const workstation = @import("workstation.zig");
const binding = @import("binding.zig");
const storage = @import("storage.zig");

// === Core Types ===

/// Generic comptime-sized workstation type.
/// Create workstation variants with specific storage counts.
pub const TaskWorkstation = workstation.TaskWorkstation;

/// Interface for working with any workstation type generically.
pub const WorkstationInterface = workstation.WorkstationInterface;

/// Common binding component for all workstation types.
/// Holds configuration and runtime state.
pub const TaskWorkstationBinding = binding.TaskWorkstationBinding;

/// Storage component for items in the task system.
pub const TaskStorage = storage.TaskStorage;

/// Role marker for storage entities (eis/iis/ios/eos).
pub const TaskStorageRole = storage.TaskStorageRole;

// === Enums ===

/// Entity reference type.
pub const Entity = workstation.Entity;

/// Priority levels for workstations and storages.
pub const Priority = workstation.Priority;

/// Workstation status in the task pipeline.
pub const WorkstationStatus = workstation.WorkstationStatus;

/// Current step in the workstation cycle.
pub const StepType = workstation.StepType;

/// Storage role in the workstation workflow.
pub const StorageRole = storage.StorageRole;

// === Components Export ===

/// All components provided by labelle-tasks for ECS registration.
pub const Components = struct {
    pub const TaskWorkstationBinding = binding.TaskWorkstationBinding;
    pub const TaskStorage = storage.TaskStorage;
    pub const TaskStorageRole = storage.TaskStorageRole;
};

// === Tests ===

test {
    _ = @import("workstation.zig");
    _ = @import("binding.zig");
    _ = @import("storage.zig");
}
