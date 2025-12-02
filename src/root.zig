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

// ============================================================================
// ECS Systems
// ============================================================================

const ecs = @import("ecs");
pub const Registry = ecs.Registry;
pub const Entity = ecs.Entity;

/// System that transitions task groups from Blocked to Queued (or Active) status.
///
/// If a blocked group already has an assigned worker (continuing from previous cycle),
/// it transitions directly to Active instead of Queued.
///
/// Config must provide:
/// - `GroupComponent`: The component type for task groups (must have `status: TaskGroupStatus`)
/// - `GroupAssignedComponent`: Component on group indicating assigned worker
/// - `canUnblock(reg, entity) bool`: Returns true if the group can be unblocked
pub fn BlockedToQueuedSystem(comptime Config: type) type {
    return struct {
        pub fn run(reg: *Registry) void {
            var view = reg.view(.{Config.GroupComponent}, .{});
            var iter = view.entityIterator();
            while (iter.next()) |entity| {
                const group = reg.get(Config.GroupComponent, entity);
                if (group.status == .Blocked) {
                    if (Config.canUnblock(reg, entity)) {
                        // If group already has a worker assigned (continuing), go to Active
                        // Otherwise go to Queued to wait for worker assignment
                        const has_worker = reg.tryGet(Config.GroupAssignedComponent, entity) != null;
                        group.status = if (has_worker) .Active else .Queued;
                    }
                }
            }
        }
    };
}

/// System that assigns idle workers to queued task groups (1:1, highest priority first).
///
/// Config must provide:
/// - `GroupComponent`: The component type for task groups (must have `status: TaskGroupStatus`, `priority: Priority`)
/// - `WorkerComponent`: The component type for workers
/// - `AssignedComponent`: Component added to worker when assigned (must have `group: Entity` field)
/// - `GroupAssignedComponent`: Component added to group when assigned (must have `worker: Entity` field)
/// - `isWorkerIdle(reg, entity) bool`: Returns true if worker is available for assignment
/// - `onAssigned(reg, worker_entity, group_entity) void`: Called after assignment is made
pub fn WorkerAssignmentSystem(comptime Config: type) type {
    return struct {
        pub fn run(reg: *Registry) void {
            // Find queued groups without workers, sorted by priority (highest first)
            var group_view = reg.view(.{Config.GroupComponent}, .{Config.GroupAssignedComponent});
            var group_iter = group_view.entityIterator();

            while (group_iter.next()) |group_entity| {
                const group = reg.get(Config.GroupComponent, group_entity);
                if (group.status != .Queued) continue;

                // Find an idle worker
                var worker_view = reg.view(.{Config.WorkerComponent}, .{Config.AssignedComponent});
                var worker_iter = worker_view.entityIterator();

                while (worker_iter.next()) |worker_entity| {
                    if (Config.isWorkerIdle(reg, worker_entity)) {
                        // Assign worker to group
                        reg.add(worker_entity, Config.AssignedComponent{ .group = group_entity });
                        reg.add(group_entity, Config.GroupAssignedComponent{ .worker = worker_entity });
                        group.status = .Active;

                        Config.onAssigned(reg, worker_entity, group_entity);
                        break;
                    }
                }
            }
        }
    };
}

/// System that handles task group completion and worker release.
///
/// When a group's steps are complete, this system:
/// 1. Resets the group (steps back to 0, status to Blocked)
/// 2. Calls `shouldContinue` to check if worker stays assigned
/// 3. If not continuing, releases the worker and calls `onReleased`
///
/// Config must provide:
/// - `GroupComponent`: The component type for task groups (must have `status: TaskGroupStatus`, `steps: GroupSteps`)
/// - `WorkerComponent`: The component type for workers
/// - `AssignedComponent`: Component on worker indicating assignment
/// - `GroupAssignedComponent`: Component on group indicating assigned worker
/// - `shouldContinue(reg, worker_entity, group_entity) bool`: Returns true if worker should start another cycle
/// - `onReleased(reg, worker_entity, group_entity) void`: Called when worker is released from group
/// - `setWorkerIdle(reg, worker_entity) void`: Called to reset worker to idle state
pub fn GroupCompletionSystem(comptime Config: type) type {
    return struct {
        pub fn run(reg: *Registry) void {
            var view = reg.view(.{ Config.GroupComponent, Config.GroupAssignedComponent }, .{});
            var iter = view.entityIterator();

            while (iter.next()) |group_entity| {
                const group = reg.get(Config.GroupComponent, group_entity);
                if (group.status != .Active) continue;
                if (!group.steps.isComplete()) continue;

                const assigned = reg.get(Config.GroupAssignedComponent, group_entity);
                const worker_entity = assigned.worker;

                // Reset group steps for next cycle
                group.steps.reset();

                // Check if worker should continue
                if (Config.shouldContinue(reg, worker_entity, group_entity)) {
                    // Worker stays assigned, set group to Blocked for resource re-check
                    // BlockedToQueuedSystem will transition back to Queued if resources available
                    // Then since worker is still assigned, it will go straight to Active
                    group.status = .Blocked;
                } else {
                    // Release worker, group goes back to Blocked
                    group.status = .Blocked;
                    reg.remove(Config.AssignedComponent, worker_entity);
                    reg.remove(Config.GroupAssignedComponent, group_entity);
                    Config.setWorkerIdle(reg, worker_entity);
                    Config.onReleased(reg, worker_entity, group_entity);
                }
            }
        }
    };
}
