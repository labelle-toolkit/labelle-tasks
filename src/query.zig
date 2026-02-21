//! Query, introspection, and diagnostics API for reading engine state

const std = @import("std");
const state_mod = @import("state.zig");
const types = @import("types.zig");

const WorkerState = types.WorkerState;
const WorkstationStatus = types.WorkstationStatus;
const StepType = types.StepType;
const Priority = types.Priority;
const StorageRole = state_mod.StorageRole;

/// Creates query and introspection functions for the engine
pub fn Query(
    comptime GameId: type,
    comptime Item: type,
    comptime EngineType: type,
) type {
    return struct {
        const WorkerData = state_mod.WorkerData(GameId);

        // ============================================
        // Simple Query API
        // ============================================

        pub fn getWorkerState(engine: *const EngineType, worker_id: GameId) ?WorkerState {
            const worker = engine.workers.get(worker_id) orelse return null;
            return worker.state;
        }

        pub fn getWorkerCurrentStep(engine: *const EngineType, worker_id: GameId) ?StepType {
            const worker = engine.workers.get(worker_id) orelse return null;
            const ws_id = worker.assigned_workstation orelse return null;
            const ws = engine.workstations.get(ws_id) orelse return null;
            return ws.current_step;
        }

        pub fn getWorkstationStatus(engine: *const EngineType, workstation_id: GameId) ?WorkstationStatus {
            const ws = engine.workstations.get(workstation_id) orelse return null;
            return ws.status;
        }

        pub fn getStorageHasItem(engine: *const EngineType, storage_id: GameId) ?bool {
            const storage = engine.storages.get(storage_id) orelse return null;
            return storage.has_item;
        }

        pub fn getStorageItemType(engine: *const EngineType, storage_id: GameId) ?Item {
            const storage = engine.storages.get(storage_id) orelse return null;
            return storage.item_type;
        }

        /// Check if a storage is full (has an item)
        pub fn isStorageFull(engine: *const EngineType, storage_id: GameId) bool {
            const storage = engine.storages.get(storage_id) orelse return false;
            return storage.has_item;
        }

        /// Get the workstation a worker is assigned to (if any)
        pub fn getWorkerAssignment(engine: *const EngineType, worker_id: GameId) ?GameId {
            const worker = engine.workers.get(worker_id) orelse return null;
            return worker.assigned_workstation;
        }

        // ============================================
        // Introspection API
        // ============================================

        /// Full storage state snapshot for diagnostics
        pub const StorageInfo = struct {
            has_item: bool,
            item_type: ?Item,
            role: StorageRole,
            accepts: ?Item,
            priority: Priority,
        };

        pub fn getStorageInfo(engine: *const EngineType, storage_id: GameId) ?StorageInfo {
            const s = engine.storages.get(storage_id) orelse return null;
            return .{
                .has_item = s.has_item,
                .item_type = s.item_type,
                .role = s.role,
                .accepts = s.accepts,
                .priority = s.priority,
            };
        }

        /// Full worker state snapshot for diagnostics
        pub const WorkerInfo = struct {
            state: WorkerState,
            assigned_workstation: ?GameId,
            has_dangling_task: bool,
        };

        pub fn getWorkerInfo(engine: *const EngineType, worker_id: GameId) ?WorkerInfo {
            const w = engine.workers.get(worker_id) orelse return null;
            return .{
                .state = w.state,
                .assigned_workstation = w.assigned_workstation,
                .has_dangling_task = w.dangling_task != null,
            };
        }

        /// Full workstation state snapshot for diagnostics
        pub const WorkstationInfo = struct {
            status: WorkstationStatus,
            assigned_worker: ?GameId,
            current_step: StepType,
            cycles_completed: u32,
            priority: Priority,
            eis_count: usize,
            iis_count: usize,
            ios_count: usize,
            eos_count: usize,
        };

        pub fn getWorkstationInfo(engine: *const EngineType, workstation_id: GameId) ?WorkstationInfo {
            const ws = engine.workstations.get(workstation_id) orelse return null;
            return .{
                .status = ws.status,
                .assigned_worker = ws.assigned_worker,
                .current_step = ws.current_step,
                .cycles_completed = ws.cycles_completed,
                .priority = ws.priority,
                .eis_count = ws.eis.items.len,
                .iis_count = ws.iis.items.len,
                .ios_count = ws.ios.items.len,
                .eos_count = ws.eos.items.len,
            };
        }

        /// Entity counts for quick overview
        pub const EngineCounts = struct {
            storages: usize,
            workers: usize,
            workstations: usize,
            dangling_items: usize,
            idle_workers: usize,
            queued_workstations: usize,
        };

        /// Get entity counts for quick diagnostics
        pub fn getCounts(engine: *const EngineType) EngineCounts {
            return .{
                .storages = engine.storages.count(),
                .workers = engine.workers.count(),
                .workstations = engine.workstations.count(),
                .dangling_items = engine.dangling_items.count(),
                .idle_workers = engine.idle_workers_set.count(),
                .queued_workstations = engine.queued_workstations_set.count(),
            };
        }

        // ============================================
        // Diagnostics
        // ============================================

        /// Dump engine state to a writer for diagnostics.
        /// Output is sorted by entity ID for deterministic results.
        pub fn dumpState(engine: *const EngineType, writer: anytype) !void {
            const counts = getCounts(engine);
            try writer.print("=== Task Engine State ===\n", .{});
            try writer.print("Storages: {d}  Workers: {d}  Workstations: {d}  Dangling: {d}\n", .{
                counts.storages, counts.workers, counts.workstations, counts.dangling_items,
            });
            try writer.print("Idle workers: {d}  Queued workstations: {d}\n\n", .{
                counts.idle_workers, counts.queued_workstations,
            });

            // Storages (sorted by ID for deterministic output)
            var s_keys: std.ArrayListUnmanaged(GameId) = .{};
            defer s_keys.deinit(engine.allocator);
            var s_iter = engine.storages.keyIterator();
            while (s_iter.next()) |key| try s_keys.append(engine.allocator, key.*);
            std.mem.sort(GameId, s_keys.items, {}, std.sort.asc(GameId));
            for (s_keys.items) |id| {
                const s = engine.storages.get(id).?;
                try writer.print("  Storage {d}: role={s} has_item={} item={s} accepts={s} priority={s}\n", .{
                    id,
                    @tagName(s.role),
                    s.has_item,
                    if (s.item_type) |it| @tagName(it) else "none",
                    if (s.accepts) |a| @tagName(a) else "any",
                    @tagName(s.priority),
                });
            }

            // Workers (sorted by ID)
            var w_keys: std.ArrayListUnmanaged(GameId) = .{};
            defer w_keys.deinit(engine.allocator);
            var w_iter = engine.workers.keyIterator();
            while (w_iter.next()) |key| try w_keys.append(engine.allocator, key.*);
            std.mem.sort(GameId, w_keys.items, {}, std.sort.asc(GameId));
            for (w_keys.items) |id| {
                const w = engine.workers.get(id).?;
                try writer.print("  Worker {d}: state={s} ws={?d} dangling={}\n", .{
                    id,
                    @tagName(w.state),
                    w.assigned_workstation,
                    w.dangling_task != null,
                });
            }

            // Workstations (sorted by ID)
            var ws_keys: std.ArrayListUnmanaged(GameId) = .{};
            defer ws_keys.deinit(engine.allocator);
            var ws_iter = engine.workstations.keyIterator();
            while (ws_iter.next()) |key| try ws_keys.append(engine.allocator, key.*);
            std.mem.sort(GameId, ws_keys.items, {}, std.sort.asc(GameId));
            for (ws_keys.items) |id| {
                const ws = engine.workstations.get(id).?;
                try writer.print("  Workstation {d}: status={s} worker={?d} step={s} cycles={d} priority={s}\n", .{
                    id,
                    @tagName(ws.status),
                    ws.assigned_worker,
                    @tagName(ws.current_step),
                    ws.cycles_completed,
                    @tagName(ws.priority),
                });
                try writer.print("    EIS({d}) IIS({d}) IOS({d}) EOS({d})\n", .{
                    ws.eis.items.len, ws.iis.items.len, ws.ios.items.len, ws.eos.items.len,
                });
            }

            // Dangling items (sorted by ID)
            if (engine.dangling_items.count() > 0) {
                var d_keys: std.ArrayListUnmanaged(GameId) = .{};
                defer d_keys.deinit(engine.allocator);
                var d_iter = engine.dangling_items.keyIterator();
                while (d_iter.next()) |key| try d_keys.append(engine.allocator, key.*);
                std.mem.sort(GameId, d_keys.items, {}, std.sort.asc(GameId));
                for (d_keys.items) |id| {
                    const item_type = engine.dangling_items.get(id).?;
                    try writer.print("  Dangling {d}: type={s}\n", .{ id, @tagName(item_type) });
                }
            }
        }
    };
}
