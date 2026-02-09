//! ECS Bridge for labelle-tasks
//!
//! Provides type-erased interface for tasks components to register with the engine.
//! The active interface is tracked directly on EcsInterface via setActive/getActive.
//!
//! This approach allows labelle-tasks to export components with built-in callbacks
//! without requiring a compile-time dependency on labelle-engine.

const std = @import("std");

/// Type-erased interface for ECS operations.
/// Implemented by games to bridge between tasks components and the task engine.
///
/// Tracks the active interface via a comptime-scoped static pointer (per GameId/Item).
/// Components use `getActive()` to find the current engine interface.
pub fn EcsInterface(comptime GameId: type, comptime Item: type) type {
    return struct {
        ptr: *anyopaque,
        vtable: *const VTable,

        const Self = @This();

        pub const VTable = struct {
            // Context setup (called before first component registration)
            ensureContext: ?*const fn (game_ptr: *anyopaque, registry_ptr: *anyopaque) void = null,

            // Storage operations
            addStorage: *const fn (ptr: *anyopaque, id: GameId, role: StorageRole, initial_item: ?Item, accepts: ?Item) anyerror!void,
            removeStorage: *const fn (ptr: *anyopaque, id: GameId) void,
            attachStorageToWorkstation: *const fn (ptr: *anyopaque, storage_id: GameId, workstation_id: GameId, role: StorageRole) anyerror!void,

            // Worker operations
            addWorker: *const fn (ptr: *anyopaque, id: GameId) anyerror!void,
            removeWorker: *const fn (ptr: *anyopaque, id: GameId) void,
            workerAvailable: *const fn (ptr: *anyopaque, id: GameId) bool,

            // Dangling item operations
            addDanglingItem: *const fn (ptr: *anyopaque, id: GameId, item_type: Item) anyerror!void,
            removeDanglingItem: *const fn (ptr: *anyopaque, id: GameId) void,

            // Workstation operations
            addWorkstation: *const fn (ptr: *anyopaque, id: GameId) anyerror!void,
            removeWorkstation: *const fn (ptr: *anyopaque, id: GameId) void,
        };

        // ============================================
        // Active interface tracking
        // ============================================

        var active: ?Self = null;

        /// Set the active ECS interface for this GameId/Item combination.
        /// Called by engine/context during initialization.
        pub fn setActive(iface: Self) void {
            active = iface;
        }

        /// Get the active ECS interface.
        /// Returns null if not set. Used by components to find the engine.
        pub fn getActive() ?Self {
            return active;
        }

        /// Clear the active interface (for cleanup).
        pub fn clearActive() void {
            active = null;
        }

        // ============================================
        // Convenience methods that delegate to vtable
        // ============================================

        pub fn ensureContext(self: Self, game_ptr: *anyopaque, registry_ptr: *anyopaque) void {
            if (self.vtable.ensureContext) |ensure_fn| {
                ensure_fn(game_ptr, registry_ptr);
            }
        }

        pub fn addStorage(self: Self, id: GameId, role: StorageRole, initial_item: ?Item, accepts: ?Item) !void {
            return self.vtable.addStorage(self.ptr, id, role, initial_item, accepts);
        }

        pub fn removeStorage(self: Self, id: GameId) void {
            self.vtable.removeStorage(self.ptr, id);
        }

        pub fn attachStorageToWorkstation(self: Self, storage_id: GameId, workstation_id: GameId, role: StorageRole) !void {
            return self.vtable.attachStorageToWorkstation(self.ptr, storage_id, workstation_id, role);
        }

        pub fn addWorker(self: Self, id: GameId) !void {
            return self.vtable.addWorker(self.ptr, id);
        }

        pub fn removeWorker(self: Self, id: GameId) void {
            self.vtable.removeWorker(self.ptr, id);
        }

        pub fn workerAvailable(self: Self, id: GameId) bool {
            return self.vtable.workerAvailable(self.ptr, id);
        }

        pub fn addDanglingItem(self: Self, id: GameId, item_type: Item) !void {
            return self.vtable.addDanglingItem(self.ptr, id, item_type);
        }

        pub fn removeDanglingItem(self: Self, id: GameId) void {
            self.vtable.removeDanglingItem(self.ptr, id);
        }

        pub fn addWorkstation(self: Self, id: GameId) !void {
            return self.vtable.addWorkstation(self.ptr, id);
        }

        pub fn removeWorkstation(self: Self, id: GameId) void {
            self.vtable.removeWorkstation(self.ptr, id);
        }
    };
}

/// Storage role in the workflow
pub const StorageRole = @import("state.zig").StorageRole;
