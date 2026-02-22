//! Pure state machine task orchestration engine
//! Tracks abstract workflow state, emits hooks to game
//! Never mutates game state - only updates internal abstract state

const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.tasks);

const hooks_mod = @import("hooks.zig");
const types = @import("types.zig");
const state_mod = @import("state.zig");
const handlers_mod = @import("handlers.zig");
const helpers_mod = @import("helpers.zig");
const dangling_mod = @import("dangling.zig");
const bridge_mod = @import("bridge.zig");
const registration_mod = @import("registration.zig");
const query_mod = @import("query.zig");
const step_handlers_mod = @import("step_handlers.zig");

// Re-export types for convenience
pub const WorkerState = types.WorkerState;
pub const WorkstationStatus = types.WorkstationStatus;
pub const StepType = types.StepType;
pub const Priority = types.Priority;

/// Pure state machine task orchestration engine
/// Tracks abstract workflow state, emits hooks to game
/// Never mutates game state - only updates internal abstract state
pub fn Engine(
    comptime GameId: type,
    comptime Item: type,
    comptime TaskHooks: type,
) type {
    return struct {
        const Self = @This();

        pub const TaskPayload = hooks_mod.TaskHookPayload(GameId, Item);
        pub const GamePayload = hooks_mod.GameHookPayload(GameId, Item);
        const Dispatcher = hooks_mod.HookDispatcher(GameId, Item, TaskHooks);

        /// Distance function type - returns distance between two entities, or null if no path
        pub const DistanceFn = *const fn (from_id: GameId, to_id: GameId) ?f32;

        // Import state types
        const StorageState = state_mod.StorageState(Item);
        const WorkerData = state_mod.WorkerData(GameId);
        const WorkstationData = state_mod.WorkstationData(GameId);

        // Import delegated modules
        const EventHandlers = handlers_mod.Handlers(GameId, Item, Self);
        const EngineHelpers = helpers_mod.Helpers(GameId, Item, Self);
        const DanglingMgr = dangling_mod.DanglingManager(GameId, Item, Self);
        const BridgeFns = bridge_mod.VTableBridge(GameId, Item, Self);
        const Reg = registration_mod.Registration(GameId, Item, Self);
        const QueryAPI = query_mod.Query(GameId, Item, Self);
        const StepHandlers = step_handlers_mod.StepHandlers(GameId, Item, Self);

        // State maps
        allocator: Allocator,
        storages: std.AutoHashMap(GameId, StorageState),
        workers: std.AutoHashMap(GameId, WorkerData),
        workstations: std.AutoHashMap(GameId, WorkstationData),
        dangling_items: std.AutoHashMap(GameId, Item),

        // Status tracking sets (eliminate per-tick allocations)
        idle_workers_set: std.AutoHashMap(GameId, void),
        queued_workstations_set: std.AutoHashMap(GameId, void),

        // Reverse index: storage_id → workstation_ids that reference it
        storage_to_workstations: std.AutoHashMap(GameId, std.ArrayListUnmanaged(GameId)),

        // Storage reservations: storage_id → worker_id (destination spoken for)
        reserved_storages: std.AutoHashMap(GameId, GameId),

        // Transport item tracking: worker_id → Item (set on pickup, cleared on delivery)
        transport_items: std.AutoHashMap(GameId, Item),

        // Hook dispatcher
        dispatcher: Dispatcher,

        // Optional distance function for spatial queries
        distance_fn: ?DistanceFn = null,

        // Callback for worker selection
        find_best_worker_fn: ?*const fn (workstation_id: ?GameId, available_workers: []const GameId) ?GameId = null,

        // Deferred evaluation dirty flags (set by handlers, processed at end of handle())
        needs_dangling_eval: bool = false,
        needs_worker_eval: bool = false,
        needs_transport_eval: bool = false,

        pub fn init(allocator: Allocator, task_hooks: TaskHooks, distance_fn: ?DistanceFn) Self {
            return .{
                .allocator = allocator,
                .storages = std.AutoHashMap(GameId, StorageState).init(allocator),
                .workers = std.AutoHashMap(GameId, WorkerData).init(allocator),
                .workstations = std.AutoHashMap(GameId, WorkstationData).init(allocator),
                .dangling_items = std.AutoHashMap(GameId, Item).init(allocator),
                .idle_workers_set = std.AutoHashMap(GameId, void).init(allocator),
                .queued_workstations_set = std.AutoHashMap(GameId, void).init(allocator),
                .storage_to_workstations = std.AutoHashMap(GameId, std.ArrayListUnmanaged(GameId)).init(allocator),
                .reserved_storages = std.AutoHashMap(GameId, GameId).init(allocator),
                .transport_items = std.AutoHashMap(GameId, Item).init(allocator),
                .dispatcher = Dispatcher.init(task_hooks),
                .distance_fn = distance_fn,
            };
        }

        pub fn deinit(self: *Self) void {
            // Free workstation storage lists
            var ws_iter = self.workstations.valueIterator();
            while (ws_iter.next()) |ws| {
                ws.deinit(self.allocator);
            }
            self.workstations.deinit();
            self.workers.deinit();
            self.storages.deinit();
            self.dangling_items.deinit();
            self.idle_workers_set.deinit();
            self.queued_workstations_set.deinit();
            self.reserved_storages.deinit();
            self.transport_items.deinit();
            // Free reverse index lists
            var ri_iter = self.storage_to_workstations.valueIterator();
            while (ri_iter.next()) |list| {
                list.deinit(self.allocator);
            }
            self.storage_to_workstations.deinit();
        }

        /// Set or update the distance function for spatial queries.
        pub fn setDistanceFunction(self: *Self, func: ?DistanceFn) void {
            self.distance_fn = func;
        }

        // ============================================
        // Registration API (delegated to registration.zig)
        // ============================================

        pub const StorageRole = Reg.StorageRole;
        pub const StorageConfig = Reg.StorageConfig;
        pub const WorkstationConfig = Reg.WorkstationConfig;

        pub fn addStorage(self: *Self, storage_id: GameId, config: StorageConfig) !void {
            return Reg.addStorage(self, storage_id, config);
        }

        pub fn addWorker(self: *Self, worker_id: GameId) !void {
            return Reg.addWorker(self, worker_id);
        }

        pub fn addWorkstation(self: *Self, workstation_id: GameId, config: WorkstationConfig) !void {
            return Reg.addWorkstation(self, workstation_id, config);
        }

        pub fn removeWorkstation(self: *Self, workstation_id: GameId) void {
            Reg.removeWorkstation(self, workstation_id);
        }

        pub fn attachStorageToWorkstation(self: *Self, storage_id: GameId, workstation_id: GameId, role: StorageRole) !void {
            return Reg.attachStorageToWorkstation(self, storage_id, workstation_id, role);
        }

        pub fn setFindBestWorker(self: *Self, callback: *const fn (workstation_id: ?GameId, available_workers: []const GameId) ?GameId) void {
            Reg.setFindBestWorker(self, callback);
        }

        // ============================================
        // Game → Tasks: handle() API
        // ============================================

        /// Main entry point for game notifications
        pub fn handle(self: *Self, payload: GamePayload) bool {
            const result = switch (payload) {
                .item_added => |p| EventHandlers.handleItemAdded(self, p.storage_id, p.item),
                .item_removed => |p| EventHandlers.handleItemRemoved(self, p.storage_id),
                .storage_cleared => |p| EventHandlers.handleStorageCleared(self, p.storage_id),
                .worker_available => |p| EventHandlers.handleWorkerAvailable(self, p.worker_id),
                .worker_unavailable => |p| EventHandlers.handleWorkerUnavailable(self, p.worker_id),
                .worker_removed => |p| EventHandlers.handleWorkerRemoved(self, p.worker_id),
                .workstation_enabled => |p| EventHandlers.handleWorkstationEnabled(self, p.workstation_id),
                .workstation_disabled => |p| EventHandlers.handleWorkstationDisabled(self, p.workstation_id),
                .workstation_removed => |p| EventHandlers.handleWorkstationRemoved(self, p.workstation_id),
                .pickup_completed => |p| StepHandlers.handlePickupCompleted(self, p.worker_id),
                .work_completed => |p| StepHandlers.handleWorkCompleted(self, p.workstation_id),
                .store_completed => |p| StepHandlers.handleStoreCompleted(self, p.worker_id),
                .transport_pickup_completed => |p| EventHandlers.handleTransportPickupCompleted(self, p.worker_id),
                .transport_delivery_completed => |p| EventHandlers.handleTransportDeliveryCompleted(self, p.worker_id),
            };

            result catch |err| {
                log.warn("handle: event failed with {}", .{err});
                self.processDeferredEvaluations();
                return false;
            };
            self.processDeferredEvaluations();
            return true;
        }

        // ============================================
        // Deferred evaluation processing
        // ============================================

        /// Maximum iterations for deferred evaluation loop to prevent infinite cycles.
        const max_deferred_iterations = 10;

        /// Process all deferred evaluations in priority order.
        /// Loops until no dirty flags remain (max iterations to prevent infinite loops).
        /// Priority order: dangling items > worker assignment > transports.
        pub fn processDeferredEvaluations(self: *Self) void {
            var iterations: u32 = 0;
            while (iterations < max_deferred_iterations) : (iterations += 1) {
                if (self.needs_dangling_eval) {
                    self.needs_dangling_eval = false;
                    self.evaluateDanglingItems();
                } else if (self.needs_worker_eval) {
                    self.needs_worker_eval = false;
                    self.tryAssignWorkers();
                } else if (self.needs_transport_eval) {
                    self.needs_transport_eval = false;
                    self.evaluateTransports();
                } else {
                    break;
                }
            }

            if (self.needs_dangling_eval or self.needs_worker_eval or self.needs_transport_eval) {
                log.warn("processDeferredEvaluations: flags still dirty after {} iterations (dangling={}, worker={}, transport={})", .{
                    max_deferred_iterations,
                    self.needs_dangling_eval,
                    self.needs_worker_eval,
                    self.needs_transport_eval,
                });
                // Clear flags to avoid stale state carrying over to next handle() call
                self.needs_dangling_eval = false;
                self.needs_worker_eval = false;
                self.needs_transport_eval = false;
            }
        }

        // ============================================
        // Convenience methods for handle()
        // ============================================

        pub fn itemAdded(self: *Self, storage_id: GameId, item: Item) bool {
            return self.handle(.{ .item_added = .{ .storage_id = storage_id, .item = item } });
        }

        pub fn itemRemoved(self: *Self, storage_id: GameId) bool {
            return self.handle(.{ .item_removed = .{ .storage_id = storage_id } });
        }

        pub fn workerAvailable(self: *Self, worker_id: GameId) bool {
            return self.handle(.{ .worker_available = .{ .worker_id = worker_id } });
        }

        pub fn pickupCompleted(self: *Self, worker_id: GameId) bool {
            return self.handle(.{ .pickup_completed = .{ .worker_id = worker_id } });
        }

        pub fn workCompleted(self: *Self, workstation_id: GameId) bool {
            return self.handle(.{ .work_completed = .{ .workstation_id = workstation_id } });
        }

        pub fn storeCompleted(self: *Self, worker_id: GameId) bool {
            return self.handle(.{ .store_completed = .{ .worker_id = worker_id } });
        }

        pub fn transportPickupCompleted(self: *Self, worker_id: GameId) bool {
            return self.handle(.{ .transport_pickup_completed = .{ .worker_id = worker_id } });
        }

        pub fn transportDeliveryCompleted(self: *Self, worker_id: GameId) bool {
            return self.handle(.{ .transport_delivery_completed = .{ .worker_id = worker_id } });
        }

        // ============================================
        // Internal helpers (delegated to helpers.zig)
        // ============================================

        pub fn evaluateWorkstationStatus(self: *Self, workstation_id: GameId) void {
            EngineHelpers.evaluateWorkstationStatus(self, workstation_id);
        }

        pub fn reevaluateWorkstations(self: *Self) void {
            EngineHelpers.reevaluateWorkstations(self);
        }

        /// Re-evaluate only workstations affected by a specific storage change.
        /// Uses the reverse index instead of scanning all workstations.
        /// Snapshots IDs before iterating to avoid use-after-free if hooks
        /// modify storage_to_workstations during evaluation.
        pub fn reevaluateAffectedWorkstations(self: *Self, storage_id: GameId) void {
            if (self.storage_to_workstations.get(storage_id)) |ws_ids| {
                // Snapshot workstation IDs to avoid dangling pointer if the list
                // is freed by a reentrant removeStorage call during evaluation
                var snapshot: std.ArrayListUnmanaged(GameId) = .{};
                defer snapshot.deinit(self.allocator);
                snapshot.appendSlice(self.allocator, ws_ids.items) catch {
                    // On OOM, skip evaluation but still set dirty flag
                    self.needs_worker_eval = true;
                    return;
                };
                for (snapshot.items) |ws_id| {
                    self.evaluateWorkstationStatus(ws_id);
                }
            }
            self.needs_worker_eval = true;
        }

        pub fn tryAssignWorkers(self: *Self) void {
            EngineHelpers.tryAssignWorkers(self);
        }

        pub fn selectEis(self: *Self, workstation_id: GameId) ?GameId {
            return EngineHelpers.selectEis(self, workstation_id);
        }

        pub fn selectEos(self: *Self, workstation_id: GameId) ?GameId {
            return EngineHelpers.selectEos(self, workstation_id);
        }

        pub fn canWorkstationOperate(self: *Self, ws: *const WorkstationData) bool {
            return EngineHelpers.canWorkstationOperate(self, ws);
        }

        // ============================================
        // Reverse Index helpers
        // ============================================

        pub fn addReverseIndexEntry(self: *Self, storage_id: GameId, workstation_id: GameId) void {
            const gop = self.storage_to_workstations.getOrPut(storage_id) catch {
                std.log.err("[tasks] addReverseIndexEntry: failed to allocate for storage {}", .{storage_id});
                return;
            };
            if (!gop.found_existing) {
                gop.value_ptr.* = .{};
            }
            for (gop.value_ptr.items) |existing_id| {
                if (existing_id == workstation_id) return;
            }
            gop.value_ptr.append(self.allocator, workstation_id) catch {
                std.log.err("[tasks] addReverseIndexEntry: failed to append workstation {} for storage {}", .{ workstation_id, storage_id });
            };
        }

        pub fn removeReverseIndexEntry(self: *Self, storage_id: GameId, workstation_id: GameId) void {
            const list = self.storage_to_workstations.getPtr(storage_id) orelse return;
            for (list.items, 0..) |id, i| {
                if (id == workstation_id) {
                    _ = list.swapRemove(i);
                    break;
                }
            }
            if (list.items.len == 0) {
                list.deinit(self.allocator);
                _ = self.storage_to_workstations.remove(storage_id);
            }
        }

        // ============================================
        // Status tracking set operations
        // ============================================

        pub fn markWorkerIdle(self: *Self, worker_id: GameId) void {
            self.idle_workers_set.put(worker_id, {}) catch
                @panic("markWorkerIdle: allocation failed, engine state is inconsistent");
        }

        pub fn markWorkerBusy(self: *Self, worker_id: GameId) void {
            _ = self.idle_workers_set.remove(worker_id);
        }

        pub fn removeWorkerTracking(self: *Self, worker_id: GameId) void {
            _ = self.idle_workers_set.remove(worker_id);
        }

        pub fn markWorkstationQueued(self: *Self, workstation_id: GameId) void {
            self.queued_workstations_set.put(workstation_id, {}) catch
                @panic("markWorkstationQueued: allocation failed, engine state is inconsistent");
        }

        pub fn markWorkstationNotQueued(self: *Self, workstation_id: GameId) void {
            _ = self.queued_workstations_set.remove(workstation_id);
        }

        pub fn removeWorkstationTracking(self: *Self, workstation_id: GameId) void {
            _ = self.queued_workstations_set.remove(workstation_id);
        }

        // ============================================
        // Query API (delegated to query.zig)
        // ============================================

        pub const StorageInfo = QueryAPI.StorageInfo;
        pub const WorkerInfo = QueryAPI.WorkerInfo;
        pub const WorkstationInfo = QueryAPI.WorkstationInfo;
        pub const EngineCounts = QueryAPI.EngineCounts;

        pub fn getWorkerState(self: *const Self, worker_id: GameId) ?WorkerState {
            return QueryAPI.getWorkerState(self, worker_id);
        }

        pub fn getWorkerCurrentStep(self: *const Self, worker_id: GameId) ?StepType {
            return QueryAPI.getWorkerCurrentStep(self, worker_id);
        }

        pub fn getWorkstationStatus(self: *const Self, workstation_id: GameId) ?WorkstationStatus {
            return QueryAPI.getWorkstationStatus(self, workstation_id);
        }

        pub fn getStorageHasItem(self: *const Self, storage_id: GameId) ?bool {
            return QueryAPI.getStorageHasItem(self, storage_id);
        }

        pub fn getStorageItemType(self: *const Self, storage_id: GameId) ?Item {
            return QueryAPI.getStorageItemType(self, storage_id);
        }

        pub fn getStorageInfo(self: *const Self, storage_id: GameId) ?StorageInfo {
            return QueryAPI.getStorageInfo(self, storage_id);
        }

        pub fn getWorkerInfo(self: *const Self, worker_id: GameId) ?WorkerInfo {
            return QueryAPI.getWorkerInfo(self, worker_id);
        }

        pub fn getWorkstationInfo(self: *const Self, workstation_id: GameId) ?WorkstationInfo {
            return QueryAPI.getWorkstationInfo(self, workstation_id);
        }

        pub fn isStorageFull(self: *const Self, storage_id: GameId) bool {
            return QueryAPI.isStorageFull(self, storage_id);
        }

        pub fn getWorkerAssignment(self: *const Self, worker_id: GameId) ?GameId {
            return QueryAPI.getWorkerAssignment(self, worker_id);
        }

        pub fn getCounts(self: *const Self) EngineCounts {
            return QueryAPI.getCounts(self);
        }

        pub fn dumpState(self: *const Self, writer: anytype) !void {
            return QueryAPI.dumpState(self, writer);
        }

        // ============================================
        // Distance API
        // ============================================

        /// Get distance between two entities. Returns 1.0 if no distance_fn is set.
        pub fn getDistance(self: *const Self, from: GameId, to: GameId) ?f32 {
            if (self.distance_fn) |df| {
                return df(from, to);
            }
            return 1.0;
        }

        /// Find nearest candidate to target. Returns null if candidates is empty or all candidates are unreachable.
        pub fn findNearest(self: *const Self, target: GameId, candidates: []const GameId) ?GameId {
            if (candidates.len == 0) return null;

            var best: ?GameId = null;
            var best_dist: f32 = std.math.floatMax(f32);

            for (candidates) |candidate| {
                if (self.getDistance(candidate, target)) |dist| {
                    if (dist < best_dist) {
                        best_dist = dist;
                        best = candidate;
                    }
                }
            }
            return best;
        }

        // ============================================
        // Dangling Items API (delegated to dangling.zig)
        // ============================================

        pub fn addDanglingItem(self: *Self, item_id: GameId, item_type: Item) !void {
            return DanglingMgr.addDanglingItem(self, item_id, item_type);
        }

        pub fn removeDanglingItem(self: *Self, item_id: GameId) void {
            DanglingMgr.removeDanglingItem(self, item_id);
        }

        pub fn getDanglingItemType(self: *const Self, item_id: GameId) ?Item {
            return DanglingMgr.getDanglingItemType(self, item_id);
        }

        pub fn findEmptyEisForItem(self: *const Self, item_type: Item) ?GameId {
            return DanglingMgr.findEmptyEisForItem(self, item_type);
        }

        pub fn findEmptyEisForItemExcluding(self: *const Self, item_type: Item, excluded: *const std.AutoHashMap(GameId, void)) ?GameId {
            return DanglingMgr.findEmptyEisForItemExcluding(self, item_type, excluded);
        }

        pub fn getIdleWorkers(self: *Self) ![]GameId {
            return DanglingMgr.getIdleWorkers(self);
        }

        pub fn evaluateDanglingItems(self: *Self) void {
            DanglingMgr.evaluateDanglingItems(self);
        }

        // ============================================
        // Storage Reservations
        // ============================================

        /// Reserve a storage as a delivery destination for a worker.
        pub fn reserveStorage(self: *Self, storage_id: GameId, worker_id: GameId) void {
            self.reserved_storages.put(storage_id, worker_id) catch {
                log.err("reserveStorage: failed to reserve storage {} for worker {}", .{ storage_id, worker_id });
            };
        }

        /// Release a reservation on a storage.
        pub fn releaseReservation(self: *Self, storage_id: GameId) void {
            _ = self.reserved_storages.remove(storage_id);
        }

        /// Release all reservations held by a worker.
        /// Uses the worker's task data directly (no allocation needed).
        pub fn releaseWorkerReservations(self: *Self, worker_id: GameId) void {
            if (self.workers.get(worker_id)) |worker| {
                if (worker.dangling_task) |task| {
                    self.releaseReservation(task.target_storage_id);
                }
                if (worker.transport_task) |task| {
                    self.releaseReservation(task.to_storage_id);
                }
            }
        }

        /// Check if a storage is reserved.
        pub fn isStorageReserved(self: *const Self, storage_id: GameId) bool {
            return self.reserved_storages.contains(storage_id);
        }

        // ============================================
        // Destination Routing
        // ============================================

        /// Find the best destination for an item: EIS first, standalone fallback.
        /// Skips full and reserved storages.
        pub fn findDestinationForItem(self: *const Self, item_type: Item) ?GameId {
            return self.findDestinationForItemImpl(item_type, null);
        }

        /// Find the best destination for an item, excluding specific storages.
        pub fn findDestinationForItemExcluding(self: *const Self, item_type: Item, excluded: *const std.AutoHashMap(GameId, void)) ?GameId {
            return self.findDestinationForItemImpl(item_type, excluded);
        }

        fn findDestinationForItemImpl(self: *const Self, item_type: Item, excluded: ?*const std.AutoHashMap(GameId, void)) ?GameId {
            // Pass 1: EIS (highest priority wins)
            var best_eis: ?GameId = null;
            var best_eis_priority: i16 = -1;

            // Pass 2: standalone (highest priority wins)
            var best_standalone: ?GameId = null;
            var best_standalone_priority: i16 = -1;

            var iter = self.storages.iterator();
            while (iter.next()) |entry| {
                const storage_id = entry.key_ptr.*;
                const storage = entry.value_ptr.*;

                // Skip full, reserved, or excluded storages
                if (storage.has_item) continue;
                if (self.reserved_storages.contains(storage_id)) continue;
                if (excluded) |ex| {
                    if (ex.contains(storage_id)) continue;
                }

                // Check item type compatibility
                if (storage.accepts != null and storage.accepts.? != item_type) continue;

                const priority: i16 = @intFromEnum(storage.priority);

                if (storage.role == .eis) {
                    if (priority > best_eis_priority) {
                        best_eis = storage_id;
                        best_eis_priority = priority;
                    }
                } else if (storage.role == .standalone) {
                    if (priority > best_standalone_priority) {
                        best_standalone = storage_id;
                        best_standalone_priority = priority;
                    }
                }
            }

            // EIS takes priority over standalone
            return best_eis orelse best_standalone;
        }

        // ============================================
        // Transport Evaluation
        // ============================================

        /// Evaluate EOS storages with items and try to assign idle workers
        /// to transport them to a destination (EIS first, standalone fallback).
        pub fn evaluateTransports(self: *Self) void {
            if (self.idle_workers_set.count() == 0) return;

            // Snapshot idle workers (reentrancy-safe)
            var idle_buf: std.ArrayListUnmanaged(GameId) = .{};
            defer idle_buf.deinit(self.allocator);
            idle_buf.ensureTotalCapacity(self.allocator, self.idle_workers_set.count()) catch return;
            var idle_iter = self.idle_workers_set.keyIterator();
            while (idle_iter.next()) |wid| {
                idle_buf.appendAssumeCapacity(wid.*);
            }
            if (idle_buf.items.len == 0) return;

            // Pre-build set of storages already being transported (O(W) single pass)
            var active_sources = std.AutoHashMap(GameId, void).init(self.allocator);
            defer active_sources.deinit();
            var w_scan = self.workers.iterator();
            while (w_scan.next()) |w_entry| {
                if (w_entry.value_ptr.transport_task) |task| {
                    active_sources.put(task.from_storage_id, {}) catch return;
                }
            }

            // Snapshot EOS storages with items (O(S) single pass)
            const EosEntry = struct { id: GameId, item_type: Item };
            var eos_snapshot: std.ArrayListUnmanaged(EosEntry) = .{};
            defer eos_snapshot.deinit(self.allocator);

            var storage_iter = self.storages.iterator();
            while (storage_iter.next()) |entry| {
                const storage = entry.value_ptr.*;
                if (storage.role == .eos and storage.has_item) {
                    if (storage.item_type) |item_type| {
                        if (!active_sources.contains(entry.key_ptr.*)) {
                            eos_snapshot.append(self.allocator, .{ .id = entry.key_ptr.*, .item_type = item_type }) catch return;
                        }
                    }
                }
            }

            // For each EOS with item, try to find a destination and assign a worker
            for (eos_snapshot.items) |eos_entry| {
                if (idle_buf.items.len == 0) break;

                const destination = self.findDestinationForItem(eos_entry.item_type) orelse continue;
                const worker_id = self.findNearest(eos_entry.id, idle_buf.items) orelse continue;

                if (self.workers.getPtr(worker_id)) |worker| {
                    // Assign transport
                    worker.state = .Working;
                    self.markWorkerBusy(worker_id);
                    worker.transport_task = .{
                        .from_storage_id = eos_entry.id,
                        .to_storage_id = destination,
                    };

                    self.reserveStorage(destination, worker_id);

                    self.dispatcher.dispatch(.{ .transport_started = .{
                        .worker_id = worker_id,
                        .from_storage_id = eos_entry.id,
                        .to_storage_id = destination,
                        .item = eos_entry.item_type,
                    } });

                    // Remove worker from idle snapshot
                    for (idle_buf.items, 0..) |id, i| {
                        if (id == worker_id) {
                            _ = idle_buf.swapRemove(i);
                            break;
                        }
                    }
                }
            }
        }

        // ============================================
        // Standalone Query API
        // ============================================

        /// Check if a storage is standalone.
        pub fn isStandalone(self: *const Self, storage_id: GameId) bool {
            const storage = self.storages.get(storage_id) orelse return false;
            return storage.role == .standalone;
        }

        // ============================================
        // ECS Bridge Interface (delegated to bridge.zig)
        // ============================================

        const ecs_bridge = @import("ecs_bridge.zig");
        pub const EcsInterface = ecs_bridge.EcsInterface(GameId, Item);

        pub fn interface(self: *Self) EcsInterface {
            return .{
                .ptr = self,
                .vtable = &BridgeFns.vtable,
            };
        }
    };
}
