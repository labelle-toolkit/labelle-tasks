//! Internal state structs for the task engine

const std = @import("std");
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

/// Maximum number of storages per role in a workstation.
/// Covers up to 16 EIS, 16 IIS, 16 IOS, or 16 EOS per workstation.
pub const MAX_STORAGE_SLOTS = 16;

/// Internal workstation state
pub fn WorkstationData(comptime GameId: type) type {
    const BitSet = std.bit_set.IntegerBitSet(MAX_STORAGE_SLOTS);

    return struct {
        const Self = @This();

        pub const FilledBitSet = BitSet;

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

        // Filled status bitsets (indexed by position in storage arrays)
        // Kept in sync with StorageState.has_item for O(1) aggregate checks
        eis_filled: BitSet = BitSet.initEmpty(),
        iis_filled: BitSet = BitSet.initEmpty(),
        ios_filled: BitSet = BitSet.initEmpty(),
        eos_filled: BitSet = BitSet.initEmpty(),

        // Selected storages for current cycle
        selected_eis: ?GameId = null,
        selected_eos: ?GameId = null,

        pub fn isProducer(self: *const Self) bool {
            return self.eis.len == 0 and self.iis.len == 0;
        }

        /// Check if all IIS are filled
        pub fn allIisFilled(self: *const Self) bool {
            return self.iis_filled.count() == self.iis.len;
        }

        /// Check if all IOS are empty
        pub fn allIosEmpty(self: *const Self) bool {
            return self.ios_filled.count() == 0;
        }

        /// Check if all EIS have items
        pub fn allEisFilled(self: *const Self) bool {
            return self.eis_filled.count() == self.eis.len;
        }

        /// Check if at least one EOS has space
        pub fn hasEosSpace(self: *const Self) bool {
            return self.eos_filled.count() < self.eos.len;
        }

        /// Find the index of a storage ID within a slice
        pub fn storageIndex(slice: []const GameId, storage_id: GameId) ?usize {
            for (slice, 0..) |id, i| {
                if (id == storage_id) return i;
            }
            return null;
        }
    };
}
