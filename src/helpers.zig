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
    };
}
