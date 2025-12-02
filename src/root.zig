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
// ECS Integration
// ============================================================================

const ecs = @import("ecs");
pub const Registry = ecs.Registry;
pub const Entity = ecs.Entity;

// ============================================================================
// Standard Worker Components
// ============================================================================

/// Worker state for task assignment.
/// - Idle: available for assignment
/// - Working: currently assigned to a task group
/// - Blocked: unavailable (fighting, sleeping, eating, etc.)
pub const WorkerState = enum {
    Idle,
    Working,
    Blocked,
};

/// Standard worker component. Add this to entities that can perform tasks.
pub const Worker = struct {
    state: WorkerState = .Idle,

    pub fn isIdle(self: Worker) bool {
        return self.state == .Idle;
    }

    pub fn isAvailable(self: Worker) bool {
        return self.state == .Idle;
    }
};

/// Component added to worker when assigned to a group.
pub const AssignedToGroup = struct {
    group: Entity,
};

/// Component added to group when a worker is assigned.
pub const GroupAssignedWorker = struct {
    worker: Entity,
};

/// Marker component: add to worker when current step is complete.
/// The event system will react to this, advance the step, and remove the marker.
pub const StepComplete = struct {};

// ============================================================================
// ECS Systems
// ============================================================================

/// System that transitions task groups from Blocked to Queued (or Active) status.
///
/// If a blocked group already has an assigned worker (continuing from previous cycle),
/// it transitions directly to Active instead of Queued.
///
/// Parameters:
/// - `GroupComponent`: Component type for task groups (must have `status: TaskGroupStatus`)
/// - `GroupAssignedComponent`: Component on group indicating assigned worker
/// - `canUnblock`: fn(*Registry, Entity) bool - returns true if group can be unblocked
pub fn BlockedToQueuedSystem(
    comptime GroupComponent: type,
    comptime GroupAssignedComponent: type,
    comptime canUnblock: fn (*Registry, Entity) bool,
) type {
    return struct {
        pub fn run(reg: *Registry) void {
            var view = reg.view(.{GroupComponent}, .{});
            var iter = view.entityIterator();
            while (iter.next()) |entity| {
                const group = reg.get(GroupComponent, entity);
                if (group.status == .Blocked) {
                    if (canUnblock(reg, entity)) {
                        // If group already has a worker assigned (continuing), go to Active
                        // Otherwise go to Queued to wait for worker assignment
                        const has_worker = reg.tryGet(GroupAssignedComponent, entity) != null;
                        group.status = if (has_worker) .Active else .Queued;
                    }
                }
            }
        }
    };
}

/// System that assigns idle workers to queued task groups (1:1).
///
/// Parameters:
/// - `GroupComponent`: Component type for task groups (must have `status: TaskGroupStatus`)
/// - `WorkerComponent`: Component type for workers
/// - `AssignedComponent`: Component added to worker when assigned (must have `group: Entity` field)
/// - `GroupAssignedComponent`: Component added to group when assigned (must have `worker: Entity` field)
/// - `isWorkerIdle`: fn(*Registry, Entity) bool - returns true if worker is available
/// - `onAssigned`: fn(*Registry, Entity, Entity) void - called after assignment (worker, group)
pub fn WorkerAssignmentSystem(
    comptime GroupComponent: type,
    comptime WorkerComponent: type,
    comptime AssignedComponent: type,
    comptime GroupAssignedComponent: type,
    comptime isWorkerIdle: fn (*Registry, Entity) bool,
    comptime onAssigned: fn (*Registry, Entity, Entity) void,
) type {
    return struct {
        pub fn run(reg: *Registry) void {
            // Find queued groups without workers
            var group_view = reg.view(.{GroupComponent}, .{GroupAssignedComponent});
            var group_iter = group_view.entityIterator();

            while (group_iter.next()) |group_entity| {
                const group = reg.get(GroupComponent, group_entity);
                if (group.status != .Queued) continue;

                // Find an idle worker
                var worker_view = reg.view(.{WorkerComponent}, .{AssignedComponent});
                var worker_iter = worker_view.entityIterator();

                while (worker_iter.next()) |worker_entity| {
                    if (isWorkerIdle(reg, worker_entity)) {
                        // Assign worker to group
                        reg.add(worker_entity, AssignedComponent{ .group = group_entity });
                        reg.add(group_entity, GroupAssignedComponent{ .worker = worker_entity });
                        group.status = .Active;

                        onAssigned(reg, worker_entity, group_entity);
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
/// 1. Resets the group steps
/// 2. Calls `shouldContinue` to check if worker stays assigned
/// 3. If not continuing, releases the worker and calls `onReleased`
///
/// Parameters:
/// - `GroupComponent`: Component type for task groups (must have `status: TaskGroupStatus`, `steps: GroupSteps`)
/// - `AssignedComponent`: Component on worker indicating assignment
/// - `GroupAssignedComponent`: Component on group indicating assigned worker (must have `worker: Entity`)
/// - `shouldContinue`: fn(*Registry, Entity, Entity) bool - returns true if worker should do another cycle
/// - `setWorkerIdle`: fn(*Registry, Entity) void - called to reset worker to idle state
/// - `onReleased`: fn(*Registry, Entity, Entity) void - called when worker is released (worker, group)
pub fn GroupCompletionSystem(
    comptime GroupComponent: type,
    comptime AssignedComponent: type,
    comptime GroupAssignedComponent: type,
    comptime shouldContinue: fn (*Registry, Entity, Entity) bool,
    comptime setWorkerIdle: fn (*Registry, Entity) void,
    comptime onReleased: fn (*Registry, Entity, Entity) void,
) type {
    return struct {
        pub fn run(reg: *Registry) void {
            var view = reg.view(.{ GroupComponent, GroupAssignedComponent }, .{});
            var iter = view.entityIterator();

            while (iter.next()) |group_entity| {
                const group = reg.get(GroupComponent, group_entity);
                if (group.status != .Active) continue;
                if (!group.steps.isComplete()) continue;

                const assigned = reg.get(GroupAssignedComponent, group_entity);
                const worker_entity = assigned.worker;

                // Reset group steps for next cycle
                group.steps.reset();

                // Check if worker should continue
                if (shouldContinue(reg, worker_entity, group_entity)) {
                    // Worker stays assigned, set group to Blocked for resource re-check
                    // BlockedToQueuedSystem will transition back to Queued/Active if resources available
                    group.status = .Blocked;
                } else {
                    // Release worker, group goes back to Blocked
                    group.status = .Blocked;
                    reg.remove(AssignedComponent, worker_entity);
                    reg.remove(GroupAssignedComponent, group_entity);
                    setWorkerIdle(reg, worker_entity);
                    onReleased(reg, worker_entity, group_entity);
                }
            }
        }
    };
}

/// System that processes active task groups by executing their current step.
///
/// For each active group with an assigned worker, calls `processStep` with the current step,
/// then advances to the next step.
///
/// Parameters:
/// - `GroupComponent`: Component type for task groups (must have `status: TaskGroupStatus`, `steps: GroupSteps`)
/// - `GroupAssignedComponent`: Component on group indicating assigned worker (must have `worker: Entity`)
/// - `processStep`: fn(*Registry, Entity, Entity, StepDef) void - called to process step (worker, group, step)
pub fn StepProcessingSystem(
    comptime GroupComponent: type,
    comptime GroupAssignedComponent: type,
    comptime processStep: fn (*Registry, Entity, Entity, StepDef) void,
) type {
    return struct {
        pub fn run(reg: *Registry) void {
            var view = reg.view(.{ GroupComponent, GroupAssignedComponent }, .{});
            var iter = view.entityIterator();

            while (iter.next()) |group_entity| {
                const group = reg.get(GroupComponent, group_entity);
                if (group.status != .Active) continue;

                const assigned = reg.get(GroupAssignedComponent, group_entity);
                const worker_entity = assigned.worker;

                // Process current step if not complete
                if (group.steps.currentStep()) |step| {
                    processStep(reg, worker_entity, group_entity, step);
                    _ = group.steps.advance();
                }
            }
        }
    };
}

// ============================================================================
// Task Runner (event-driven)
// ============================================================================

/// Event-driven task runner using zig-ecs component signals.
///
/// Uses the standard Worker, AssignedToGroup, GroupAssignedWorker, and StepComplete components.
///
/// **Event-driven flow:**
/// 1. Worker assigned → `onAssigned` callback → user starts step (movement, timer, etc.)
/// 2. Step done → user adds `StepComplete` to worker → system advances step
/// 3. All steps done → `GroupCompletionSystem` handles cycle completion
///
/// **tick() only runs:**
/// - BlockedToQueuedSystem (resource availability can change)
/// - WorkerAssignmentSystem (workers become idle)
/// - GroupCompletionSystem (handles completed cycles)
///
/// **No polling for step progress!** Steps advance via StepComplete marker component.
///
/// Parameters:
/// - `GroupComponent`: Component type for task groups
/// - `canUnblock`: fn(*Registry, Entity) bool
/// - `startStep`: fn(*Registry, Entity, Entity, StepDef) void - called when step should begin
/// - `shouldContinue`: fn(*Registry, Entity, Entity) bool
/// - `onReleased`: fn(*Registry, Entity, Entity) void (optional, can be noop)
pub fn TaskRunner(
    comptime GroupComponent: type,
    comptime canUnblock: fn (*Registry, Entity) bool,
    comptime startStep: fn (*Registry, Entity, Entity, StepDef) void,
    comptime shouldContinue: fn (*Registry, Entity, Entity) bool,
    comptime onReleased: fn (*Registry, Entity, Entity) void,
) type {
    return struct {
        const Self = @This();

        // Internal systems using standard components
        const Blocked = BlockedToQueuedSystem(GroupComponent, GroupAssignedWorker, canUnblock);
        const Assignment = WorkerAssignmentSystem(
            GroupComponent,
            Worker,
            AssignedToGroup,
            GroupAssignedWorker,
            isWorkerIdle,
            onWorkerAssigned,
        );

        fn isWorkerIdle(reg: *Registry, entity: Entity) bool {
            const worker = reg.get(Worker, entity);
            return worker.state == .Idle;
        }

        fn onWorkerAssigned(reg: *Registry, worker_entity: Entity, group_entity: Entity) void {
            const worker = reg.get(Worker, worker_entity);
            worker.state = .Working;

            // Start first step immediately
            const group = reg.get(GroupComponent, group_entity);
            if (group.steps.currentStep()) |step| {
                startStep(reg, worker_entity, group_entity, step);
            }
        }

        fn setWorkerIdle(reg: *Registry, worker_entity: Entity) void {
            const worker = reg.get(Worker, worker_entity);
            worker.state = .Idle;
        }

        /// Custom completion system that starts next cycle when worker continues.
        fn handleCompletion(reg: *Registry) void {
            var view = reg.view(.{ GroupComponent, GroupAssignedWorker }, .{});
            var iter = view.entityIterator();

            while (iter.next()) |group_entity| {
                const group = reg.get(GroupComponent, group_entity);
                if (group.status != .Active) continue;
                if (!group.steps.isComplete()) continue;

                const assigned = reg.get(GroupAssignedWorker, group_entity);
                const worker_entity = assigned.worker;

                // Reset group steps for next cycle
                group.steps.reset();

                // Check if worker should continue
                if (shouldContinue(reg, worker_entity, group_entity)) {
                    // Worker stays assigned, start first step of new cycle
                    if (group.steps.currentStep()) |step| {
                        startStep(reg, worker_entity, group_entity, step);
                    }
                } else {
                    // Release worker, group goes back to Blocked
                    group.status = .Blocked;
                    reg.remove(AssignedToGroup, worker_entity);
                    reg.remove(GroupAssignedWorker, group_entity);
                    setWorkerIdle(reg, worker_entity);
                    onReleased(reg, worker_entity, group_entity);
                }
            }
        }

        /// Called when StepComplete component is added to a worker.
        /// Advances to next step or marks group ready for completion.
        fn onStepCompleteAdded(reg: *Registry, worker_entity: Entity) void {
            // Remove the marker immediately
            reg.remove(StepComplete, worker_entity);

            // Get assignment
            const assigned = reg.tryGet(AssignedToGroup, worker_entity);
            if (assigned == null) return;

            const group = reg.get(GroupComponent, assigned.?.group);

            // Advance to next step
            if (group.steps.advance()) {
                // Check if more steps remain
                if (group.steps.currentStep()) |next_step| {
                    startStep(reg, worker_entity, assigned.?.group, next_step);
                }
                // If no more steps (isComplete), runCompletion will handle it
            }
        }

        /// Set up event handlers. Call this once during initialization.
        /// This connects the StepComplete signal to automatically advance steps.
        pub fn setup(reg: *Registry) void {
            reg.onConstruct(StepComplete).connect(onStepCompleteAdded);
        }

        /// Run task systems for one tick (no step polling).
        ///
        /// Only runs:
        /// - BlockedToQueuedSystem (resources may have changed)
        /// - WorkerAssignmentSystem (workers may be idle)
        /// - Completion handling (groups may have finished all steps)
        pub fn tick(reg: *Registry) void {
            Blocked.run(reg);
            Assignment.run(reg);
            handleCompletion(reg);
        }

        /// Signal that a worker has completed their current step.
        /// This triggers the event system to advance to the next step.
        pub fn completeStep(reg: *Registry, worker_entity: Entity) void {
            reg.add(worker_entity, StepComplete{});
        }

        /// Run only the blocked-to-queued transition.
        pub fn runBlocked(reg: *Registry) void {
            Blocked.run(reg);
        }

        /// Run only worker assignment.
        pub fn runAssignment(reg: *Registry) void {
            Assignment.run(reg);
        }

        /// Run only completion handling.
        pub fn runCompletion(reg: *Registry) void {
            handleCompletion(reg);
        }
    };
}

/// No-op callback for when you don't need onReleased.
pub fn noop(reg: *Registry, worker: Entity, group: Entity) void {
    _ = reg;
    _ = worker;
    _ = group;
}
