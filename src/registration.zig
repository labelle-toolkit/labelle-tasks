//! Registration API for adding/removing entities to the task engine

const std = @import("std");
const state_mod = @import("state.zig");
const types = @import("types.zig");

const Priority = types.Priority;

/// Creates registration functions for the engine
pub fn Registration(
    comptime GameId: type,
    comptime Item: type,
    comptime EngineType: type,
) type {
    return struct {
        // Re-export StorageRole for convenience
        pub const StorageRole = state_mod.StorageRole;

        /// Storage configuration for registration
        pub const StorageConfig = struct {
            role: StorageRole = .eis,
            accepts: ?Item = null, // null = accepts any item type
            initial_item: ?Item = null,
            priority: Priority = .Normal,
        };

        /// Workstation configuration for registration
        pub const WorkstationConfig = struct {
            eis: []const GameId = &.{},
            iis: []const GameId = &.{},
            ios: []const GameId = &.{},
            eos: []const GameId = &.{},
            priority: Priority = .Normal,
        };

        /// Register a storage with the engine
        pub fn addStorage(engine: *EngineType, storage_id: GameId, config: StorageConfig) !void {
            try engine.storages.put(storage_id, .{
                .has_item = config.initial_item != null,
                .item_type = config.initial_item,
                .role = config.role,
                .accepts = config.accepts,
                .priority = config.priority,
            });

            if (config.role == .eis and config.initial_item == null) {
                // Direct evaluation: addStorage is called from outside handle()
                // (component registration), so dirty flags would never be processed.
                engine.evaluateDanglingItems();
            }
        }

        /// Register a worker with the engine
        pub fn addWorker(engine: *EngineType, worker_id: GameId) !void {
            try engine.workers.put(worker_id, .{});
            errdefer _ = engine.workers.remove(worker_id);
            try engine.idle_workers_set.put(worker_id, {});
        }

        /// Register a workstation with the engine
        pub fn addWorkstation(engine: *EngineType, workstation_id: GameId, config: WorkstationConfig) !void {
            var eis = std.ArrayListUnmanaged(GameId){};
            errdefer eis.deinit(engine.allocator);
            try eis.appendSlice(engine.allocator, config.eis);

            var iis = std.ArrayListUnmanaged(GameId){};
            errdefer iis.deinit(engine.allocator);
            try iis.appendSlice(engine.allocator, config.iis);

            var ios = std.ArrayListUnmanaged(GameId){};
            errdefer ios.deinit(engine.allocator);
            try ios.appendSlice(engine.allocator, config.ios);

            var eos = std.ArrayListUnmanaged(GameId){};
            errdefer eos.deinit(engine.allocator);
            try eos.appendSlice(engine.allocator, config.eos);

            try engine.workstations.put(workstation_id, .{
                .eis = eis,
                .iis = iis,
                .ios = ios,
                .eos = eos,
                .priority = config.priority,
            });

            const all_storages = [_][]const GameId{ config.eis, config.iis, config.ios, config.eos };
            for (all_storages) |storage_ids| {
                for (storage_ids) |sid| {
                    engine.addReverseIndexEntry(sid, workstation_id);
                }
            }

            engine.evaluateWorkstationStatus(workstation_id);
        }

        /// Remove a workstation from the engine
        pub fn removeWorkstation(engine: *EngineType, workstation_id: GameId) void {
            if (engine.workstations.getPtr(workstation_id)) |ws| {
                if (ws.assigned_worker) |worker_id| {
                    if (engine.workers.getPtr(worker_id)) |worker| {
                        worker.state = .Idle;
                        worker.assigned_workstation = null;
                        engine.markWorkerIdle(worker_id);
                        engine.dispatcher.dispatch(.{ .worker_released = .{ .worker_id = worker_id } });
                    }
                }
            }
            engine.removeWorkstationTracking(workstation_id);
            if (engine.workstations.fetchRemove(workstation_id)) |kv| {
                const all_storages = [_][]const GameId{ kv.value.eis.items, kv.value.iis.items, kv.value.ios.items, kv.value.eos.items };
                for (all_storages) |storage_ids| {
                    for (storage_ids) |sid| {
                        engine.removeReverseIndexEntry(sid, workstation_id);
                    }
                }
                var ws = kv.value;
                ws.deinit(engine.allocator);
            }
        }

        /// Attach a storage to a workstation dynamically.
        /// This allows storages to register themselves with their parent workstation
        /// using the parent reference convention (RFC #169).
        pub fn attachStorageToWorkstation(engine: *EngineType, storage_id: GameId, workstation_id: GameId, role: StorageRole) !void {
            const ws = engine.workstations.getPtr(workstation_id) orelse {
                std.log.warn("[tasks] attachStorageToWorkstation: workstation {d} not found", .{workstation_id});
                return error.WorkstationNotFound;
            };

            const list = switch (role) {
                .eis => &ws.eis,
                .iis => &ws.iis,
                .ios => &ws.ios,
                .eos => &ws.eos,
                .standalone => {
                    std.log.warn("[tasks] attachStorageToWorkstation: cannot attach standalone storage to workstation", .{});
                    return error.InvalidStorageRole;
                },
            };
            try list.append(engine.allocator, storage_id);

            engine.addReverseIndexEntry(storage_id, workstation_id);
            engine.evaluateWorkstationStatus(workstation_id);
        }

        /// Set the callback for worker selection
        pub fn setFindBestWorker(engine: *EngineType, callback: *const fn (workstation_id: ?GameId, available_workers: []const GameId) ?GameId) void {
            engine.find_best_worker_fn = callback;
        }
    };
}
