//! Pure state machine task orchestration engine
//! Tracks abstract workflow state, emits hooks to game
//! Never mutates game state - only updates internal abstract state

const std = @import("std");
const Allocator = std.mem.Allocator;

const hooks_mod = @import("hooks.zig");
const types = @import("types.zig");
const state_mod = @import("state.zig");
const handlers_mod = @import("handlers.zig");
const helpers_mod = @import("helpers.zig");

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

        // Import handlers and helpers
        const EventHandlers = handlers_mod.Handlers(GameId, Item, Self);
        const EngineHelpers = helpers_mod.Helpers(GameId, Item, Self);

        // State maps
        allocator: Allocator,
        storages: std.AutoHashMap(GameId, StorageState),
        workers: std.AutoHashMap(GameId, WorkerData),
        workstations: std.AutoHashMap(GameId, WorkstationData),
        dangling_items: std.AutoHashMap(GameId, Item),

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
                .dispatcher = Dispatcher.init(task_hooks),
                .distance_fn = distance_fn,
            };
        }

        pub fn deinit(self: *Self) void {
            // Free workstation storage slices
            var ws_iter = self.workstations.valueIterator();
            while (ws_iter.next()) |ws| {
                self.allocator.free(ws.eis);
                self.allocator.free(ws.iis);
                self.allocator.free(ws.ios);
                self.allocator.free(ws.eos);
            }
            self.workstations.deinit();
            self.workers.deinit();
            self.storages.deinit();
            self.dangling_items.deinit();
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
        };

        /// Register a storage with the engine
        pub fn addStorage(self: *Self, storage_id: GameId, config: StorageConfig) !void {
            try self.storages.put(storage_id, .{
                .has_item = config.initial_item != null,
                .item_type = config.initial_item,
                .role = config.role,
                .accepts = config.accepts,
            });

            // If an empty EIS was added, check if any dangling items can be delivered
            if (config.role == .eis and config.initial_item == null) {
                self.evaluateDanglingItems();
            }
        }

        /// Register a worker with the engine
        pub fn addWorker(self: *Self, worker_id: GameId) !void {
            try self.workers.put(worker_id, .{});
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
            // Copy the storage ID slices since they may be stack-allocated
            const eis = try self.allocator.dupe(GameId, config.eis);
            errdefer self.allocator.free(eis);
            const iis = try self.allocator.dupe(GameId, config.iis);
            errdefer self.allocator.free(iis);
            const ios = try self.allocator.dupe(GameId, config.ios);
            errdefer self.allocator.free(ios);
            const eos = try self.allocator.dupe(GameId, config.eos);
            errdefer self.allocator.free(eos);

            try self.workstations.put(workstation_id, .{
                .eis = eis,
                .iis = iis,
                .ios = ios,
                .eos = eos,
                .priority = config.priority,
            });

            // Evaluate initial status
            self.evaluateWorkstationStatus(workstation_id);
        }

        /// Remove a workstation from the engine
        pub fn removeWorkstation(self: *Self, workstation_id: GameId) void {
            if (self.workstations.fetchRemove(workstation_id)) |kv| {
                self.allocator.free(kv.value.eis);
                self.allocator.free(kv.value.iis);
                self.allocator.free(kv.value.ios);
                self.allocator.free(kv.value.eos);
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

            // Append storage to appropriate array based on role
            // Create new slice with additional element, copy old data, free old slice
            switch (role) {
                .eis => {
                    const new_eis = try self.allocator.alloc(GameId, ws.eis.len + 1);
                    @memcpy(new_eis[0..ws.eis.len], ws.eis);
                    new_eis[ws.eis.len] = storage_id;
                    // Initialize bit based on current storage state
                    if (self.storages.get(storage_id)) |storage| {
                        if (storage.has_item) ws.eis_filled.set(ws.eis.len);
                    }
                    self.allocator.free(ws.eis);
                    ws.eis = new_eis;
                },
                .iis => {
                    const new_iis = try self.allocator.alloc(GameId, ws.iis.len + 1);
                    @memcpy(new_iis[0..ws.iis.len], ws.iis);
                    new_iis[ws.iis.len] = storage_id;
                    if (self.storages.get(storage_id)) |storage| {
                        if (storage.has_item) ws.iis_filled.set(ws.iis.len);
                    }
                    self.allocator.free(ws.iis);
                    ws.iis = new_iis;
                },
                .ios => {
                    const new_ios = try self.allocator.alloc(GameId, ws.ios.len + 1);
                    @memcpy(new_ios[0..ws.ios.len], ws.ios);
                    new_ios[ws.ios.len] = storage_id;
                    if (self.storages.get(storage_id)) |storage| {
                        if (storage.has_item) ws.ios_filled.set(ws.ios.len);
                    }
                    self.allocator.free(ws.ios);
                    ws.ios = new_ios;
                },
                .eos => {
                    const new_eos = try self.allocator.alloc(GameId, ws.eos.len + 1);
                    @memcpy(new_eos[0..ws.eos.len], ws.eos);
                    new_eos[ws.eos.len] = storage_id;
                    if (self.storages.get(storage_id)) |storage| {
                        if (storage.has_item) ws.eos_filled.set(ws.eos.len);
                    }
                    self.allocator.free(ws.eos);
                    ws.eos = new_eos;
                },
            }

            // Re-evaluate workstation status after adding storage
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
            return switch (payload) {
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

        pub fn tryAssignWorkers(self: *Self) void {
            EngineHelpers.tryAssignWorkers(self);
        }

        pub fn selectEis(self: *Self, workstation_id: GameId) ?GameId {
            return EngineHelpers.selectEis(self, workstation_id);
        }

        pub fn selectEos(self: *Self, workstation_id: GameId) ?GameId {
            return EngineHelpers.selectEos(self, workstation_id);
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

        /// Get distance between two entities.
        /// Returns null only if distance_fn returns null (no path exists).
        /// If no distance_fn provided, assumes distance is 1.0.
        pub fn getDistance(self: *const Self, from: GameId, to: GameId) ?f32 {
            if (self.distance_fn) |df| {
                return df(from, to);
            }
            return 1.0; // No distance service - assume all distances are equal
        }

        /// Find nearest entity to a target from a list of candidates.
        /// Works for any entity type: workers, storages, workstations.
        /// Returns null if candidates is empty or all candidates are unreachable.
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
        // Dangling Items API
        // ============================================

        /// Register a dangling item (item not in any storage)
        pub fn addDanglingItem(self: *Self, item_id: GameId, item_type: Item) !void {
            try self.dangling_items.put(item_id, item_type);
            // Evaluate if any idle worker can pick up this item
            self.evaluateDanglingItems();
        }

        /// Remove a dangling item (picked up or despawned)
        pub fn removeDanglingItem(self: *Self, item_id: GameId) void {
            _ = self.dangling_items.remove(item_id);
        }

        /// Get the item type of a dangling item
        pub fn getDanglingItemType(self: *const Self, item_id: GameId) ?Item {
            return self.dangling_items.get(item_id);
        }

        /// Find an empty EIS that accepts the given item type.
        /// Returns null if no suitable EIS found.
        pub fn findEmptyEisForItem(self: *const Self, item_type: Item) ?GameId {
            var iter = self.storages.iterator();
            while (iter.next()) |entry| {
                const storage = entry.value_ptr.*;
                // Must be EIS, must be empty, must accept this item type
                if (storage.role == .eis and !storage.has_item) {
                    // accepts == null means accepts any item
                    if (storage.accepts == null or storage.accepts.? == item_type) {
                        return entry.key_ptr.*;
                    }
                }
            }
            return null;
        }

        /// Get list of idle workers (allocated, caller must free)
        pub fn getIdleWorkers(self: *Self) ![]GameId {
            var list = std.ArrayListUnmanaged(GameId){};
            errdefer list.deinit(self.allocator);

            var iter = self.workers.iterator();
            while (iter.next()) |entry| {
                if (entry.value_ptr.state == .Idle) {
                    try list.append(self.allocator, entry.key_ptr.*);
                }
            }
            return list.toOwnedSlice(self.allocator);
        }

        /// Evaluate dangling items and try to assign workers
        pub fn evaluateDanglingItems(self: *Self) void {
            // Get idle workers (we need to free this later)
            const idle_workers = self.getIdleWorkers() catch return;
            defer self.allocator.free(idle_workers);

            if (idle_workers.len == 0) return;

            // For each dangling item, try to find a worker and EIS
            var dangling_iter = self.dangling_items.iterator();
            while (dangling_iter.next()) |entry| {
                const item_id = entry.key_ptr.*;
                const item_type = entry.value_ptr.*;

                // Find an empty EIS that accepts this item type
                const target_eis = self.findEmptyEisForItem(item_type) orelse continue;

                // Find nearest idle worker to the dangling item
                const worker_id = self.findNearest(item_id, idle_workers) orelse continue;

                // Assign worker to pick up this dangling item
                if (self.workers.getPtr(worker_id)) |worker| {
                    worker.state = .Working;
                    worker.dangling_task = .{
                        .item_id = item_id,
                        .target_eis_id = target_eis,
                    };

                    // Dispatch hook to notify game
                    self.dispatcher.dispatch(.{ .pickup_dangling_started = .{
                        .worker_id = worker_id,
                        .item_id = item_id,
                        .item_type = item_type,
                        .target_eis_id = target_eis,
                    } });

                    // Only assign one item per evaluation cycle
                    // (we'd need to refresh idle_workers list for more)
                    return;
                }
            }
        }

        // ============================================
        // ECS Bridge Interface
        // ============================================

        const ecs_bridge = @import("ecs_bridge.zig");
        pub const EcsInterface = ecs_bridge.EcsInterface(GameId, Item);

        /// Get the ECS bridge interface for this engine.
        /// Used by games to connect tasks components to the engine.
        ///
        /// Usage:
        /// ```zig
        /// var task_engine = tasks.Engine(u64, Item, Hooks).init(allocator, .{});
        /// tasks.setEngineInterface(u64, Item, task_engine.interface());
        /// ```
        pub fn interface(self: *Self) EcsInterface {
            return .{
                .ptr = self,
                .vtable = &vtable,
            };
        }

        const vtable = EcsInterface.VTable{
            .addStorage = addStorageVTable,
            .removeStorage = removeStorageVTable,
            .attachStorageToWorkstation = attachStorageToWorkstationVTable,
            .addWorker = addWorkerVTable,
            .removeWorker = removeWorkerVTable,
            .workerAvailable = workerAvailableVTable,
            .addDanglingItem = addDanglingItemVTable,
            .removeDanglingItem = removeDanglingItemVTable,
            .addWorkstation = addWorkstationVTable,
            .removeWorkstation = removeWorkstationVTable,
        };

        fn addStorageVTable(ptr: *anyopaque, id: GameId, role: StorageRole, initial_item: ?Item, accepts: ?Item) anyerror!void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            try self.addStorage(id, .{
                .role = role,
                .initial_item = initial_item,
                .accepts = accepts,
            });
        }

        fn removeStorageVTable(ptr: *anyopaque, id: GameId) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            _ = self.storages.remove(id);
        }

        fn attachStorageToWorkstationVTable(ptr: *anyopaque, storage_id: GameId, workstation_id: GameId, role: StorageRole) anyerror!void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            try self.attachStorageToWorkstation(storage_id, workstation_id, role);
        }

        fn addWorkerVTable(ptr: *anyopaque, id: GameId) anyerror!void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            try self.addWorker(id);
        }

        fn removeWorkerVTable(ptr: *anyopaque, id: GameId) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            _ = self.handle(.{ .worker_removed = .{ .worker_id = id } });
        }

        fn workerAvailableVTable(ptr: *anyopaque, id: GameId) bool {
            const self: *Self = @ptrCast(@alignCast(ptr));
            return self.handle(.{ .worker_available = .{ .worker_id = id } });
        }

        fn addDanglingItemVTable(ptr: *anyopaque, id: GameId, item_type: Item) anyerror!void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            try self.addDanglingItem(id, item_type);
        }

        fn removeDanglingItemVTable(ptr: *anyopaque, id: GameId) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.removeDanglingItem(id);
        }

        fn addWorkstationVTable(ptr: *anyopaque, id: GameId) anyerror!void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            try self.addWorkstation(id, .{});
        }

        fn removeWorkstationVTable(ptr: *anyopaque, id: GameId) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.removeWorkstation(id);
        }
    };
}
