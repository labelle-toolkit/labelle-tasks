//! Event handlers for game → task engine communication
//! Handles storage, worker, and workstation lifecycle events.
//! Step completion handlers (pickup/work/store) are in step_handlers.zig.

const std = @import("std");
const log = std.log.scoped(.tasks);

const state_mod = @import("state.zig");

/// Creates handler functions for the engine
pub fn Handlers(
    comptime GameId: type,
    comptime Item: type,
    comptime EngineType: type,
) type {
    return struct {
        const WorkerData = state_mod.WorkerData(GameId);

        // ============================================
        // Storage handlers
        // ============================================

        pub fn handleItemAdded(engine: *EngineType, storage_id: GameId, item: Item) anyerror!void {
            const storage = engine.storages.getPtr(storage_id) orelse {
                log.err("item_added: unknown storage {}", .{storage_id});
                return error.UnknownStorage;
            };

            // Allow setting item_type even if has_item is already true
            // This is needed for IOS where task engine sets has_item=true in workCompleted
            // but game sets item_type via process_completed hook
            if (storage.has_item and storage.item_type != null) {
                log.warn("item_added: storage {} already has item {s}, ignoring", .{ storage_id, @tagName(storage.item_type.?) });
                return error.StorageAlreadyFull;
            }

            storage.has_item = true;
            storage.item_type = item;

            // Re-evaluate only workstations that reference this storage
            engine.reevaluateAffectedWorkstations(storage_id);
        }

        pub fn handleItemRemoved(engine: *EngineType, storage_id: GameId) anyerror!void {
            const storage = engine.storages.getPtr(storage_id) orelse {
                log.err("item_removed: unknown storage {}", .{storage_id});
                return error.UnknownStorage;
            };

            storage.has_item = false;
            storage.item_type = null;

            engine.reevaluateAffectedWorkstations(storage_id);
        }

        pub fn handleStorageCleared(engine: *EngineType, storage_id: GameId) anyerror!void {
            _ = engine.storages.remove(storage_id);
            // Clean up reverse index entry for this storage
            if (engine.storage_to_workstations.fetchRemove(storage_id)) |kv| {
                var list = kv.value;
                list.deinit(engine.allocator);
            }
        }

        // ============================================
        // Worker handlers
        // ============================================

        pub fn handleWorkerAvailable(engine: *EngineType, worker_id: GameId) anyerror!void {
            const worker = engine.workers.getPtr(worker_id) orelse {
                log.err("worker_available: unknown worker {}", .{worker_id});
                return error.UnknownWorker;
            };

            // Guard: if worker is already actively assigned, don't clear the assignment.
            // This can happen if workerAvailable is called redundantly (e.g., onAdd + init script).
            if (worker.state == .Working and worker.assigned_workstation != null) {
                log.debug("worker_available: worker {} already working at ws {}, ignoring", .{ worker_id, worker.assigned_workstation.? });
                return;
            }

            worker.state = .Idle;
            worker.assigned_workstation = null;
            engine.markWorkerIdle(worker_id);

            // First, try to assign worker to pick up dangling items (higher priority)
            engine.evaluateDanglingItems();

            // If worker is still idle, try to assign to a queued workstation
            if (worker.state == .Idle) {
                engine.tryAssignWorkers();
            }
        }

        pub fn handleWorkerUnavailable(engine: *EngineType, worker_id: GameId) anyerror!void {
            const worker = engine.workers.getPtr(worker_id) orelse {
                log.err("worker_unavailable: unknown worker {}", .{worker_id});
                return error.UnknownWorker;
            };

            // If worker was assigned, release from workstation
            if (worker.assigned_workstation) |ws_id| {
                if (engine.workstations.getPtr(ws_id)) |ws| {
                    ws.assigned_worker = null;
                    engine.dispatcher.dispatch(.{ .worker_released = .{ .worker_id = worker_id } });
                    // Re-evaluate: workstation may be Blocked if conditions changed
                    engine.evaluateWorkstationStatus(ws_id);
                }
            }

            worker.state = .Unavailable;
            worker.assigned_workstation = null;
            engine.markWorkerBusy(worker_id);
        }

        pub fn handleWorkerRemoved(engine: *EngineType, worker_id: GameId) anyerror!void {
            if (engine.workers.getPtr(worker_id)) |worker| {
                // Release from workstation first
                if (worker.assigned_workstation) |ws_id| {
                    if (engine.workstations.getPtr(ws_id)) |ws| {
                        ws.assigned_worker = null;
                        engine.evaluateWorkstationStatus(ws_id);
                    }
                }
            }
            engine.removeWorkerTracking(worker_id);
            _ = engine.workers.remove(worker_id);
        }

        // ============================================
        // Workstation handlers
        // ============================================

        pub fn handleWorkstationEnabled(engine: *EngineType, workstation_id: GameId) anyerror!void {
            engine.evaluateWorkstationStatus(workstation_id);
        }

        pub fn handleWorkstationDisabled(engine: *EngineType, workstation_id: GameId) anyerror!void {
            const ws = engine.workstations.getPtr(workstation_id) orelse {
                return error.UnknownWorkstation;
            };

            // Release worker if assigned
            if (ws.assigned_worker) |worker_id| {
                if (engine.workers.getPtr(worker_id)) |worker| {
                    worker.state = .Idle;
                    worker.assigned_workstation = null;
                    engine.markWorkerIdle(worker_id);
                    engine.dispatcher.dispatch(.{ .worker_released = .{ .worker_id = worker_id } });
                }
            }

            ws.status = .Blocked;
            ws.assigned_worker = null;
            engine.markWorkstationNotQueued(workstation_id);
            engine.dispatcher.dispatch(.{ .workstation_blocked = .{ .workstation_id = workstation_id } });
        }

        pub fn handleWorkstationRemoved(engine: *EngineType, workstation_id: GameId) anyerror!void {
            // Release worker if assigned (before removing workstation)
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
            // Delegate to removeWorkstation which handles reverse index cleanup and memory freeing
            engine.removeWorkstation(workstation_id);
        }
    };
}
