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

        // Hook dispatcher
        dispatcher: Dispatcher,

        // Optional distance function for spatial queries
        distance_fn: ?DistanceFn = null,

        // Callback for worker selection
        find_best_worker_fn: ?*const fn (workstation_id: ?GameId, available_workers: []const GameId) ?GameId = null,

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
        // Registration API
        // ============================================

        // Re-export StorageRole for convenience
        pub const StorageRole = state_mod.StorageRole;

        /// Storage configuration for registration
        pub const StorageConfig = struct {
            role: StorageRole = .eis,
            accepts: ?Item = null, // null = accepts any item type
            initial_item: ?Item = null,
            priority: Priority = .Normal,
        };

        /// Register a storage with the engine
        pub fn addStorage(self: *Self, storage_id: GameId, config: StorageConfig) !void {
            try self.storages.put(storage_id, .{
                .has_item = config.initial_item != null,
                .item_type = config.initial_item,
                .role = config.role,
                .accepts = config.accepts,
                .priority = config.priority,
            });

            if (config.role == .eis and config.initial_item == null) {
                self.evaluateDanglingItems();
            }
        }

        /// Register a worker with the engine
        pub fn addWorker(self: *Self, worker_id: GameId) !void {
            try self.workers.put(worker_id, .{});
            errdefer _ = self.workers.remove(worker_id);
            try self.idle_workers_set.put(worker_id, {});
        }

        /// Workstation configuration for registration
        pub const WorkstationConfig = struct {
            eis: []const GameId = &.{},
            iis: []const GameId = &.{},
            ios: []const GameId = &.{},
            eos: []const GameId = &.{},
            priority: Priority = .Normal,
        };

        /// Register a workstation with the engine
        pub fn addWorkstation(self: *Self, workstation_id: GameId, config: WorkstationConfig) !void {
            var eis = std.ArrayListUnmanaged(GameId){};
            errdefer eis.deinit(self.allocator);
            try eis.appendSlice(self.allocator, config.eis);

            var iis = std.ArrayListUnmanaged(GameId){};
            errdefer iis.deinit(self.allocator);
            try iis.appendSlice(self.allocator, config.iis);

            var ios = std.ArrayListUnmanaged(GameId){};
            errdefer ios.deinit(self.allocator);
            try ios.appendSlice(self.allocator, config.ios);

            var eos = std.ArrayListUnmanaged(GameId){};
            errdefer eos.deinit(self.allocator);
            try eos.appendSlice(self.allocator, config.eos);

            try self.workstations.put(workstation_id, .{
                .eis = eis,
                .iis = iis,
                .ios = ios,
                .eos = eos,
                .priority = config.priority,
            });

            const all_storages = [_][]const GameId{ config.eis, config.iis, config.ios, config.eos };
            for (all_storages) |storage_ids| {
                for (storage_ids) |sid| {
                    self.addReverseIndexEntry(sid, workstation_id);
                }
            }

            self.evaluateWorkstationStatus(workstation_id);
        }

        /// Remove a workstation from the engine
        pub fn removeWorkstation(self: *Self, workstation_id: GameId) void {
            if (self.workstations.getPtr(workstation_id)) |ws| {
                if (ws.assigned_worker) |worker_id| {
                    if (self.workers.getPtr(worker_id)) |worker| {
                        worker.state = .Idle;
                        worker.assigned_workstation = null;
                        self.markWorkerIdle(worker_id);
                        self.dispatcher.dispatch(.{ .worker_released = .{ .worker_id = worker_id } });
                    }
                }
            }
            self.removeWorkstationTracking(workstation_id);
            if (self.workstations.fetchRemove(workstation_id)) |kv| {
                const all_storages = [_][]const GameId{ kv.value.eis.items, kv.value.iis.items, kv.value.ios.items, kv.value.eos.items };
                for (all_storages) |storage_ids| {
                    for (storage_ids) |sid| {
                        self.removeReverseIndexEntry(sid, workstation_id);
                    }
                }
                var ws = kv.value;
                ws.deinit(self.allocator);
            }
        }

        /// Attach a storage to a workstation dynamically.
        /// This allows storages to register themselves with their parent workstation
        /// using the parent reference convention (RFC #169).
        pub fn attachStorageToWorkstation(self: *Self, storage_id: GameId, workstation_id: GameId, role: StorageRole) !void {
            const ws = self.workstations.getPtr(workstation_id) orelse {
                std.log.warn("[tasks] attachStorageToWorkstation: workstation {d} not found", .{workstation_id});
                return error.WorkstationNotFound;
            };

            const list = switch (role) {
                .eis => &ws.eis,
                .iis => &ws.iis,
                .ios => &ws.ios,
                .eos => &ws.eos,
            };
            try list.append(self.allocator, storage_id);

            self.addReverseIndexEntry(storage_id, workstation_id);
            self.evaluateWorkstationStatus(workstation_id);
        }

        /// Set the callback for worker selection
        pub fn setFindBestWorker(self: *Self, callback: *const fn (workstation_id: ?GameId, available_workers: []const GameId) ?GameId) void {
            self.find_best_worker_fn = callback;
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
                .pickup_completed => |p| EventHandlers.handlePickupCompleted(self, p.worker_id),
                .work_completed => |p| EventHandlers.handleWorkCompleted(self, p.workstation_id),
                .store_completed => |p| EventHandlers.handleStoreCompleted(self, p.worker_id),
            };

            result catch |err| {
                log.warn("handle: event failed with {}", .{err});
                return false;
            };
            return true;
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

        // ============================================
        // Internal helpers (delegated)
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
                snapshot.appendSlice(self.allocator, ws_ids.items) catch return;
                for (snapshot.items) |ws_id| {
                    self.evaluateWorkstationStatus(ws_id);
                }
            }
            self.tryAssignWorkers();
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

        fn addReverseIndexEntry(self: *Self, storage_id: GameId, workstation_id: GameId) void {
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

        fn removeReverseIndexEntry(self: *Self, storage_id: GameId, workstation_id: GameId) void {
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

        /// Mark a worker as idle in the tracking set
        pub fn markWorkerIdle(self: *Self, worker_id: GameId) void {
            self.idle_workers_set.put(worker_id, {}) catch
                @panic("markWorkerIdle: allocation failed, engine state is inconsistent");
        }

        /// Mark a worker as non-idle in the tracking set
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
        // Query API
        // ============================================

        pub fn getWorkerState(self: *const Self, worker_id: GameId) ?WorkerState {
            const worker = self.workers.get(worker_id) orelse return null;
            return worker.state;
        }

        pub fn getWorkerCurrentStep(self: *const Self, worker_id: GameId) ?StepType {
            const worker = self.workers.get(worker_id) orelse return null;
            const ws_id = worker.assigned_workstation orelse return null;
            const ws = self.workstations.get(ws_id) orelse return null;
            return ws.current_step;
        }

        pub fn getWorkstationStatus(self: *const Self, workstation_id: GameId) ?WorkstationStatus {
            const ws = self.workstations.get(workstation_id) orelse return null;
            return ws.status;
        }

        pub fn getStorageHasItem(self: *const Self, storage_id: GameId) ?bool {
            const storage = self.storages.get(storage_id) orelse return null;
            return storage.has_item;
        }

        pub fn getStorageItemType(self: *const Self, storage_id: GameId) ?Item {
            const storage = self.storages.get(storage_id) orelse return null;
            return storage.item_type;
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

        /// Register a dangling item (item not in any storage) and try to assign a worker.
        pub fn addDanglingItem(self: *Self, item_id: GameId, item_type: Item) !void {
            return DanglingMgr.addDanglingItem(self, item_id, item_type);
        }

        /// Remove a dangling item (picked up or despawned).
        pub fn removeDanglingItem(self: *Self, item_id: GameId) void {
            DanglingMgr.removeDanglingItem(self, item_id);
        }

        /// Get the item type of a dangling item, or null if not found.
        pub fn getDanglingItemType(self: *const Self, item_id: GameId) ?Item {
            return DanglingMgr.getDanglingItemType(self, item_id);
        }

        /// Find an empty EIS that accepts the given item type. Returns null if none found.
        pub fn findEmptyEisForItem(self: *const Self, item_type: Item) ?GameId {
            return DanglingMgr.findEmptyEisForItem(self, item_type);
        }

        /// Find an empty EIS that accepts the given item type, excluding reserved ones. Returns null if none found.
        pub fn findEmptyEisForItemExcluding(self: *const Self, item_type: Item, excluded: *const std.AutoHashMap(GameId, void)) ?GameId {
            return DanglingMgr.findEmptyEisForItemExcluding(self, item_type, excluded);
        }

        /// Get list of idle workers. Caller owns the returned slice and must free it.
        pub fn getIdleWorkers(self: *Self) ![]GameId {
            return DanglingMgr.getIdleWorkers(self);
        }

        /// Evaluate dangling items and try to assign idle workers to pick them up.
        pub fn evaluateDanglingItems(self: *Self) void {
            DanglingMgr.evaluateDanglingItems(self);
        }

        // ============================================
        // ECS Bridge Interface (delegated to bridge.zig)
        // ============================================

        const ecs_bridge = @import("ecs_bridge.zig");
        pub const EcsInterface = ecs_bridge.EcsInterface(GameId, Item);

        /// Get the ECS bridge interface for this engine.
        /// Used by games to connect tasks components to the engine.
        pub fn interface(self: *Self) EcsInterface {
            return .{
                .ptr = self,
                .vtable = &BridgeFns.vtable,
            };
        }
    };
}
