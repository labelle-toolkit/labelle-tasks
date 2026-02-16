//! ECS bridge vtable implementation for the task engine.
//! Provides type-erased function implementations for the EcsInterface vtable.

const state_mod = @import("state.zig");
const ecs_bridge = @import("ecs_bridge.zig");

/// Creates vtable bridge functions for the engine
pub fn VTableBridge(
    comptime GameId: type,
    comptime Item: type,
    comptime EngineType: type,
) type {
    const StorageRole = state_mod.StorageRole;
    const EcsInterface = ecs_bridge.EcsInterface(GameId, Item);

    return struct {
        pub const vtable = EcsInterface.VTable{
            .addStorage = addStorage,
            .removeStorage = removeStorage,
            .attachStorageToWorkstation = attachStorageToWorkstation,
            .addWorker = addWorker,
            .removeWorker = removeWorker,
            .workerAvailable = workerAvailable,
            .addDanglingItem = addDanglingItem,
            .removeDanglingItem = removeDanglingItem,
            .addWorkstation = addWorkstation,
            .removeWorkstation = removeWorkstation,
        };

        fn addStorage(ptr: *anyopaque, id: GameId, role: StorageRole, initial_item: ?Item, accepts: ?Item) anyerror!void {
            const self: *EngineType = @ptrCast(@alignCast(ptr));
            try self.addStorage(id, .{
                .role = role,
                .initial_item = initial_item,
                .accepts = accepts,
            });
        }

        /// Remove a storage from the engine via the ECS bridge.
        /// Note: callers of reevaluateAffectedWorkstations snapshot the
        /// workstation list before iterating, so this is safe to call
        /// reentrantly during evaluation.
        fn removeStorage(ptr: *anyopaque, id: GameId) void {
            const self: *EngineType = @ptrCast(@alignCast(ptr));
            _ = self.storages.remove(id);
            // Clean up reverse index entry for this storage
            if (self.storage_to_workstations.fetchRemove(id)) |kv| {
                var list = kv.value;
                list.deinit(self.allocator);
            }
        }

        fn attachStorageToWorkstation(ptr: *anyopaque, storage_id: GameId, workstation_id: GameId, role: StorageRole) anyerror!void {
            const self: *EngineType = @ptrCast(@alignCast(ptr));
            try self.attachStorageToWorkstation(storage_id, workstation_id, role);
        }

        fn addWorker(ptr: *anyopaque, id: GameId) anyerror!void {
            const self: *EngineType = @ptrCast(@alignCast(ptr));
            try self.addWorker(id);
        }

        fn removeWorker(ptr: *anyopaque, id: GameId) void {
            const self: *EngineType = @ptrCast(@alignCast(ptr));
            _ = self.handle(.{ .worker_removed = .{ .worker_id = id } });
        }

        fn workerAvailable(ptr: *anyopaque, id: GameId) bool {
            const self: *EngineType = @ptrCast(@alignCast(ptr));
            return self.handle(.{ .worker_available = .{ .worker_id = id } });
        }

        fn addDanglingItem(ptr: *anyopaque, id: GameId, item_type: Item) anyerror!void {
            const self: *EngineType = @ptrCast(@alignCast(ptr));
            try self.addDanglingItem(id, item_type);
        }

        fn removeDanglingItem(ptr: *anyopaque, id: GameId) void {
            const self: *EngineType = @ptrCast(@alignCast(ptr));
            self.removeDanglingItem(id);
        }

        fn addWorkstation(ptr: *anyopaque, id: GameId) anyerror!void {
            const self: *EngineType = @ptrCast(@alignCast(ptr));
            try self.addWorkstation(id, .{});
        }

        fn removeWorkstation(ptr: *anyopaque, id: GameId) void {
            const self: *EngineType = @ptrCast(@alignCast(ptr));
            self.removeWorkstation(id);
        }
    };
}
