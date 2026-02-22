//! Dangling item management for the task engine.
//! Handles items that are not in any storage and need to be delivered to a destination
//! (EIS first, standalone fallback).

const std = @import("std");
const log = std.log.scoped(.tasks);

/// Creates dangling item management functions for the engine
pub fn DanglingManager(
    comptime GameId: type,
    comptime Item: type,
    comptime EngineType: type,
) type {
    return struct {
        /// Register a dangling item (item not in any storage)
        pub fn addDanglingItem(engine: *EngineType, item_id: GameId, item_type: Item) !void {
            try engine.dangling_items.put(item_id, item_type);
            // Defer evaluation — processDeferredEvaluations will handle it
            engine.needs_dangling_eval = true;
        }

        /// Remove a dangling item (picked up or despawned)
        pub fn removeDanglingItem(engine: *EngineType, item_id: GameId) void {
            _ = engine.dangling_items.remove(item_id);
        }

        /// Get the item type of a dangling item
        pub fn getDanglingItemType(engine: *const EngineType, item_id: GameId) ?Item {
            return engine.dangling_items.get(item_id);
        }

        /// Find an empty EIS that accepts the given item type.
        /// Returns null if no suitable EIS found.
        /// Note: Does not check reservations — use findDestinationForItem for reservation-aware routing.
        pub fn findEmptyEisForItem(engine: *const EngineType, item_type: Item) ?GameId {
            var iter = engine.storages.iterator();
            while (iter.next()) |entry| {
                const storage = entry.value_ptr.*;
                if (storage.role == .eis and !storage.has_item) {
                    if (storage.accepts == null or storage.accepts.? == item_type) {
                        return entry.key_ptr.*;
                    }
                }
            }
            return null;
        }

        /// Find an empty EIS that accepts the given item type, excluding specific storages.
        /// Returns null if no suitable EIS found.
        /// Note: Does not check reservations — use findDestinationForItem for reservation-aware routing.
        pub fn findEmptyEisForItemExcluding(engine: *const EngineType, item_type: Item, excluded: *const std.AutoHashMap(GameId, void)) ?GameId {
            var iter = engine.storages.iterator();
            while (iter.next()) |entry| {
                const storage_id = entry.key_ptr.*;
                const storage = entry.value_ptr.*;
                if (storage.role == .eis and !storage.has_item and !excluded.contains(storage_id)) {
                    if (storage.accepts == null or storage.accepts.? == item_type) {
                        return storage_id;
                    }
                }
            }
            return null;
        }

        /// Get list of idle workers (allocated, caller must free)
        pub fn getIdleWorkers(engine: *EngineType) ![]GameId {
            var list: std.ArrayListUnmanaged(GameId) = .{};
            errdefer list.deinit(engine.allocator);

            var iter = engine.workers.iterator();
            while (iter.next()) |entry| {
                if (entry.value_ptr.state == .Idle) {
                    try list.append(engine.allocator, entry.key_ptr.*);
                }
            }
            return list.toOwnedSlice(engine.allocator);
        }

        /// Evaluate dangling items and try to assign workers.
        /// Uses persistent reserved_storages for reservation tracking.
        /// Snapshots both idle workers and dangling items before iterating
        /// to avoid iterator invalidation from reentrant hook dispatch.
        pub fn evaluateDanglingItems(engine: *EngineType) void {
            if (engine.idle_workers_set.count() == 0) return;

            // Snapshot idle workers into local buffer (reentrancy-safe pattern)
            var idle_buf: std.ArrayListUnmanaged(GameId) = .{};
            defer idle_buf.deinit(engine.allocator);
            idle_buf.ensureTotalCapacity(engine.allocator, engine.idle_workers_set.count()) catch return;
            var idle_iter = engine.idle_workers_set.keyIterator();
            while (idle_iter.next()) |wid| {
                idle_buf.appendAssumeCapacity(wid.*);
            }
            if (idle_buf.items.len == 0) return;

            // Snapshot dangling items to avoid iterator invalidation if hooks
            // modify dangling_items during dispatch (e.g., addDanglingItem/removeDanglingItem)
            const DanglingEntry = struct { id: GameId, item_type: Item };
            var dangling_snapshot: std.ArrayListUnmanaged(DanglingEntry) = .{};
            defer dangling_snapshot.deinit(engine.allocator);
            dangling_snapshot.ensureTotalCapacity(engine.allocator, engine.dangling_items.count()) catch return;
            var snap_iter = engine.dangling_items.iterator();
            while (snap_iter.next()) |entry| {
                dangling_snapshot.appendAssumeCapacity(.{ .id = entry.key_ptr.*, .item_type = entry.value_ptr.* });
            }

            log.debug("evaluateDanglingItems: {d} idle workers, {d} dangling items", .{
                idle_buf.items.len,
                dangling_snapshot.items.len,
            });

            // Track items already assigned to workers (from prior evaluations or in-flight deliveries)
            var assigned_items = std.AutoHashMap(GameId, GameId).init(engine.allocator);
            defer assigned_items.deinit();
            var worker_scan = engine.workers.iterator();
            while (worker_scan.next()) |worker_entry| {
                if (worker_entry.value_ptr.dangling_task) |task| {
                    assigned_items.put(task.item_id, worker_entry.key_ptr.*) catch return;
                }
            }

            // Track workers assigned during this evaluation to prevent double-assignment
            var assigned_workers = std.AutoHashMap(GameId, void).init(engine.allocator);
            defer assigned_workers.deinit();

            // For each dangling item, try to find a worker and destination
            for (dangling_snapshot.items) |dangling_entry| {
                const item_id = dangling_entry.id;
                const item_type = dangling_entry.item_type;

                if (assigned_items.get(item_id)) |assigned_worker_id| {
                    log.debug("evaluateDanglingItems: item {d} already assigned to worker {d}, skipping", .{
                        item_id,
                        assigned_worker_id,
                    });
                    continue;
                }

                // Use findDestinationForItem which checks reservations and prefers EIS over standalone
                const target = engine.findDestinationForItem(item_type) orelse continue;
                const worker_id = engine.findNearest(item_id, idle_buf.items) orelse continue;

                if (assigned_workers.contains(worker_id)) {
                    log.debug("evaluateDanglingItems: worker {d} already assigned in this evaluation, skipping item {d}", .{
                        worker_id,
                        item_id,
                    });
                    continue;
                }

                if (engine.workers.getPtr(worker_id)) |worker| {
                    log.debug("evaluateDanglingItems: assigning worker {d} to item {d}", .{
                        worker_id,
                        item_id,
                    });

                    // Track assignments first; abort on OOM before mutating worker
                    // state to prevent permanently stuck workers
                    assigned_workers.put(worker_id, {}) catch return;
                    assigned_items.put(item_id, worker_id) catch return;

                    worker.state = .Working;
                    engine.markWorkerBusy(worker_id);
                    worker.dangling_task = .{
                        .item_id = item_id,
                        .target_storage_id = target,
                    };

                    // Reserve the destination storage
                    engine.reserveStorage(target, worker_id);

                    engine.dispatcher.dispatch(.{ .pickup_dangling_started = .{
                        .worker_id = worker_id,
                        .item_id = item_id,
                        .item_type = item_type,
                        .target_storage_id = target,
                    } });

                    for (idle_buf.items, 0..) |id, i| {
                        if (id == worker_id) {
                            _ = idle_buf.swapRemove(i);
                            break;
                        }
                    }
                    if (idle_buf.items.len == 0) return;
                    continue;
                }
            }
        }
    };
}
