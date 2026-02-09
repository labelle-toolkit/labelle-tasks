//! Event handlers for game → task engine communication

const std = @import("std");
const log = std.log.scoped(.tasks);

const types = @import("types.zig");
const state_mod = @import("state.zig");

/// Creates handler functions for the engine
pub fn Handlers(
    comptime GameId: type,
    comptime Item: type,
    comptime EngineType: type,
) type {
    return struct {
        const Self = @This();
        const StorageState = state_mod.StorageState(Item);
        const WorkerData = state_mod.WorkerData(GameId);
        const WorkstationData = state_mod.WorkstationData(GameId);

        // ============================================
        // Storage handlers
        // ============================================

        pub fn handleItemAdded(engine: *EngineType, storage_id: GameId, item: Item) bool {
            const storage = engine.storages.getPtr(storage_id) orelse {
                log.err("item_added: unknown storage {}", .{storage_id});
                return false;
            };

            // Allow setting item_type even if has_item is already true
            // This is needed for IOS where task engine sets has_item=true in workCompleted
            // but game sets item_type via process_completed hook
            if (storage.has_item and storage.item_type != null) {
                log.warn("item_added: storage {} already has item {s}, ignoring", .{ storage_id, @tagName(storage.item_type.?) });
                return false;
            }

            storage.has_item = true;
            storage.item_type = item;

            // Re-evaluate workstations that use this storage
            engine.reevaluateWorkstations();
            return true;
        }

        pub fn handleItemRemoved(engine: *EngineType, storage_id: GameId) bool {
            const storage = engine.storages.getPtr(storage_id) orelse {
                log.err("item_removed: unknown storage {}", .{storage_id});
                return false;
            };

            storage.has_item = false;
            storage.item_type = null;

            engine.reevaluateWorkstations();
            return true;
        }

        pub fn handleStorageCleared(engine: *EngineType, storage_id: GameId) bool {
            _ = engine.storages.remove(storage_id);
            return true;
        }

        // ============================================
        // Worker handlers
        // ============================================

        pub fn handleWorkerAvailable(engine: *EngineType, worker_id: GameId) bool {
            const worker = engine.workers.getPtr(worker_id) orelse {
                log.err("worker_available: unknown worker {}", .{worker_id});
                return false;
            };

            worker.state = .Idle;
            worker.assigned_workstation = null;

            // First, try to assign worker to pick up dangling items (higher priority)
            engine.evaluateDanglingItems();

            // If worker is still idle, try to assign to a queued workstation
            if (worker.state == .Idle) {
                engine.tryAssignWorkers();
            }
            return true;
        }

        pub fn handleWorkerUnavailable(engine: *EngineType, worker_id: GameId) bool {
            const worker = engine.workers.getPtr(worker_id) orelse {
                log.err("worker_unavailable: unknown worker {}", .{worker_id});
                return false;
            };

            // If worker was assigned, release from workstation
            if (worker.assigned_workstation) |ws_id| {
                if (engine.workstations.getPtr(ws_id)) |ws| {
                    ws.assigned_worker = null;
                    ws.status = .Queued;

                    engine.dispatcher.dispatch(.{ .worker_released = .{ .worker_id = worker_id } });
                    engine.dispatcher.dispatch(.{ .workstation_queued = .{ .workstation_id = ws_id } });
                }
            }

            worker.state = .Unavailable;
            worker.assigned_workstation = null;
            return true;
        }

        pub fn handleWorkerRemoved(engine: *EngineType, worker_id: GameId) bool {
            if (engine.workers.getPtr(worker_id)) |worker| {
                // Release from workstation first
                if (worker.assigned_workstation) |ws_id| {
                    if (engine.workstations.getPtr(ws_id)) |ws| {
                        ws.assigned_worker = null;
                        engine.evaluateWorkstationStatus(ws_id);
                    }
                }
            }
            _ = engine.workers.remove(worker_id);
            return true;
        }

        // ============================================
        // Workstation handlers
        // ============================================

        pub fn handleWorkstationEnabled(engine: *EngineType, workstation_id: GameId) bool {
            engine.evaluateWorkstationStatus(workstation_id);
            return true;
        }

        pub fn handleWorkstationDisabled(engine: *EngineType, workstation_id: GameId) bool {
            const ws = engine.workstations.getPtr(workstation_id) orelse {
                return false;
            };

            // Release worker if assigned
            if (ws.assigned_worker) |worker_id| {
                if (engine.workers.getPtr(worker_id)) |worker| {
                    worker.state = .Idle;
                    worker.assigned_workstation = null;
                    engine.dispatcher.dispatch(.{ .worker_released = .{ .worker_id = worker_id } });
                }
            }

            ws.status = .Blocked;
            ws.assigned_worker = null;
            engine.dispatcher.dispatch(.{ .workstation_blocked = .{ .workstation_id = workstation_id } });
            return true;
        }

        pub fn handleWorkstationRemoved(engine: *EngineType, workstation_id: GameId) bool {
            if (engine.workstations.getPtr(workstation_id)) |ws| {
                // Release worker
                if (ws.assigned_worker) |worker_id| {
                    if (engine.workers.getPtr(worker_id)) |worker| {
                        worker.state = .Idle;
                        worker.assigned_workstation = null;
                    }
                }

                // Free storage lists
                ws.deinit(engine.allocator);
            }
            _ = engine.workstations.remove(workstation_id);
            return true;
        }

        // ============================================
        // Step completion handlers
        // ============================================

        pub fn handlePickupCompleted(engine: *EngineType, worker_id: GameId) bool {
            const worker = engine.workers.getPtr(worker_id) orelse {
                log.err("pickup_completed: unknown worker {}", .{worker_id});
                return false;
            };

            // Handle dangling item delivery
            if (worker.dangling_task) |task| {
                const item_type = engine.dangling_items.get(task.item_id) orelse {
                    log.err("pickup_completed: dangling item {} no longer exists", .{task.item_id});
                    return false;
                };

                // Dispatch store_started to move worker to EIS
                engine.dispatcher.dispatch(.{ .store_started = .{
                    .worker_id = worker_id,
                    .storage_id = task.target_eis_id,
                    .item = item_type,
                } });
                return true;
            }

            const ws_id = worker.assigned_workstation orelse {
                log.err("pickup_completed: worker {} not assigned to workstation", .{worker_id});
                return false;
            };

            const ws = engine.workstations.getPtr(ws_id) orelse {
                log.err("pickup_completed: unknown workstation {}", .{ws_id});
                return false;
            };

            if (ws.current_step != .Pickup) {
                log.err("pickup_completed: workstation {} not in Pickup step", .{ws_id});
                return false;
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
            }

            // Check if all IIS are filled
            var all_iis_filled = true;
            for (ws.iis.items) |iis_id| {
                if (engine.storages.get(iis_id)) |iis_storage| {
                    if (!iis_storage.has_item) {
                        all_iis_filled = false;
                        break;
                    }
                }
            }

            if (all_iis_filled or ws.isProducer()) {
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

            return true;
        }

        pub fn handleWorkCompleted(engine: *EngineType, workstation_id: GameId) bool {
            const ws = engine.workstations.getPtr(workstation_id) orelse {
                log.err("work_completed: unknown workstation {}", .{workstation_id});
                return false;
            };

            if (ws.current_step != .Process) {
                log.err("work_completed: workstation {} not in Process step", .{workstation_id});
                return false;
            }

            const worker_id = ws.assigned_worker orelse {
                log.err("work_completed: workstation {} has no assigned worker", .{workstation_id});
                return false;
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
                    .item = item orelse return true, // No item to store
                } });
            }

            return true;
        }

        pub fn handleStoreCompleted(engine: *EngineType, worker_id: GameId) bool {
            const worker = engine.workers.getPtr(worker_id) orelse {
                log.err("store_completed: unknown worker {}", .{worker_id});
                return false;
            };

            // Handle dangling item delivery completion
            if (worker.dangling_task) |task| {
                const item_type = engine.dangling_items.get(task.item_id) orelse {
                    log.err("store_completed: dangling item {} no longer exists", .{task.item_id});
                    return false;
                };

                // Update EIS state - now has the item
                if (engine.storages.getPtr(task.target_eis_id)) |storage| {
                    storage.has_item = true;
                    storage.item_type = item_type;
                }

                // Dispatch item_delivered hook before removing (game can move item visual)
                engine.dispatcher.dispatch(.{ .item_delivered = .{
                    .worker_id = worker_id,
                    .item_id = task.item_id,
                    .item_type = item_type,
                    .storage_id = task.target_eis_id,
                } });

                // Remove from dangling items tracking
                engine.removeDanglingItem(task.item_id);

                // Clear worker task and set to idle
                worker.dangling_task = null;
                worker.state = .Idle;

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

                return true;
            }

            const ws_id = worker.assigned_workstation orelse {
                log.err("store_completed: worker {} not assigned to workstation", .{worker_id});
                return false;
            };

            const ws = engine.workstations.getPtr(ws_id) orelse {
                log.err("store_completed: unknown workstation {}", .{ws_id});
                return false;
            };

            if (ws.current_step != .Store) {
                log.err("store_completed: workstation {} not in Store step", .{ws_id});
                return false;
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

                // Reset for next cycle
                ws.current_step = .Pickup;
                ws.selected_eis = null;
                ws.selected_eos = null;

                // Release worker
                ws.assigned_worker = null;
                worker.state = .Idle;
                worker.assigned_workstation = null;
                engine.dispatcher.dispatch(.{ .worker_released = .{ .worker_id = worker_id } });

                // Re-evaluate workstation status
                engine.evaluateWorkstationStatus(ws_id);

                // Try to assign workers
                engine.tryAssignWorkers();
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
            }

            return true;
        }
    };
}
