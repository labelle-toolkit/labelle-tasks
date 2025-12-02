//! labelle-tasks: ECS task/job queue system for Zig games
//!
//! A fully event-driven task/job queue system designed for game AI, worker management,
//! and job assignment. Built to integrate with zig-ecs.
//!
//! **No polling!** All state transitions happen via zig-ecs component signals:
//! - `ResourcesAvailable` on group → transitions Blocked → Queued, triggers assignment
//! - `WorkerBecameIdle` on worker → attempts to assign to a queued group
//! - `GroupNeedsWorker` on group → attempts to assign an idle worker
//! - `StepComplete` on worker → advances to next step

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

// ============================================================================
// Event Marker Components
// ============================================================================

/// Marker component: add to worker when current step is complete.
/// The event system will react to this, advance the step, and remove the marker.
pub const StepComplete = struct {};

/// Marker component: add to group when its resources become available.
/// The event system will react to this, transition Blocked → Queued, and remove the marker.
/// This allows resource systems to trigger unblocking without polling.
pub const ResourcesAvailable = struct {};

/// Marker component: add to worker when they become idle/available.
/// The event system will react to this and attempt to assign them to a queued group.
/// This avoids polling all workers every tick.
pub const WorkerBecameIdle = struct {};

/// Marker component: add to group when it becomes ready for worker assignment.
/// The event system will react to this and attempt to assign an idle worker.
/// This avoids polling all groups every tick.
pub const GroupNeedsWorker = struct {};

// ============================================================================
// Task Runner (fully event-driven)
// ============================================================================

/// Fully event-driven task runner with NO polling.
///
/// Uses zig-ecs component signals to react to state changes:
///
/// **Event triggers:**
/// - `ResourcesAvailable` on group → transitions Blocked → Queued, triggers assignment
/// - `WorkerBecameIdle` on worker → attempts to assign to a queued group
/// - `GroupNeedsWorker` on group → attempts to assign an idle worker
/// - `StepComplete` on worker → advances to next step
///
/// **Usage:**
/// 1. Call `setup(reg)` once at init to connect all signals
/// 2. When resources become available: `signalResourcesAvailable(reg, group)`
/// 3. When worker finishes fighting/sleeping: `signalWorkerIdle(reg, worker)`
/// 4. When step work completes: `completeStep(reg, worker)`
///
/// **No tick() needed!** All state transitions happen via signals.
/// The tick() method is provided but does nothing - you can remove it from your game loop.
///
/// Parameters:
/// - `GroupComponent`: Component type for task groups (must have `status: TaskGroupStatus`, `steps: GroupSteps`)
/// - `startStep`: fn(*Registry, Entity, Entity, StepDef) void - called when step should begin
/// - `shouldContinue`: fn(*Registry, Entity, Entity) bool - returns true if worker should do another cycle
/// - `onReleased`: fn(*Registry, Entity, Entity) void - called when worker is released (optional, can be noop)
pub fn TaskRunner(
    comptime GroupComponent: type,
    comptime startStep: fn (*Registry, Entity, Entity, StepDef) void,
    comptime shouldContinue: fn (*Registry, Entity, Entity) bool,
    comptime onReleased: fn (*Registry, Entity, Entity) void,
) type {
    return struct {
        const Self = @This();

        fn isWorkerIdle(reg: *Registry, entity: Entity) bool {
            const worker = reg.get(Worker, entity);
            return worker.state == .Idle;
        }

        fn assignWorkerToGroup(reg: *Registry, worker_entity: Entity, group_entity: Entity) void {
            const worker = reg.get(Worker, worker_entity);
            const group = reg.get(GroupComponent, group_entity);

            // Add assignment components
            reg.add(worker_entity, AssignedToGroup{ .group = group_entity });
            reg.add(group_entity, GroupAssignedWorker{ .worker = worker_entity });

            // Update states
            worker.state = .Working;
            group.status = .Active;

            // Start first step
            if (group.steps.currentStep()) |step| {
                startStep(reg, worker_entity, group_entity, step);
            }
        }

        fn findAndAssignWorker(reg: *Registry, group_entity: Entity) bool {
            // Find an idle worker without assignment
            var worker_view = reg.view(.{Worker}, .{AssignedToGroup});
            var worker_iter = worker_view.entityIterator();

            while (worker_iter.next()) |worker_entity| {
                if (isWorkerIdle(reg, worker_entity)) {
                    assignWorkerToGroup(reg, worker_entity, group_entity);
                    return true;
                }
            }
            return false;
        }

        fn findAndAssignGroup(reg: *Registry, worker_entity: Entity) bool {
            // Find a queued group without worker
            var group_view = reg.view(.{GroupComponent}, .{GroupAssignedWorker});
            var group_iter = group_view.entityIterator();

            while (group_iter.next()) |group_entity| {
                const group = reg.get(GroupComponent, group_entity);
                if (group.status == .Queued) {
                    assignWorkerToGroup(reg, worker_entity, group_entity);
                    return true;
                }
            }
            return false;
        }

        /// Called when ResourcesAvailable is added to a group.
        fn onResourcesAvailable(reg: *Registry, group_entity: Entity) void {
            // Remove marker immediately
            reg.remove(ResourcesAvailable, group_entity);

            const group = reg.tryGet(GroupComponent, group_entity);
            if (group == null) return;
            if (group.?.status != .Blocked) return;

            // Check if group already has a worker (continuing cycle)
            const has_worker = reg.tryGet(GroupAssignedWorker, group_entity) != null;
            if (has_worker) {
                // Worker already assigned, go directly to Active and start step
                group.?.status = .Active;
                const assigned = reg.get(GroupAssignedWorker, group_entity);
                if (group.?.steps.currentStep()) |step| {
                    startStep(reg, assigned.worker, group_entity, step);
                }
            } else {
                // Need a worker - try to find one immediately
                group.?.status = .Queued;
                if (!findAndAssignWorker(reg, group_entity)) {
                    // No worker available, add GroupNeedsWorker for future matching
                    // (but don't add if already has it to avoid duplicate signals)
                    if (!reg.has(GroupNeedsWorker, group_entity)) {
                        reg.add(group_entity, GroupNeedsWorker{});
                    }
                }
            }
        }

        /// Called when WorkerBecameIdle is added to a worker.
        fn onWorkerBecameIdle(reg: *Registry, worker_entity: Entity) void {
            // Remove marker immediately
            reg.remove(WorkerBecameIdle, worker_entity);

            const worker = reg.tryGet(Worker, worker_entity);
            if (worker == null) return;
            if (worker.?.state != .Idle) return;

            // Already assigned? Nothing to do
            if (reg.tryGet(AssignedToGroup, worker_entity) != null) return;

            // Try to find a group that needs a worker
            _ = findAndAssignGroup(reg, worker_entity);
        }

        /// Called when GroupNeedsWorker is added to a group.
        fn onGroupNeedsWorker(reg: *Registry, group_entity: Entity) void {
            // Remove marker immediately
            reg.remove(GroupNeedsWorker, group_entity);

            const group = reg.tryGet(GroupComponent, group_entity);
            if (group == null) return;
            if (group.?.status != .Queued) return;

            // Already has worker? Nothing to do
            if (reg.tryGet(GroupAssignedWorker, group_entity) != null) return;

            // Try to find an idle worker
            _ = findAndAssignWorker(reg, group_entity);
        }

        /// Called when StepComplete is added to a worker.
        fn onStepComplete(reg: *Registry, worker_entity: Entity) void {
            // Remove marker immediately
            reg.remove(StepComplete, worker_entity);

            const assigned = reg.tryGet(AssignedToGroup, worker_entity);
            if (assigned == null) return;

            const group_entity = assigned.?.group;
            const group = reg.get(GroupComponent, group_entity);

            // Advance to next step
            if (group.steps.advance()) {
                if (group.steps.currentStep()) |next_step| {
                    // More steps - start next one
                    startStep(reg, worker_entity, group_entity, next_step);
                } else {
                    // All steps complete - handle cycle completion
                    handleCycleComplete(reg, worker_entity, group_entity);
                }
            }
        }

        fn handleCycleComplete(reg: *Registry, worker_entity: Entity, group_entity: Entity) void {
            const group = reg.get(GroupComponent, group_entity);
            const worker = reg.get(Worker, worker_entity);

            // Reset steps for potential next cycle
            group.steps.reset();

            if (shouldContinue(reg, worker_entity, group_entity)) {
                // Worker continues - group goes to Blocked waiting for resources
                // User code should call signalResourcesAvailable when ready
                group.status = .Blocked;
            } else {
                // Worker released
                group.status = .Blocked;
                reg.remove(AssignedToGroup, worker_entity);
                reg.remove(GroupAssignedWorker, group_entity);
                worker.state = .Idle;
                onReleased(reg, worker_entity, group_entity);

                // Worker is now idle - signal so they can be assigned to another group
                reg.add(worker_entity, WorkerBecameIdle{});
            }
        }

        /// Set up all event handlers. Call this once during initialization.
        pub fn setup(reg: *Registry) void {
            reg.onConstruct(ResourcesAvailable).connect(onResourcesAvailable);
            reg.onConstruct(WorkerBecameIdle).connect(onWorkerBecameIdle);
            reg.onConstruct(GroupNeedsWorker).connect(onGroupNeedsWorker);
            reg.onConstruct(StepComplete).connect(onStepComplete);
        }

        /// tick() is a no-op - all state transitions happen via signals.
        /// Kept for API compatibility - you can remove this call from your game loop.
        pub fn tick(reg: *Registry) void {
            _ = reg;
            // No polling! Everything is event-driven.
        }

        // ====================================================================
        // Public signal helpers - call these to trigger state transitions
        // ====================================================================

        /// Signal that a group's resources are now available.
        /// Call this when the conditions for unblocking are met (e.g., ingredients available).
        pub fn signalResourcesAvailable(reg: *Registry, group_entity: Entity) void {
            reg.add(group_entity, ResourcesAvailable{});
        }

        /// Signal that a worker has become idle and available for work.
        /// Call this when a worker finishes fighting, sleeping, eating, etc.
        pub fn signalWorkerIdle(reg: *Registry, worker_entity: Entity) void {
            reg.add(worker_entity, WorkerBecameIdle{});
        }

        /// Signal that a worker has completed their current step.
        /// Call this when movement completes, timer expires, animation finishes, etc.
        pub fn completeStep(reg: *Registry, worker_entity: Entity) void {
            reg.add(worker_entity, StepComplete{});
        }

        /// Signal that a group needs a worker assigned.
        /// Typically called internally, but can be used to re-trigger assignment.
        pub fn signalGroupNeedsWorker(reg: *Registry, group_entity: Entity) void {
            reg.add(group_entity, GroupNeedsWorker{});
        }
    };
}

/// No-op callback for when you don't need onReleased.
pub fn noop(reg: *Registry, worker: Entity, group: Entity) void {
    _ = reg;
    _ = worker;
    _ = group;
}
