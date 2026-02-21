//! Step completion handlers for the workstation workflow cycle
//! Handles pickup_completed, work_completed, and store_completed events

const std = @import("std");
const log = std.log.scoped(.tasks);

const state_mod = @import("state.zig");

/// Creates step completion handler functions for the engine
pub fn StepHandlers(
    comptime GameId: type,
    comptime Item: type,
    comptime EngineType: type,
) type {
    return struct {
        const WorkerData = state_mod.WorkerData(GameId);

        /// Helper function to recover worker state when a dangling item no longer exists
        fn recoverWorkerFromMissingDanglingItem(engine: *EngineType, worker: *WorkerData, worker_id: GameId) void {
            worker.dangling_task = null;
            worker.state = .Idle;
            engine.markWorkerIdle(worker_id);
            // Try to assign new task
            engine.evaluateDanglingItems();
            if (worker.state == .Idle) {
                engine.tryAssignWorkers();
            }
        }

        pub fn handlePickupCompleted(engine: *EngineType, worker_id: GameId) anyerror!void {
            const worker = engine.workers.getPtr(worker_id) orelse {
                log.err("pickup_completed: unknown worker {}", .{worker_id});
                return error.UnknownWorker;
            };

            // Handle dangling item delivery
            if (worker.dangling_task) |task| {
                const item_type = engine.dangling_items.get(task.item_id) orelse {
                    log.err("pickup_completed: dangling item {} no longer exists", .{task.item_id});
                    // BUG FIX: Clean up worker state so it doesn't get stuck
                    recoverWorkerFromMissingDanglingItem(engine, worker, worker_id);
                    return error.DanglingItemNotFound;
                };

                // Dispatch store_started to move worker to EIS
                engine.dispatcher.dispatch(.{ .store_started = .{
                    .worker_id = worker_id,
                    .storage_id = task.target_storage_id,
                    .item = item_type,
                } });
                return;
            }

            const ws_id = worker.assigned_workstation orelse {
                log.err("pickup_completed: worker {} not assigned to workstation", .{worker_id});
                return error.WorkerNotAssigned;
            };

            const ws = engine.workstations.getPtr(ws_id) orelse {
                log.err("pickup_completed: unknown workstation {}", .{ws_id});
                return error.UnknownWorkstation;
            };

            if (ws.current_step != .Pickup) {
                log.err("pickup_completed: workstation {} not in Pickup step", .{ws_id});
                return error.InvalidStep;
            }

            // Update abstract state: item moved from EIS to IIS
            if (ws.selected_eis) |eis_id| {
                if (engine.storages.getPtr(eis_id)) |eis_storage| {
                    const item = eis_storage.item_type;

                    // Clear EIS
                    eis_storage.has_item = false;
                    eis_storage.item_type = null;

                    // Fill first empty IIS
                    for (ws.iis.items) |iis_id| {
                        if (engine.storages.getPtr(iis_id)) |iis_storage| {
                            if (!iis_storage.has_item) {
                                iis_storage.has_item = true;
                                iis_storage.item_type = item;
                                break;
                            }
                        }
                    }
                }

                // EIS is now free — check if idle workers can deliver dangling items to it
                engine.evaluateDanglingItems();
            }

            // Check if all IIS are filled
            var iis_filled_count: usize = 0;
            var iis_total_count: usize = 0;
            for (ws.iis.items) |iis_id| {
                iis_total_count += 1;
                if (engine.storages.get(iis_id)) |iis_storage| {
                    if (iis_storage.has_item) {
                        iis_filled_count += 1;
                    }
                }
            }

            // Only process if ALL IIS are filled
            // For non-producers, require at least 1 IIS and all must be filled
            const can_process = if (ws.isProducer())
                true
            else
                (iis_total_count > 0 and iis_filled_count == iis_total_count);

            if (can_process) {
                // Move to Process step
                ws.current_step = .Process;
                engine.dispatcher.dispatch(.{ .process_started = .{
                    .workstation_id = ws_id,
                    .worker_id = worker_id,
                } });
            } else {
                // Need more pickups - select next EIS
                ws.selected_eis = engine.selectEis(ws_id);
                if (ws.selected_eis) |eis_id| {
                    const item = engine.storages.get(eis_id).?.item_type.?;
                    engine.dispatcher.dispatch(.{ .pickup_started = .{
                        .worker_id = worker_id,
                        .storage_id = eis_id,
                        .item = item,
                    } });
                }
            }
        }

        pub fn handleWorkCompleted(engine: *EngineType, workstation_id: GameId) anyerror!void {
            const ws = engine.workstations.getPtr(workstation_id) orelse {
                log.err("work_completed: unknown workstation {}", .{workstation_id});
                return error.UnknownWorkstation;
            };

            if (ws.current_step != .Process) {
                log.err("work_completed: workstation {} not in Process step", .{workstation_id});
                return error.InvalidStep;
            }

            const worker_id = ws.assigned_worker orelse {
                log.err("work_completed: workstation {} has no assigned worker", .{workstation_id});
                return error.NoAssignedWorker;
            };

            // Update abstract state: IIS → IOS transformation
            // Emit input_consumed for each IIS item, then clear
            for (ws.iis.items) |iis_id| {
                if (engine.storages.getPtr(iis_id)) |storage| {
                    if (storage.has_item) {
                        if (storage.item_type) |item| {
                            engine.dispatcher.dispatch(.{ .input_consumed = .{
                                .workstation_id = workstation_id,
                                .storage_id = iis_id,
                                .item = item,
                            } });
                        }
                    }
                    storage.has_item = false;
                    storage.item_type = null;
                }
            }

            // Fill all IOS (game determines actual output items via process_completed hook)
            // For now, we just mark them as having items - game will set the actual entity
            for (ws.ios.items) |ios_id| {
                if (engine.storages.getPtr(ios_id)) |storage| {
                    storage.has_item = true;
                    // item_type will be set by game via item_added or left for game to track
                }
            }

            // Emit process_completed - game handles entity transformation
            engine.dispatcher.dispatch(.{ .process_completed = .{
                .workstation_id = workstation_id,
                .worker_id = worker_id,
            } });

            // Move to Store step
            ws.current_step = .Store;
            ws.selected_eos = engine.selectEos(workstation_id);

            if (ws.selected_eos) |eos_id| {
                // Get item from first IOS that has one
                var item: ?Item = null;
                for (ws.ios.items) |ios_id| {
                    if (engine.storages.get(ios_id)) |storage| {
                        if (storage.item_type) |it| {
                            item = it;
                            break;
                        }
                    }
                }

                engine.dispatcher.dispatch(.{ .store_started = .{
                    .worker_id = worker_id,
                    .storage_id = eos_id,
                    .item = item orelse return, // No item to store
                } });
            }
        }

        pub fn handleStoreCompleted(engine: *EngineType, worker_id: GameId) anyerror!void {
            const worker = engine.workers.getPtr(worker_id) orelse {
                log.err("store_completed: unknown worker {}", .{worker_id});
                return error.UnknownWorker;
            };

            // Handle dangling item delivery completion
            if (worker.dangling_task) |task| {
                const item_type = engine.dangling_items.get(task.item_id) orelse {
                    log.err("store_completed: dangling item {} no longer exists", .{task.item_id});
                    // BUG FIX: Clean up worker state so it doesn't get stuck
                    recoverWorkerFromMissingDanglingItem(engine, worker, worker_id);
                    return error.DanglingItemNotFound;
                };

                // Update EIS state - now has the item
                if (engine.storages.getPtr(task.target_storage_id)) |storage| {
                    storage.has_item = true;
                    storage.item_type = item_type;
                }

                // Dispatch item_delivered hook before removing (game can move item visual)
                engine.dispatcher.dispatch(.{ .item_delivered = .{
                    .worker_id = worker_id,
                    .item_id = task.item_id,
                    .item_type = item_type,
                    .storage_id = task.target_storage_id,
                } });

                // Remove from dangling items tracking
                engine.removeDanglingItem(task.item_id);

                // Release storage reservation
                engine.releaseReservation(task.target_storage_id);

                // Clear worker task and set to idle
                worker.dangling_task = null;
                worker.state = .Idle;
                engine.markWorkerIdle(worker_id);

                // First, check for remaining dangling items (higher priority)
                engine.evaluateDanglingItems();

                // Re-evaluate workstations (EIS now has item, may become Queued)
                // Only assign to workstations if worker is still idle
                if (worker.state == .Idle) {
                    engine.reevaluateWorkstations();
                } else {
                    // Worker was assigned to dangling item, just re-evaluate statuses
                    var ws_iter = engine.workstations.keyIterator();
                    while (ws_iter.next()) |ws_id| {
                        engine.evaluateWorkstationStatus(ws_id.*);
                    }
                }

                return;
            }

            const ws_id = worker.assigned_workstation orelse {
                // Recover: worker lost workstation assignment (can happen if reentrancy
                // during process_completed hook disrupted state). Return to idle.
                log.warn("store_completed: worker {} not assigned to workstation, recovering to idle", .{worker_id});
                worker.state = .Idle;
                engine.markWorkerIdle(worker_id);
                engine.dispatcher.dispatch(.{ .worker_released = .{ .worker_id = worker_id } });
                engine.tryAssignWorkers();
                return;
            };

            const ws = engine.workstations.getPtr(ws_id) orelse {
                log.err("store_completed: unknown workstation {}", .{ws_id});
                return error.UnknownWorkstation;
            };

            if (ws.current_step != .Store) {
                log.err("store_completed: workstation {} not in Store step", .{ws_id});
                return error.InvalidStep;
            }

            // Update abstract state: IOS → EOS
            // Find first IOS with item and move to selected EOS
            for (ws.ios.items) |ios_id| {
                if (engine.storages.getPtr(ios_id)) |ios_storage| {
                    if (ios_storage.has_item) {
                        const item = ios_storage.item_type;

                        // Clear IOS
                        ios_storage.has_item = false;
                        ios_storage.item_type = null;

                        // Fill EOS
                        if (ws.selected_eos) |eos_id| {
                            if (engine.storages.getPtr(eos_id)) |eos_storage| {
                                eos_storage.has_item = true;
                                eos_storage.item_type = item;
                            }
                        }
                        break;
                    }
                }
            }

            // Check if all IOS are empty
            var all_ios_empty = true;
            for (ws.ios.items) |ios_id| {
                if (engine.storages.get(ios_id)) |storage| {
                    if (storage.has_item) {
                        all_ios_empty = false;
                        break;
                    }
                }
            }

            if (all_ios_empty) {
                // Cycle complete
                ws.cycles_completed += 1;
                engine.dispatcher.dispatch(.{ .cycle_completed = .{
                    .workstation_id = ws_id,
                    .cycles_completed = ws.cycles_completed,
                } });

                // Reset per-cycle selections
                ws.selected_eis = null;
                ws.selected_eos = null;

                // Check if workstation can start another cycle immediately
                if (engine.canWorkstationOperate(ws)) {
                    // Keep worker assigned — start next cycle directly
                    if (ws.isProducer()) {
                        ws.current_step = .Process;
                        engine.dispatcher.dispatch(.{ .process_started = .{
                            .workstation_id = ws_id,
                            .worker_id = worker_id,
                        } });
                    } else {
                        ws.current_step = .Pickup;
                        ws.selected_eis = engine.selectEis(ws_id);

                        if (ws.selected_eis) |eis_id| {
                            const item = engine.storages.get(eis_id).?.item_type.?;
                            engine.dispatcher.dispatch(.{ .pickup_started = .{
                                .worker_id = worker_id,
                                .storage_id = eis_id,
                                .item = item,
                            } });
                        }
                    }

                    // EOS just got an item — other idle workers may transport it
                    engine.evaluateTransports();
                } else {
                    // Can't continue — release worker normally
                    ws.assigned_worker = null;
                    worker.state = .Idle;
                    worker.assigned_workstation = null;
                    engine.markWorkerIdle(worker_id);
                    engine.dispatcher.dispatch(.{ .worker_released = .{ .worker_id = worker_id } });

                    // Re-evaluate workstation status
                    engine.evaluateWorkstationStatus(ws_id);

                    // Try to assign workers to workstations first
                    engine.tryAssignWorkers();

                    // EOS just got an item — try transport (all idle workers, not just this one)
                    engine.evaluateTransports();
                }
            } else {
                // More items to store
                ws.selected_eos = engine.selectEos(ws_id);
                if (ws.selected_eos) |eos_id| {
                    var item: ?Item = null;
                    for (ws.ios.items) |ios_id| {
                        if (engine.storages.get(ios_id)) |storage| {
                            if (storage.item_type) |it| {
                                item = it;
                                break;
                            }
                        }
                    }

                    if (item) |it| {
                        engine.dispatcher.dispatch(.{ .store_started = .{
                            .worker_id = worker_id,
                            .storage_id = eos_id,
                            .item = it,
                        } });
                    }
                }

                // Previous EOS just got an item — other idle workers may transport it
                engine.evaluateTransports();
            }
        }
    };
}
