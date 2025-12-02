//! labelle-tasks: ECS task/job queue system for Zig games
//!
//! A generic task/job queue system designed for game AI, worker management,
//! and job assignment. Built to integrate with zig-ecs.

const std = @import("std");

// ============================================================================
// Common Types
// ============================================================================

pub const Priority = enum {
    Low,
    Normal,
    High,
    Critical,
};

pub const InterruptLevel = enum {
    None, // can always be interrupted
    Low, // only High/Critical can interrupt
    High, // only Critical can interrupt
    Atomic, // cannot be interrupted
};

// ============================================================================
// Standalone Task Components
// ============================================================================

pub const TaskStatus = enum {
    Queued,
    Active,
    Completed,
    Cancelled,
};

pub const Task = struct {
    status: TaskStatus,
    priority: Priority,
    interrupt_level: InterruptLevel,

    pub fn init(priority: Priority) Task {
        return .{
            .status = .Queued,
            .priority = priority,
            .interrupt_level = .None,
        };
    }

    pub fn withInterruptLevel(self: Task, level: InterruptLevel) Task {
        var task = self;
        task.interrupt_level = level;
        return task;
    }
};

// ============================================================================
// Task Group Components
// ============================================================================

pub const TaskGroupStatus = enum {
    Blocked,
    Queued,
    Active,
};

pub const TaskGroup = struct {
    status: TaskGroupStatus,
    priority: Priority,
    interrupt_level: InterruptLevel,

    pub fn init(priority: Priority) TaskGroup {
        return .{
            .status = .Blocked,
            .priority = priority,
            .interrupt_level = .None,
        };
    }

    pub fn withInterruptLevel(self: TaskGroup, level: InterruptLevel) TaskGroup {
        var group = self;
        group.interrupt_level = level;
        return group;
    }
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

pub const GroupSteps = struct {
    steps: []const StepDef,
    current_index: u8,

    pub fn init(steps: []const StepDef) GroupSteps {
        return initAt(steps, 0);
    }

    /// Initialize GroupSteps at a specific step index for resuming interrupted work.
    /// Asserts that start_index <= steps.len (equal means already complete).
    pub fn initAt(steps: []const StepDef, start_index: u8) GroupSteps {
        std.debug.assert(start_index <= steps.len);
        return .{
            .steps = steps,
            .current_index = start_index,
        };
    }

    pub fn currentStep(self: GroupSteps) ?StepDef {
        if (self.current_index >= self.steps.len) return null;
        return self.steps[self.current_index];
    }

    pub fn advance(self: *GroupSteps) bool {
        if (self.current_index >= self.steps.len) return false;
        self.current_index += 1;
        return true;
    }

    pub fn reset(self: *GroupSteps) void {
        self.current_index = 0;
    }

    pub fn isComplete(self: GroupSteps) bool {
        return self.current_index >= self.steps.len;
    }
};

// ============================================================================
// Interrupt Logic
// ============================================================================

/// Check if a task/group with given interrupt level can be interrupted by given priority
pub fn canInterrupt(interrupt_level: InterruptLevel, by_priority: Priority) bool {
    return switch (interrupt_level) {
        .None => true,
        .Low => by_priority == .High or by_priority == .Critical,
        .High => by_priority == .Critical,
        .Atomic => false,
    };
}
