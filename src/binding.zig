const workstation = @import("workstation.zig");

pub const Entity = workstation.Entity;
pub const Priority = workstation.Priority;
pub const WorkstationStatus = workstation.WorkstationStatus;
pub const StepType = workstation.StepType;

/// Common binding component for all workstation types.
/// Holds configuration and runtime state.
/// Every entity with a workstation component also gets this binding.
pub const TaskWorkstationBinding = struct {
    // === Configuration (set in prefab/scene) ===

    /// Time in ticks to complete processing
    process_duration: u32 = 0,

    /// Priority for worker assignment
    priority: Priority = .Normal,

    // === Runtime state (managed by task engine) ===

    /// Current workstation status
    status: WorkstationStatus = .Blocked,

    /// Currently assigned worker entity
    assigned_worker: ?Entity = null,

    /// Timer for process step
    process_timer: u32 = 0,

    /// Current step in the cycle
    current_step: StepType = .Pickup,

    /// Which EIS was selected for current cycle (for multi-EIS workstations)
    selected_eis: ?Entity = null,

    /// Which EOS was selected for current cycle (for multi-EOS workstations)
    selected_eos: ?Entity = null,

    /// Number of completed cycles
    cycles_completed: u32 = 0,

    // === Methods ===

    /// Reset runtime state for a new cycle
    pub fn resetCycle(self: *TaskWorkstationBinding) void {
        self.process_timer = 0;
        self.current_step = .Pickup;
        self.selected_eis = null;
        self.selected_eos = null;
    }

    /// Check if workstation is ready to accept a worker
    pub fn canAcceptWorker(self: *const TaskWorkstationBinding) bool {
        return self.status == .Queued and self.assigned_worker == null;
    }

    /// Assign a worker to this workstation
    pub fn assignWorker(self: *TaskWorkstationBinding, worker: Entity) void {
        self.assigned_worker = worker;
        self.status = .Active;
    }

    /// Release the assigned worker
    pub fn releaseWorker(self: *TaskWorkstationBinding) ?Entity {
        const worker = self.assigned_worker;
        self.assigned_worker = null;
        self.status = .Blocked;
        return worker;
    }

    /// Advance to next step in the cycle
    pub fn advanceStep(self: *TaskWorkstationBinding) void {
        self.current_step = switch (self.current_step) {
            .Pickup => .Process,
            .Process => .Store,
            .Store => blk: {
                self.cycles_completed += 1;
                break :blk .Pickup;
            },
        };
    }

    /// Update process timer, returns true if processing completed
    pub fn tickProcess(self: *TaskWorkstationBinding) bool {
        if (self.current_step != .Process) return false;

        self.process_timer += 1;
        if (self.process_timer >= self.process_duration) {
            self.process_timer = 0;
            return true;
        }
        return false;
    }
};

const std = @import("std");

test "TaskWorkstationBinding defaults" {
    const binding = TaskWorkstationBinding{};

    try std.testing.expectEqual(0, binding.process_duration);
    try std.testing.expectEqual(Priority.Normal, binding.priority);
    try std.testing.expectEqual(WorkstationStatus.Blocked, binding.status);
    try std.testing.expectEqual(null, binding.assigned_worker);
}

test "TaskWorkstationBinding worker assignment" {
    var binding = TaskWorkstationBinding{ .status = .Queued };
    const worker = Entity{ .id = 42 };

    try std.testing.expectEqual(true, binding.canAcceptWorker());

    binding.assignWorker(worker);

    try std.testing.expectEqual(false, binding.canAcceptWorker());
    try std.testing.expectEqual(WorkstationStatus.Active, binding.status);
    try std.testing.expectEqual(worker, binding.assigned_worker.?);

    const released = binding.releaseWorker();
    try std.testing.expectEqual(worker, released.?);
    try std.testing.expectEqual(null, binding.assigned_worker);
}

test "TaskWorkstationBinding step advancement" {
    var binding = TaskWorkstationBinding{};

    try std.testing.expectEqual(StepType.Pickup, binding.current_step);
    try std.testing.expectEqual(0, binding.cycles_completed);

    binding.advanceStep();
    try std.testing.expectEqual(StepType.Process, binding.current_step);

    binding.advanceStep();
    try std.testing.expectEqual(StepType.Store, binding.current_step);

    binding.advanceStep();
    try std.testing.expectEqual(StepType.Pickup, binding.current_step);
    try std.testing.expectEqual(1, binding.cycles_completed);
}

test "TaskWorkstationBinding process timer" {
    var binding = TaskWorkstationBinding{
        .process_duration = 3,
        .current_step = .Process,
    };

    try std.testing.expectEqual(false, binding.tickProcess());
    try std.testing.expectEqual(false, binding.tickProcess());
    try std.testing.expectEqual(true, binding.tickProcess());
    try std.testing.expectEqual(0, binding.process_timer);
}
