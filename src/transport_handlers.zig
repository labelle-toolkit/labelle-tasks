//! Transport event handlers and cancellation helpers
//! Handles transport_pickup_completed, transport_delivery_completed,
//! and provides cancellation utilities used by lifecycle handlers.

const std = @import("std");
const log = std.log.scoped(.tasks);

const state_mod = @import("state.zig");

/// Creates transport handler functions for the engine
pub fn TransportHandlers(
    comptime GameId: type,
    comptime Item: type,
    comptime EngineType: type,
) type {
    return struct {
        const WorkerData = state_mod.WorkerData(GameId);

        // ============================================
        // Transport event handlers
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
                // Recover: cancel transport so worker doesn't get stuck
                cancelAndReleaseTransport(engine, worker, worker_id, task, null);
                return error.UnknownStorage;
            };

            const item_type = from_storage.item_type orelse {
                log.err("transport_pickup_completed: source storage {} has no item type", .{task.from_storage_id});
                // Recover: cancel transport so worker doesn't get stuck
                cancelAndReleaseTransport(engine, worker, worker_id, task, null);
                return error.NoItemType;
            };

            // Store the item type for delivery phase
            engine.transport_items.put(worker_id, item_type) catch {
                log.err("transport_pickup_completed: failed to track item for worker {}", .{worker_id});
                // Recover: cancel transport so worker doesn't get stuck
                cancelAndReleaseTransport(engine, worker, worker_id, task, null);
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
                // Recover: cancel transport so worker doesn't get stuck
                cancelAndReleaseTransport(engine, worker, worker_id, task, null);
                return error.NoItemType;
            };

            const dest_storage = engine.storages.getPtr(task.to_storage_id) orelse {
                log.err("transport_delivery_completed: destination storage {} not found", .{task.to_storage_id});
                // Recover: cancel transport so worker doesn't get stuck
                cancelAndReleaseTransport(engine, worker, worker_id, task, item_type);
                return error.UnknownStorage;
            };

            // Check if destination is full (race condition)
            if (dest_storage.has_item) {
                log.warn("transport_delivery_completed: destination {} full, attempting re-route", .{task.to_storage_id});

                // Release old reservation
                engine.releaseReservation(task.to_storage_id);

                // Try to find a new destination
                if (engine.findDestinationForItem(item_type)) |new_dest| {
                    // Re-route: worker already has the item, redirect directly to new destination
                    worker.transport_task = .{
                        .from_storage_id = task.to_storage_id,
                        .to_storage_id = new_dest,
                    };
                    engine.reserveStorage(new_dest, worker_id);
                    engine.dispatcher.dispatch(.{ .transport_rerouted = .{
                        .worker_id = worker_id,
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

                releaseTransportWorker(engine, worker, worker_id);
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

            // Re-evaluate: destination may enable a workstation
            engine.reevaluateAffectedWorkstations(task.to_storage_id);

            // Clean up worker and re-evaluate for new tasks
            releaseTransportWorker(engine, worker, worker_id);
        }

        // ============================================
        // Transport worker helpers
        // ============================================

        /// Clear transport state from a worker and defer re-evaluation.
        fn releaseTransportWorker(engine: *EngineType, worker: *WorkerData, worker_id: GameId) void {
            worker.transport_task = null;
            _ = engine.transport_items.remove(worker_id);
            worker.state = .Idle;
            engine.markWorkerIdle(worker_id);
            engine.needs_dangling_eval = true;
            engine.needs_worker_eval = true;
            engine.needs_transport_eval = true;
        }

        // ============================================
        // Transport cancellation helpers
        // ============================================

        /// Cancel a transport, dispatch transport_cancelled, and release the worker to Idle.
        /// Used for error recovery in transport handlers.
        fn cancelAndReleaseTransport(engine: *EngineType, worker: *WorkerData, worker_id: GameId, task: @TypeOf(worker.transport_task.?), item_type: ?Item) void {
            engine.releaseReservation(task.to_storage_id);

            engine.dispatcher.dispatch(.{ .transport_cancelled = .{
                .worker_id = worker_id,
                .from_storage_id = task.from_storage_id,
                .to_storage_id = task.to_storage_id,
                .item = item_type,
            } });

            releaseTransportWorker(engine, worker, worker_id);
        }

        /// Cancel a worker's transport task and dispatch transport_cancelled hook.
        pub fn cancelWorkerTransport(engine: *EngineType, worker: *WorkerData, worker_id: GameId, task: @TypeOf(worker.transport_task.?)) void {
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

        /// Cancel any transport delivering to a given storage.
        /// Re-evaluates the freed worker for other tasks.
        pub fn cancelTransportToStorage(engine: *EngineType, storage_id: GameId) void {
            var found_worker: ?GameId = null;
            var iter = engine.workers.iterator();
            while (iter.next()) |entry| {
                const wid = entry.key_ptr.*;
                const worker = entry.value_ptr;
                if (worker.transport_task) |task| {
                    if (task.to_storage_id == storage_id) {
                        cancelWorkerTransport(engine, worker, wid, task);
                        worker.state = .Idle;
                        engine.markWorkerIdle(wid);
                        found_worker = wid;
                        break;
                    }
                }
            }

            if (found_worker != null) {
                engine.needs_dangling_eval = true;
                engine.needs_worker_eval = true;
                engine.needs_transport_eval = true;
            }
        }

        /// Cancel any dangling delivery targeting a given storage.
        /// Re-evaluates the freed worker for other tasks.
        pub fn cancelDanglingToStorage(engine: *EngineType, storage_id: GameId) void {
            var found_worker: ?GameId = null;
            var iter = engine.workers.iterator();
            while (iter.next()) |entry| {
                const wid = entry.key_ptr.*;
                const worker = entry.value_ptr;
                if (worker.dangling_task) |task| {
                    if (task.target_storage_id == storage_id) {
                        engine.releaseReservation(storage_id);
                        worker.dangling_task = null;
                        worker.state = .Idle;
                        engine.markWorkerIdle(wid);
                        found_worker = wid;
                        break;
                    }
                }
            }

            if (found_worker != null) {
                engine.needs_dangling_eval = true;
                engine.needs_worker_eval = true;
                engine.needs_transport_eval = true;
            }
        }

        /// Cancel any transport that uses a given storage as its source.
        /// Re-evaluates the freed worker for other tasks.
        pub fn cancelTransportFromStorage(engine: *EngineType, storage_id: GameId) void {
            // Find worker with transport_task.from_storage_id == storage_id
            var found_worker: ?GameId = null;
            var iter = engine.workers.iterator();
            while (iter.next()) |entry| {
                const wid = entry.key_ptr.*;
                const worker = entry.value_ptr;
                if (worker.transport_task) |task| {
                    if (task.from_storage_id == storage_id) {
                        cancelWorkerTransport(engine, worker, wid, task);
                        worker.state = .Idle;
                        engine.markWorkerIdle(wid);
                        found_worker = wid;
                        break; // Only one worker per EOS transport
                    }
                }
            }

            // Re-evaluate freed worker for other tasks
            if (found_worker != null) {
                engine.needs_dangling_eval = true;
                engine.needs_worker_eval = true;
                engine.needs_transport_eval = true;
            }
        }
    };
}
