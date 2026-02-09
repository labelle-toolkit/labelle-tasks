//! Internal helper functions for the task engine

const std = @import("std");
const state_mod = @import("state.zig");
const types = @import("types.zig");

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

            // Snapshot into local buffers to avoid reentrancy issues
            // (assignWorkerToWorkstation dispatches hooks which could trigger tryAssignWorkers again)
            var idle_scratch: std.ArrayListUnmanaged(GameId) = .{};
            defer idle_scratch.deinit(engine.allocator);
            var queued_scratch: std.ArrayListUnmanaged(GameId) = .{};
            defer queued_scratch.deinit(engine.allocator);

            idle_scratch.ensureTotalCapacity(engine.allocator, engine.idle_workers_set.count()) catch return;
            queued_scratch.ensureTotalCapacity(engine.allocator, engine.queued_workstations_set.count()) catch return;

            var idle_iter = engine.idle_workers_set.keyIterator();
            while (idle_iter.next()) |wid| {
                idle_scratch.appendAssumeCapacity(wid.*);
            }

            var queued_iter = engine.queued_workstations_set.keyIterator();
            while (queued_iter.next()) |wsid| {
                queued_scratch.appendAssumeCapacity(wsid.*);
            }

            var idle_workers = idle_scratch.items;
            if (idle_workers.len == 0) return;

            // Sort queued workstations by priority (highest first) so higher-priority
            // workstations get workers before lower-priority ones
            std.mem.sort(GameId, queued_scratch.items, engine, struct {
                fn lessThan(eng: *EngineType, a: GameId, b: GameId) bool {
                    const a_ws = eng.workstations.get(a) orelse unreachable;
                    const b_ws = eng.workstations.get(b) orelse unreachable;
                    return @intFromEnum(a_ws.priority) > @intFromEnum(b_ws.priority);
                }
            }.lessThan);

            // Assign idle workers to queued workstations (iterating snapshots, safe to mutate sets)
            for (queued_scratch.items) |ws_id| {
                const ws = engine.workstations.get(ws_id) orelse continue;
                if (ws.status != .Queued) continue;

                // Use callback to select worker, or just pick first
                const worker_id = if (engine.find_best_worker_fn) |callback|
                    callback(ws_id, idle_workers)
                else if (idle_workers.len > 0)
                    idle_workers[0]
                else
                    null;

                if (worker_id) |wid| {
                    assignWorkerToWorkstation(engine, wid, ws_id);

                    // O(n) search + O(1) swap remove from local snapshot
                    for (idle_workers, 0..) |id, idx| {
                        if (id == wid) {
                            idle_workers[idx] = idle_workers[idle_workers.len - 1];
                            idle_workers = idle_workers[0 .. idle_workers.len - 1];
                            break;
                        }
                    }

                    // Early exit when no idle workers remain
                    if (idle_workers.len == 0) break;
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

        /// Select the highest-priority storage matching the given has_item condition.
        fn selectStorage(engine: *EngineType, storage_ids: []const GameId, comptime has_item_check: bool) ?GameId {
            var best_id: ?GameId = null;
            var best_priority: i16 = -1;

            for (storage_ids) |id| {
                if (engine.storages.get(id)) |storage| {
                    if (storage.has_item == has_item_check) {
                        const current_priority: i16 = @intFromEnum(storage.priority);
                        if (current_priority > best_priority) {
                            best_id = id;
                            best_priority = current_priority;
                        }
                    }
                }
            }
            return best_id;
        }

        pub fn selectEis(engine: *EngineType, workstation_id: GameId) ?GameId {
            const ws = engine.workstations.get(workstation_id) orelse return null;
            return selectStorage(engine, ws.eis.items, true);
        }

        pub fn selectEos(engine: *EngineType, workstation_id: GameId) ?GameId {
            const ws = engine.workstations.get(workstation_id) orelse return null;
            return selectStorage(engine, ws.eos.items, false);
        }
    };
}
