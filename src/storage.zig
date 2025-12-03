//! Storage management for labelle-tasks
//!
//! Storages are entities that hold items. Each workstation references
//! four types of storages:
//! - EIS (External Input Storage): Items received from outside
//! - IIS (Internal Input Storage): Recipe requirements (consumed per cycle)
//! - IOS (Internal Output Storage): Production output (produced per cycle)
//! - EOS (External Output Storage): Output buffer for finished items
//!
//! IIS capacity defines the input recipe.
//! IOS capacity defines the output recipe.

const std = @import("std");
const log_mod = @import("log.zig");
const log = log_mod.storage;

/// Storage management parameterized by game's entity ID and Item types.
pub fn Storage(comptime GameId: type, comptime Item: type) type {
    return struct {
        const Self = @This();

        /// A slot defines capacity for a specific item type
        pub const Slot = struct {
            item: Item,
            capacity: u32,
        };

        /// Configuration for creating a storage
        pub const Config = struct {
            slots: []const Slot,
        };

        /// Internal storage data
        pub const Data = struct {
            game_id: GameId,
            slots: []const Slot,
            /// Current quantities for each slot (same order as slots)
            quantities: []u32,
            allocator: std.mem.Allocator,

            // Logging helpers
            fn fmtGameId(id: GameId) u64 {
                return log_mod.fmtGameId(GameId, id);
            }

            fn fmtItem(item: Item) []const u8 {
                return log_mod.fmtItem(Item, item);
            }

            pub fn deinit(self: *Data) void {
                self.allocator.free(self.quantities);
            }

            /// Get current quantity of an item
            pub fn getQuantity(self: *const Data, item: Item) u32 {
                for (self.slots, 0..) |slot, i| {
                    if (slot.item == item) {
                        return self.quantities[i];
                    }
                }
                return 0;
            }

            /// Get capacity for an item
            pub fn getCapacity(self: *const Data, item: Item) u32 {
                for (self.slots) |slot| {
                    if (slot.item == item) {
                        return slot.capacity;
                    }
                }
                return 0;
            }

            /// Get available space for an item
            pub fn getAvailableSpace(self: *const Data, item: Item) u32 {
                for (self.slots, 0..) |slot, i| {
                    if (slot.item == item) {
                        return slot.capacity - self.quantities[i];
                    }
                }
                return 0;
            }

            /// Check if storage has at least the given quantity of an item
            pub fn hasAtLeast(self: *const Data, item: Item, quantity: u32) bool {
                return self.getQuantity(item) >= quantity;
            }

            /// Check if storage has space for at least the given quantity of an item
            pub fn hasSpaceFor(self: *const Data, item: Item, quantity: u32) bool {
                return self.getAvailableSpace(item) >= quantity;
            }

            /// Check if storage is full for a specific item
            pub fn isFull(self: *const Data, item: Item) bool {
                return self.getAvailableSpace(item) == 0;
            }

            /// Check if storage is empty for a specific item
            pub fn isEmpty(self: *const Data, item: Item) bool {
                return self.getQuantity(item) == 0;
            }

            /// Add items to storage. Returns actual amount added (may be less if not enough space).
            pub fn add(self: *Data, item: Item, quantity: u32) u32 {
                for (self.slots, 0..) |slot, i| {
                    if (slot.item == item) {
                        const available = slot.capacity - self.quantities[i];
                        const to_add = @min(quantity, available);
                        self.quantities[i] += to_add;
                        if (to_add > 0) {
                            log.debug("storage add: storage={d}, item={s}, added={d}, new_qty={d}/{d}", .{
                                fmtGameId(self.game_id),
                                fmtItem(item),
                                to_add,
                                self.quantities[i],
                                slot.capacity,
                            });
                        }
                        return to_add;
                    }
                }
                return 0;
            }

            /// Remove items from storage. Returns actual amount removed (may be less if not enough).
            pub fn remove(self: *Data, item: Item, quantity: u32) u32 {
                for (self.slots, 0..) |slot, i| {
                    if (slot.item == item) {
                        const to_remove = @min(quantity, self.quantities[i]);
                        self.quantities[i] -= to_remove;
                        if (to_remove > 0) {
                            log.debug("storage remove: storage={d}, item={s}, removed={d}, new_qty={d}/{d}", .{
                                fmtGameId(self.game_id),
                                fmtItem(item),
                                to_remove,
                                self.quantities[i],
                                slot.capacity,
                            });
                        }
                        return to_remove;
                    }
                }
                return 0;
            }

            /// Check if this storage can fulfill the recipe defined by another storage's slots
            /// (used to check if EIS has enough for IIS recipe)
            pub fn canFulfillRecipe(self: *const Data, recipe_slots: []const Slot) bool {
                for (recipe_slots) |recipe_slot| {
                    if (!self.hasAtLeast(recipe_slot.item, recipe_slot.capacity)) {
                        return false;
                    }
                }
                return true;
            }

            /// Check if this storage has space for the output defined by another storage's slots
            /// (used to check if EOS has space for IOS output)
            pub fn hasSpaceForOutput(self: *const Data, output_slots: []const Slot) bool {
                for (output_slots) |output_slot| {
                    if (!self.hasSpaceFor(output_slot.item, output_slot.capacity)) {
                        return false;
                    }
                }
                return true;
            }

            /// Transfer recipe from this storage to target storage
            /// (used for EIS -> IIS transfer)
            pub fn transferRecipeTo(self: *Data, target: *Data, recipe_slots: []const Slot) bool {
                // First verify we have everything
                if (!self.canFulfillRecipe(recipe_slots)) {
                    return false;
                }

                log.debug("storage transfer: from={d}, to={d}", .{
                    fmtGameId(self.game_id),
                    fmtGameId(target.game_id),
                });

                // Transfer each item
                for (recipe_slots) |recipe_slot| {
                    const removed = self.remove(recipe_slot.item, recipe_slot.capacity);
                    _ = target.add(recipe_slot.item, removed);
                }
                return true;
            }

            /// Clear all quantities (consume IIS after processing)
            pub fn clear(self: *Data) void {
                for (self.quantities) |*q| {
                    q.* = 0;
                }
            }

            /// Fill to capacity based on slots (produce IOS output)
            pub fn fillToCapacity(self: *Data) void {
                for (self.slots, 0..) |slot, i| {
                    self.quantities[i] = slot.capacity;
                }
            }
        };
    };
}
