//! Internal state structs for the task engine

const types = @import("types.zig");

const WorkerState = types.WorkerState;
const WorkstationStatus = types.WorkstationStatus;
const StepType = types.StepType;
const Priority = types.Priority;

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

/// Internal worker state
pub fn WorkerData(comptime GameId: type) type {
    return struct {
        state: WorkerState = .Idle,
        assigned_workstation: ?GameId = null,

        /// Dangling item delivery task (if worker is delivering a dangling item)
        dangling_task: ?struct {
            item_id: GameId,
            target_eis_id: GameId,
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
