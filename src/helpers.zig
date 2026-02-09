//! Internal helper functions for the task engine

const std = @import("std");
const state_mod = @import("state.zig");

/// Creates helper functions for the engine
pub fn Helpers(
    comptime GameId: type,
    comptime Item: type,
    comptime EngineType: type,
) type {
    _ = Item; // Used by engine type
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

            // Update tracking set
            if (ws.status == .Queued) {
                engine.markWorkstationQueued(workstation_id);
            } else {
                engine.markWorkstationNotQueued(workstation_id);
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
            // Producer: just needs empty IOS and at least one empty EOS
            if (ws.isProducer()) {
                // Check IOS has space (all IOS must be empty for producer to start new cycle)
                for (ws.ios.items) |ios_id| {
                    if (engine.storages.get(ios_id)) |storage| {
                        if (storage.has_item) return false; // IOS full
                    }
                }
                // Check at least one EOS has space
                var has_eos_space = false;
                for (ws.eos.items) |eos_id| {
                    if (engine.storages.get(eos_id)) |storage| {
                        if (!storage.has_item) {
                            has_eos_space = true;
                            break;
                        }
                    }
                }
                return has_eos_space;
            }

            // Regular workstation: needs ALL EIS to have items and space in EOS
            // (All ingredients must be present before processing can begin)
            for (ws.eis.items) |eis_id| {
                if (engine.storages.get(eis_id)) |storage| {
                    if (!storage.has_item) {
                        return false; // Missing ingredient
                    }
                } else {
                    return false; // Storage not found
                }
            }

            var has_output_space = false;
            for (ws.eos.items) |eos_id| {
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
            if (engine.idle_workers_set.count() == 0) return;
            if (engine.queued_workstations_set.count() == 0) return;

            // Build a snapshot of idle worker IDs for the callback API
            // (uses stack buffer to avoid heap allocation for small counts)
            var idle_buf: [64]GameId = undefined;
            var idle_workers = std.ArrayListUnmanaged(GameId){};
            defer if (idle_workers.capacity > 64) idle_workers.deinit(engine.allocator);

            // Try to use stack buffer first
            if (engine.idle_workers_set.count() <= 64) {
                idle_workers = .{ .items = idle_buf[0..0], .capacity = 64 };
            }

            var idle_iter = engine.idle_workers_set.keyIterator();
            while (idle_iter.next()) |wid| {
                if (idle_workers.capacity <= 64) {
                    // Using stack buffer
                    if (idle_workers.items.len < 64) {
                        idle_buf[idle_workers.items.len] = wid.*;
                        idle_workers.items = idle_buf[0 .. idle_workers.items.len + 1];
                    }
                } else {
                    idle_workers.append(engine.allocator, wid.*) catch continue;
                }
            }

            if (idle_workers.items.len == 0) return;

            // Iterate queued workstations from tracking set
            var queued_iter = engine.queued_workstations_set.keyIterator();
            while (queued_iter.next()) |ws_id_ptr| {
                const ws_id = ws_id_ptr.*;

                // Use callback to select worker, or just pick first
                const worker_id = if (engine.find_best_worker_fn) |callback|
                    callback(ws_id, idle_workers.items)
                else if (idle_workers.items.len > 0)
                    idle_workers.items[0]
                else
                    null;

                if (worker_id) |wid| {
                    assignWorkerToWorkstation(engine, wid, ws_id);

                    // O(n) search + O(1) swap remove from local snapshot
                    for (idle_workers.items, 0..) |id, i| {
                        if (id == wid) {
                            _ = idle_workers.swapRemove(i);
                            break;
                        }
                    }

                    // Early exit when no idle workers remain
                    if (idle_workers.items.len == 0) break;
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

            // Update tracking sets
            engine.markWorkerBusy(worker_id);
            engine.markWorkstationNotQueued(workstation_id);

            engine.dispatcher.dispatch(.{ .worker_assigned = .{
                .worker_id = worker_id,
                .workstation_id = workstation_id,
            } });
            engine.dispatcher.dispatch(.{ .workstation_activated = .{ .workstation_id = workstation_id } });

            // Start the workflow
            if (ws.isProducer()) {
                // Producer: go straight to Process
                ws.current_step = .Process;
                engine.dispatcher.dispatch(.{ .process_started = .{
                    .workstation_id = workstation_id,
                    .worker_id = worker_id,
                } });
            } else {
                // Regular: start with Pickup
                ws.current_step = .Pickup;
                ws.selected_eis = selectEis(engine, workstation_id);

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

        // ============================================
        // Storage selection
        // ============================================

        pub fn selectEis(engine: *EngineType, workstation_id: GameId) ?GameId {
            const ws = engine.workstations.get(workstation_id) orelse return null;

            // Find first EIS with an item
            for (ws.eis.items) |eis_id| {
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
            for (ws.eos.items) |eos_id| {
                if (engine.storages.get(eos_id)) |storage| {
                    if (!storage.has_item) {
                        return eos_id;
                    }
                }
            }
            return null;
        }
    };
}
