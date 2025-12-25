//! Storage management for labelle-tasks
//!
//! Storages are entities that define what item type they accept.
//! Each workstation references four types of storages:
//! - EIS (External Input Storage): Items received from outside
//! - IIS (Internal Input Storage): Recipe requirements (consumed per cycle)
//! - IOS (Internal Output Storage): Production output (produced per cycle)
//! - EOS (External Output Storage): Output buffer for finished items
//!
//! Item can be any type (enum, union, etc.) that supports equality comparison.

const std = @import("std");
const log_mod = @import("log.zig");

/// Storage parameterized by game's entity ID and Item types.
/// Item can be an enum or a tagged union for flexible item type systems.
pub fn Storage(comptime GameId: type, comptime Item: type) type {
    return struct {
        const Self = @This();

        game_id: GameId,
        /// The item type this storage holds
        item: Item,

        // Logging helpers
        fn fmtGameId(id: GameId) u64 {
            return log_mod.fmtGameId(GameId, id);
        }

        fn fmtItem(i: Item) []const u8 {
            return log_mod.fmtItem(Item, i);
        }

        pub fn deinit(self: *Self) void {
            _ = self;
        }

        /// Check if this storage holds the given item type
        pub fn isAllowed(self: *const Self, item: Item) bool {
            return std.meta.eql(self.item, item);
        }
    };
}
