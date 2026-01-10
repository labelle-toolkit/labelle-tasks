//! Internal state structs for the task engine

const types = @import("types.zig");

const WorkerState = types.WorkerState;
const WorkstationStatus = types.WorkstationStatus;
const StepType = types.StepType;
const Priority = types.Priority;
const TargetType = types.TargetType;

/// Storage role in the workflow
pub const StorageRole = enum {
    eis, // External Input Storage (source of raw materials)
    iis, // Internal Input Storage (workstation input buffer)
    ios, // Internal Output Storage (workstation output buffer)
    eos, // External Output Storage (final products)
};

/// Abstract storage state (no entity references)
pub fn StorageState(comptime Item: type) type {
    return struct {
        has_item: bool = false,
        item_type: ?Item = null,
        role: StorageRole = .eis,
        accepts: ?Item = null, // null = accepts any item type
        priority: Priority = .Normal,
    };
}

/// Movement target for worker
pub fn MovingTo(comptime GameId: type) type {
    return struct {
        target: GameId,
        target_type: TargetType,
    };
}

/// Internal worker state
pub fn WorkerData(comptime GameId: type, comptime Item: type) type {
    return struct {
        state: WorkerState = .Idle,
        assigned_workstation: ?GameId = null,

        /// Current movement target (if worker is moving)
        moving_to: ?MovingTo(GameId) = null,

        /// Dangling item delivery task (if worker is delivering a dangling item)
        dangling_task: ?struct {
            item_id: GameId,
            target_eis_id: GameId,
        } = null,

        /// Transport task (if worker is transporting EOS → EIS)
        transport_task: ?struct {
            from_eos_id: GameId,
            to_eis_id: GameId,
            item_type: Item,
        } = null,
    };
}

/// Internal workstation state
pub fn WorkstationData(comptime GameId: type) type {
    return struct {
        const Self = @This();

        status: WorkstationStatus = .Blocked,
        assigned_worker: ?GameId = null,
        current_step: StepType = .Pickup,
        cycles_completed: u32 = 0,
        priority: Priority = .Normal,

        // Storage references (by GameId)
        eis: []const GameId,
        iis: []const GameId,
        ios: []const GameId,
        eos: []const GameId,

        // Selected storages for current cycle
        selected_eis: ?GameId = null,
        selected_eos: ?GameId = null,

        pub fn isProducer(self: *const Self) bool {
            return self.eis.len == 0 and self.iis.len == 0;
        }
    };
}
