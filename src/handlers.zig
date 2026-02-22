//! Event handlers for game → task engine communication
//! Handles storage, worker, and workstation lifecycle events.
//! Step completion handlers (pickup/work/store) are in step_handlers.zig.
//! Transport handlers (pickup/delivery) are in transport_handlers.zig.

const std = @import("std");
const log = std.log.scoped(.tasks);

const state_mod = @import("state.zig");
const transport_handlers_mod = @import("transport_handlers.zig");

/// Creates handler functions for the engine
pub fn Handlers(
    comptime GameId: type,
    comptime Item: type,
    comptime EngineType: type,
) type {
    return struct {
        const WorkerData = state_mod.WorkerData(GameId);
        const TransportHelpers = transport_handlers_mod.TransportHandlers(GameId, Item, EngineType);

        // Re-export transport handler functions for engine dispatch
        pub const handleTransportPickupCompleted = TransportHelpers.handleTransportPickupCompleted;
        pub const handleTransportDeliveryCompleted = TransportHelpers.handleTransportDeliveryCompleted;

        // Re-export cancellation helpers used by lifecycle handlers
        const cancelWorkerTransport = TransportHelpers.cancelWorkerTransport;
        const cancelTransportFromStorage = TransportHelpers.cancelTransportFromStorage;
        const cancelTransportToStorage = TransportHelpers.cancelTransportToStorage;
        const cancelDanglingToStorage = TransportHelpers.cancelDanglingToStorage;

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

            // Standalone storage hook
            if (storage.role == .standalone) {
                engine.dispatcher.dispatch(.{ .standalone_item_added = .{
                    .storage_id = storage_id,
                    .item = item,
                } });
            }

            // Re-evaluate only workstations that reference this storage
            engine.reevaluateAffectedWorkstations(storage_id);

            // If an EOS just got an item, try to transport it
            if (storage.role == .eos) {
                engine.needs_transport_eval = true;
            }
        }

        pub fn handleItemRemoved(engine: *EngineType, storage_id: GameId) anyerror!void {
            const storage = engine.storages.getPtr(storage_id) orelse {
                log.err("item_removed: unknown storage {}", .{storage_id});
                return error.UnknownStorage;
            };

            const role = storage.role;

            storage.has_item = false;
            storage.item_type = null;

            // Standalone storage hook
            if (role == .standalone) {
                engine.dispatcher.dispatch(.{ .standalone_item_removed = .{
                    .storage_id = storage_id,
                } });
            }

            // Cancel any transport from this EOS and re-evaluate freed worker
            if (role == .eos) {
                cancelTransportFromStorage(engine, storage_id);
            }

            engine.reevaluateAffectedWorkstations(storage_id);

            // If an EIS or standalone just became empty, EOS items may now have a destination
            if (role == .eis or role == .standalone) {
                engine.needs_transport_eval = true;
            }
        }

        pub fn handleStorageCleared(engine: *EngineType, storage_id: GameId) anyerror!void {
            // Cancel any transport sourcing from this storage
            cancelTransportFromStorage(engine, storage_id);

            // Cancel any transport delivering to this storage
            cancelTransportToStorage(engine, storage_id);

            // Cancel any dangling delivery targeting this storage
            cancelDanglingToStorage(engine, storage_id);

            // Release any reservation on this storage
            engine.releaseReservation(storage_id);

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

            // Defer all evaluations — processDeferredEvaluations handles priority order
            engine.needs_dangling_eval = true;
            engine.needs_worker_eval = true;
            engine.needs_transport_eval = true;
        }

        pub fn handleWorkerUnavailable(engine: *EngineType, worker_id: GameId) anyerror!void {
            const worker = engine.workers.getPtr(worker_id) orelse {
                log.err("worker_unavailable: unknown worker {}", .{worker_id});
                return error.UnknownWorker;
            };

            // Cancel transport task if active (EOS item may need a new worker)
            const had_transport = worker.transport_task != null;
            if (worker.transport_task) |task| {
                cancelWorkerTransport(engine, worker, worker_id, task);
            }

            // Cancel dangling task if active (item needs reassignment)
            const had_dangling = worker.dangling_task != null;
            if (worker.dangling_task) |_| {
                engine.releaseWorkerReservations(worker_id);
                worker.dangling_task = null;
            }

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

            // Re-evaluate orphaned tasks so other workers can pick them up
            if (had_dangling) {
                engine.needs_dangling_eval = true;
            }
            if (had_transport) {
                engine.needs_transport_eval = true;
            }
        }

        pub fn handleWorkerRemoved(engine: *EngineType, worker_id: GameId) anyerror!void {
            var had_transport = false;
            var had_dangling = false;
            if (engine.workers.getPtr(worker_id)) |worker| {
                // Cancel transport task if active (EOS item may need a new worker)
                had_transport = worker.transport_task != null;
                if (worker.transport_task) |task| {
                    cancelWorkerTransport(engine, worker, worker_id, task);
                }

                // Cancel dangling task if active (item needs reassignment)
                had_dangling = worker.dangling_task != null;
                if (worker.dangling_task) |_| {
                    engine.releaseWorkerReservations(worker_id);
                    worker.dangling_task = null;
                }

                // Release from workstation first
                if (worker.assigned_workstation) |ws_id| {
                    if (engine.workstations.getPtr(ws_id)) |ws| {
                        ws.assigned_worker = null;
                        engine.evaluateWorkstationStatus(ws_id);
                    }
                }
            }
            engine.releaseWorkerReservations(worker_id);
            _ = engine.transport_items.remove(worker_id);
            engine.removeWorkerTracking(worker_id);
            _ = engine.workers.remove(worker_id);

            // Re-evaluate orphaned tasks so other workers can pick them up
            if (had_dangling) {
                engine.needs_dangling_eval = true;
            }
            if (had_transport) {
                engine.needs_transport_eval = true;
            }
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
