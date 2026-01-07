//! Internal helper functions for the task engine

const std = @import("std");
const state_mod = @import("state.zig");
const types = @import("types.zig");

const TargetType = types.TargetType;

/// Creates helper functions for the engine
pub fn Helpers(
    comptime GameId: type,
    comptime Item: type,
    comptime EngineType: type,
) type {
    return struct {
        const Self = @This();
        const WorkstationData = state_mod.WorkstationData(GameId);

        // ============================================
        // Workstation evaluation
        // ============================================

        pub fn evaluateWorkstationStatus(engine: *EngineType, workstation_id: GameId) void {
            const ws = engine.workstations.getPtr(workstation_id) orelse return;

            const old_status = ws.status;

            // Check if workstation can operate
            const can_operate = canWorkstationOperate(engine, ws);

            if (ws.assigned_worker != null) {
                ws.status = .Active;
            } else if (can_operate) {
                ws.status = .Queued;
            } else {
                ws.status = .Blocked;
            }

            // Emit status change hooks
            if (ws.status != old_status) {
                switch (ws.status) {
                    .Blocked => engine.dispatcher.dispatch(.{ .workstation_blocked = .{ .workstation_id = workstation_id } }),
                    .Queued => engine.dispatcher.dispatch(.{ .workstation_queued = .{ .workstation_id = workstation_id } }),
                    .Active => engine.dispatcher.dispatch(.{ .workstation_activated = .{ .workstation_id = workstation_id } }),
                }
            }
        }

        pub fn canWorkstationOperate(engine: *EngineType, ws: *const WorkstationData) bool {
            // Producer: just needs empty IOS and empty EOS
            if (ws.isProducer()) {
                // Check IOS has space
                for (ws.ios) |ios_id| {
                    if (engine.storages.get(ios_id)) |storage| {
                        if (storage.has_item) return false; // IOS full
                    }
                }
                // Check EOS has space
                for (ws.eos) |eos_id| {
                    if (engine.storages.get(eos_id)) |storage| {
                        if (storage.has_item) return false; // EOS full
                    }
                }
                return true;
            }

            // Regular workstation: needs items in EIS and space in EOS
            var has_input = false;
            for (ws.eis) |eis_id| {
                if (engine.storages.get(eis_id)) |storage| {
                    if (storage.has_item) {
                        has_input = true;
                        break;
                    }
                }
            }
            if (!has_input) return false;

            var has_output_space = false;
            for (ws.eos) |eos_id| {
                if (engine.storages.get(eos_id)) |storage| {
                    if (!storage.has_item) {
                        has_output_space = true;
                        break;
                    }
                }
            }
            if (!has_output_space) return false;

            return true;
        }

        pub fn reevaluateWorkstations(engine: *EngineType) void {
            var iter = engine.workstations.keyIterator();
            while (iter.next()) |ws_id| {
                evaluateWorkstationStatus(engine, ws_id.*);
            }
            tryAssignWorkers(engine);
        }

        // ============================================
        // Worker assignment
        // ============================================

        pub fn tryAssignWorkers(engine: *EngineType) void {
            // Collect idle workers
            var idle_workers = std.ArrayListUnmanaged(GameId){};
            defer idle_workers.deinit(engine.allocator);

            var worker_iter = engine.workers.iterator();
            while (worker_iter.next()) |entry| {
                if (entry.value_ptr.state == .Idle) {
                    idle_workers.append(engine.allocator, entry.key_ptr.*) catch continue;
                }
            }

            if (idle_workers.items.len == 0) return;

            // Find queued workstations and assign workers
            var ws_iter = engine.workstations.iterator();
            while (ws_iter.next()) |entry| {
                const ws_id = entry.key_ptr.*;
                const ws = entry.value_ptr;

                if (ws.status != .Queued) continue;

                // Use callback to select worker, or just pick first
                const worker_id = if (engine.find_best_worker_fn) |callback|
                    callback(ws_id, idle_workers.items)
                else if (idle_workers.items.len > 0)
                    idle_workers.items[0]
                else
                    null;

                if (worker_id) |wid| {
                    assignWorkerToWorkstation(engine, wid, ws_id);

                    // Remove from idle list
                    for (idle_workers.items, 0..) |id, i| {
                        if (id == wid) {
                            _ = idle_workers.swapRemove(i);
                            break;
                        }
                    }
                }
            }
        }

        pub fn assignWorkerToWorkstation(engine: *EngineType, worker_id: GameId, workstation_id: GameId) void {
            const worker = engine.workers.getPtr(worker_id) orelse return;
            const ws = engine.workstations.getPtr(workstation_id) orelse return;

            worker.state = .Working;
            worker.assigned_workstation = workstation_id;
            ws.assigned_worker = worker_id;
            ws.status = .Active;

            // Set movement target to workstation
            worker.moving_to = .{
                .target = workstation_id,
                .target_type = .workstation,
            };

            engine.dispatcher.dispatch(.{ .worker_assigned = .{
                .worker_id = worker_id,
                .workstation_id = workstation_id,
            } });
            engine.dispatcher.dispatch(.{ .workstation_activated = .{ .workstation_id = workstation_id } });

            // Emit movement_started - game should move worker to workstation
            engine.dispatcher.dispatch(.{ .movement_started = .{
                .worker_id = worker_id,
                .target = workstation_id,
                .target_type = .workstation,
            } });
        }

        /// Called when worker arrives at their movement target
        pub fn handleWorkerArrival(engine: *EngineType, worker_id: GameId) bool {
            const worker = engine.workers.getPtr(worker_id) orelse return false;
            const moving_to = worker.moving_to orelse return false;

            // Clear movement target
            worker.moving_to = null;

            switch (moving_to.target_type) {
                .workstation => {
                    // Worker arrived at workstation - check for leftover items in IOS first
                    const ws_id = worker.assigned_workstation orelse return false;
                    const ws = engine.workstations.getPtr(ws_id) orelse return false;

                    // PRIORITY 1: Check for leftover items in IOS (from interrupted cycles)
                    if (selectIos(engine, ws_id)) |ios_id| {
                        // IOS has leftover item - need to store it first
                        const ios_item = engine.storages.get(ios_id).?.item_type;

                        // Check if EOS has space
                        if (selectEos(engine, ws_id)) |eos_id| {
                            // EOS has space - move to Store step
                            ws.current_step = .Store;
                            ws.selected_eos = eos_id;

                            // Set movement target to EOS
                            worker.moving_to = .{
                                .target = eos_id,
                                .target_type = .storage,
                            };

                            engine.dispatcher.dispatch(.{ .store_started = .{
                                .worker_id = worker_id,
                                .storage_id = eos_id,
                                .item = ios_item orelse return false,
                            } });
                            engine.dispatcher.dispatch(.{ .movement_started = .{
                                .worker_id = worker_id,
                                .target = eos_id,
                                .target_type = .storage,
                            } });
                        } else {
                            // No EOS space - release worker, workstation is blocked
                            releaseWorker(engine, worker_id, ws_id);
                        }
                        return true;
                    }

                    // PRIORITY 2: Normal workflow
                    // Check if all IIS have items (ready for processing)
                    if (ws.isProducer() or allIisFilled(engine, ws_id)) {
                        // All inputs ready - go to Process step
                        ws.current_step = .Process;
                        engine.dispatcher.dispatch(.{ .process_started = .{
                            .workstation_id = ws_id,
                            .worker_id = worker_id,
                        } });
                    } else {
                        // IIS not filled - need to pick up items from EIS
                        ws.current_step = .Pickup;
                        ws.selected_eis = selectEis(engine, ws_id);

                        if (ws.selected_eis) |eis_id| {
                            const item = engine.storages.get(eis_id).?.item_type.?;

                            // Set movement target to EIS
                            worker.moving_to = .{
                                .target = eis_id,
                                .target_type = .storage,
                            };

                            engine.dispatcher.dispatch(.{ .pickup_started = .{
                                .worker_id = worker_id,
                                .storage_id = eis_id,
                                .item = item,
                            } });
                            engine.dispatcher.dispatch(.{ .movement_started = .{
                                .worker_id = worker_id,
                                .target = eis_id,
                                .target_type = .storage,
                            } });
                        } else {
                            // No EIS with items available - release worker
                            releaseWorker(engine, worker_id, ws_id);
                        }
                    }
                },
                .storage => {
                    // Worker arrived at storage
                    // Check if this is a transport task (EOS → EIS delivery)
                    if (worker.transport_task) |task| {
                        if (moving_to.target == task.from_eos_id) {
                            // Arrived at EOS - now go to EIS
                            worker.moving_to = .{
                                .target = task.to_eis_id,
                                .target_type = .storage,
                            };
                            engine.dispatcher.dispatch(.{ .movement_started = .{
                                .worker_id = worker_id,
                                .target = task.to_eis_id,
                                .target_type = .storage,
                            } });
                            return true;
                        } else if (moving_to.target == task.to_eis_id) {
                            // Arrived at EIS - complete transport
                            handleTransportComplete(engine, worker_id, worker, task);
                            return true;
                        }
                    }

                    // Check if this is a dangling item delivery (no assigned workstation)
                    if (worker.dangling_task != null) {
                        // Dangling item delivery - worker arrived at target EIS
                        // Delegate to existing dangling delivery completion logic
                        _ = @import("handlers.zig").Handlers(GameId, Item, EngineType).handleStoreCompleted(engine, worker_id);
                        return true;
                    }

                    // Workstation workflow - depends on current step
                    const ws_id = worker.assigned_workstation orelse return false;
                    const ws = engine.workstations.getPtr(ws_id) orelse return false;

                    switch (ws.current_step) {
                        .Pickup => {
                            // Delegate to existing pickup completion logic
                            _ = @import("handlers.zig").Handlers(GameId, Item, EngineType).handlePickupCompleted(engine, worker_id);
                        },
                        .Store => {
                            // Delegate to existing store completion logic
                            _ = @import("handlers.zig").Handlers(GameId, Item, EngineType).handleStoreCompleted(engine, worker_id);
                        },
                        .Process => {
                            // Shouldn't happen - Process doesn't involve storage movement
                        },
                    }
                },
                .dangling_item => {
                    // Worker arrived at dangling item - pick it up
                    // Delegate to existing dangling item logic
                    @import("handlers.zig").Handlers(GameId, Item, EngineType).handleDanglingPickupArrival(engine, worker_id);
                },
            }
            return true;
        }

        // ============================================
        // Storage selection
        // ============================================

        pub fn selectEis(engine: *EngineType, workstation_id: GameId) ?GameId {
            const ws = engine.workstations.get(workstation_id) orelse return null;

            // Find first EIS with an item
            for (ws.eis) |eis_id| {
                if (engine.storages.get(eis_id)) |storage| {
                    if (storage.has_item) {
                        return eis_id;
                    }
                }
            }
            return null;
        }

        pub fn selectEos(engine: *EngineType, workstation_id: GameId) ?GameId {
            const ws = engine.workstations.get(workstation_id) orelse return null;

            // Find first EOS with space
            for (ws.eos) |eos_id| {
                if (engine.storages.get(eos_id)) |storage| {
                    if (!storage.has_item) {
                        return eos_id;
                    }
                }
            }
            return null;
        }

        /// Select an IOS that has an item (for clearing leftover items)
        pub fn selectIos(engine: *EngineType, workstation_id: GameId) ?GameId {
            const ws = engine.workstations.get(workstation_id) orelse return null;

            // Find first IOS with an item
            for (ws.ios) |ios_id| {
                if (engine.storages.get(ios_id)) |storage| {
                    if (storage.has_item) {
                        return ios_id;
                    }
                }
            }
            return null;
        }

        /// Check if all IIS have items (ready for processing)
        pub fn allIisFilled(engine: *EngineType, workstation_id: GameId) bool {
            const ws = engine.workstations.get(workstation_id) orelse return false;

            // If no IIS, consider it "filled" (producer workstation)
            if (ws.iis.len == 0) return true;

            for (ws.iis) |iis_id| {
                if (engine.storages.get(iis_id)) |storage| {
                    if (!storage.has_item) {
                        return false;
                    }
                }
            }
            return true;
        }

        /// Release worker from workstation assignment
        pub fn releaseWorker(engine: *EngineType, worker_id: GameId, ws_id: GameId) void {
            const worker = engine.workers.getPtr(worker_id) orelse return;
            const ws = engine.workstations.getPtr(ws_id) orelse return;

            // Release worker
            ws.assigned_worker = null;
            worker.state = .Idle;
            worker.assigned_workstation = null;
            worker.moving_to = null;

            engine.dispatcher.dispatch(.{ .worker_released = .{ .worker_id = worker_id } });

            // Re-evaluate workstation status
            evaluateWorkstationStatus(engine, ws_id);
        }

        // ============================================
        // Transport completion
        // ============================================

        const WorkerData = state_mod.WorkerData(GameId, Item);

        /// Complete EOS → EIS transport
        fn handleTransportComplete(engine: *EngineType, worker_id: GameId, worker: *WorkerData, task: anytype) void {
            const log = std.log.scoped(.transport);

            // Fill EIS with transported item
            if (engine.storages.getPtr(task.to_eis_id)) |eis| {
                eis.has_item = true;
                eis.item_type = task.item_type;
            }

            // Dispatch hooks
            engine.dispatcher.dispatch(.{ .transport_completed = .{
                .worker_id = worker_id,
                .to_storage_id = task.to_eis_id,
                .item = task.item_type,
            } });
            engine.dispatcher.dispatch(.{ .item_delivered = .{
                .worker_id = worker_id,
                .item_id = 0, // No entity ID for transported items
                .item_type = task.item_type,
                .storage_id = task.to_eis_id,
            } });

            log.info("transport complete: worker {d} delivered {s} to EIS {d}", .{
                worker_id,
                @tagName(task.item_type),
                task.to_eis_id,
            });

            // Release worker
            worker.state = .Idle;
            worker.transport_task = null;
            worker.moving_to = null;

            engine.dispatcher.dispatch(.{ .worker_released = .{ .worker_id = worker_id } });

            // Re-evaluate for more work
            reevaluateWorkstations(engine);
            engine.evaluateTransports();
            engine.evaluateDanglingItems();
            tryAssignWorkers(engine);
        }
    };
}
