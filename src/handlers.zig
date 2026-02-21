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
                engine.evaluateTransports();
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

            // Cancel any transport from this EOS
            if (role == .eos) {
                cancelTransportFromStorage(engine, storage_id);
            }

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

            // First, try to assign worker to pick up dangling items (highest priority)
            engine.evaluateDanglingItems();

            // If worker is still idle, try to assign to a queued workstation
            if (worker.state == .Idle) {
                engine.tryAssignWorkers();
            }

            // If worker is still idle, try EOS transport (lowest priority)
            if (worker.state == .Idle) {
                engine.evaluateTransports();
            }
        }

        pub fn handleWorkerUnavailable(engine: *EngineType, worker_id: GameId) anyerror!void {
            const worker = engine.workers.getPtr(worker_id) orelse {
                log.err("worker_unavailable: unknown worker {}", .{worker_id});
                return error.UnknownWorker;
            };

            // Cancel transport task if active
            if (worker.transport_task) |task| {
                cancelWorkerTransport(engine, worker, worker_id, task);
            }

            // Cancel dangling task if active
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
        }

        pub fn handleWorkerRemoved(engine: *EngineType, worker_id: GameId) anyerror!void {
            if (engine.workers.getPtr(worker_id)) |worker| {
                // Cancel transport task if active
                if (worker.transport_task) |task| {
                    cancelWorkerTransport(engine, worker, worker_id, task);
                }

                // Cancel dangling task if active
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

        // ============================================
        // Transport handlers
        // ============================================

        pub fn handleTransportPickupCompleted(engine: *EngineType, worker_id: GameId) anyerror!void {
            const worker = engine.workers.getPtr(worker_id) orelse {
                log.err("transport_pickup_completed: unknown worker {}", .{worker_id});
                return error.UnknownWorker;
            };

            const task = worker.transport_task orelse {
                log.err("transport_pickup_completed: worker {} has no transport task", .{worker_id});
                return error.NoTransportTask;
            };

            // Read item_type from source storage before clearing it
            const from_storage = engine.storages.getPtr(task.from_storage_id) orelse {
                log.err("transport_pickup_completed: source storage {} not found", .{task.from_storage_id});
                return error.UnknownStorage;
            };

            const item_type = from_storage.item_type orelse {
                log.err("transport_pickup_completed: source storage {} has no item type", .{task.from_storage_id});
                return error.NoItemType;
            };

            // Store the item type for delivery phase
            engine.transport_items.put(worker_id, item_type) catch {
                log.err("transport_pickup_completed: failed to track item for worker {}", .{worker_id});
                return error.OutOfMemory;
            };

            // Clear the source storage
            from_storage.has_item = false;
            from_storage.item_type = null;

            // Source EOS is now empty — re-evaluate workstations that reference it
            engine.reevaluateAffectedWorkstations(task.from_storage_id);
        }

        pub fn handleTransportDeliveryCompleted(engine: *EngineType, worker_id: GameId) anyerror!void {
            const worker = engine.workers.getPtr(worker_id) orelse {
                log.err("transport_delivery_completed: unknown worker {}", .{worker_id});
                return error.UnknownWorker;
            };

            const task = worker.transport_task orelse {
                log.err("transport_delivery_completed: worker {} has no transport task", .{worker_id});
                return error.NoTransportTask;
            };

            const item_type = engine.transport_items.get(worker_id) orelse {
                log.err("transport_delivery_completed: no tracked item for worker {}", .{worker_id});
                return error.NoItemType;
            };

            const dest_storage = engine.storages.getPtr(task.to_storage_id) orelse {
                log.err("transport_delivery_completed: destination storage {} not found", .{task.to_storage_id});
                return error.UnknownStorage;
            };

            // Check if destination is full (race condition)
            if (dest_storage.has_item) {
                log.warn("transport_delivery_completed: destination {} full, attempting re-route", .{task.to_storage_id});

                // Release old reservation
                engine.releaseReservation(task.to_storage_id);

                // Try to find a new destination
                if (engine.findDestinationForItem(item_type)) |new_dest| {
                    // Re-route: update task, reserve new destination, dispatch new transport_started
                    worker.transport_task = .{
                        .from_storage_id = task.from_storage_id,
                        .to_storage_id = new_dest,
                    };
                    engine.reserveStorage(new_dest, worker_id);
                    engine.dispatcher.dispatch(.{ .transport_started = .{
                        .worker_id = worker_id,
                        .from_storage_id = task.from_storage_id,
                        .to_storage_id = new_dest,
                        .item = item_type,
                    } });
                    return;
                }

                // No destination available — cancel transport
                engine.dispatcher.dispatch(.{ .transport_cancelled = .{
                    .worker_id = worker_id,
                    .from_storage_id = task.from_storage_id,
                    .to_storage_id = task.to_storage_id,
                    .item = item_type,
                } });

                worker.transport_task = null;
                _ = engine.transport_items.remove(worker_id);
                worker.state = .Idle;
                engine.markWorkerIdle(worker_id);
                engine.evaluateDanglingItems();
                if (worker.state == .Idle) engine.tryAssignWorkers();
                if (worker.state == .Idle) engine.evaluateTransports();
                return;
            }

            // Destination is empty — deliver
            dest_storage.has_item = true;
            dest_storage.item_type = item_type;

            // Release reservation
            engine.releaseReservation(task.to_storage_id);

            // Dispatch transport_completed
            engine.dispatcher.dispatch(.{ .transport_completed = .{
                .worker_id = worker_id,
                .to_storage_id = task.to_storage_id,
                .item = item_type,
            } });

            // Clean up worker
            worker.transport_task = null;
            _ = engine.transport_items.remove(worker_id);
            worker.state = .Idle;
            engine.markWorkerIdle(worker_id);

            // Re-evaluate: destination may enable a workstation
            engine.reevaluateAffectedWorkstations(task.to_storage_id);

            // Try to assign worker to new tasks
            engine.evaluateDanglingItems();
            if (worker.state == .Idle) engine.tryAssignWorkers();
            if (worker.state == .Idle) engine.evaluateTransports();
        }

        // ============================================
        // Transport cancellation helpers
        // ============================================

        /// Cancel a worker's transport task and dispatch transport_cancelled hook.
        fn cancelWorkerTransport(engine: *EngineType, worker: *WorkerData, worker_id: GameId, task: @TypeOf(worker.transport_task.?)) void {
            const item_type = engine.transport_items.get(worker_id);

            engine.releaseReservation(task.to_storage_id);
            _ = engine.transport_items.remove(worker_id);

            engine.dispatcher.dispatch(.{ .transport_cancelled = .{
                .worker_id = worker_id,
                .from_storage_id = task.from_storage_id,
                .to_storage_id = task.to_storage_id,
                .item = item_type,
            } });

            worker.transport_task = null;
        }

        /// Cancel any transport that uses a given storage as its source.
        fn cancelTransportFromStorage(engine: *EngineType, storage_id: GameId) void {
            // Find worker with transport_task.from_storage_id == storage_id
            var iter = engine.workers.iterator();
            while (iter.next()) |entry| {
                const wid = entry.key_ptr.*;
                const worker = entry.value_ptr;
                if (worker.transport_task) |task| {
                    if (task.from_storage_id == storage_id) {
                        cancelWorkerTransport(engine, worker, wid, task);
                        worker.state = .Idle;
                        engine.markWorkerIdle(wid);
                        // Don't re-evaluate here — caller handles it
                        break; // Only one worker per EOS transport
                    }
                }
            }
        }
    };
}
