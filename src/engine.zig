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

        // Hook dispatcher
        dispatcher: Dispatcher,

        // Callback for worker selection
        find_best_worker_fn: ?*const fn (workstation_id: ?GameId, available_workers: []const GameId) ?GameId = null,

        pub fn init(allocator: Allocator, task_hooks: TaskHooks) Self {
            return .{
                .allocator = allocator,
                .storages = std.AutoHashMap(GameId, StorageState).init(allocator),
                .workers = std.AutoHashMap(GameId, WorkerData).init(allocator),
                .workstations = std.AutoHashMap(GameId, WorkstationData).init(allocator),
                .dispatcher = Dispatcher.init(task_hooks),
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
        }

        // ============================================
        // Registration API
        // ============================================

        /// Register a storage with the engine
        pub fn addStorage(self: *Self, storage_id: GameId, item_type: ?Item) !void {
            try self.storages.put(storage_id, .{
                .has_item = item_type != null,
                .item_type = item_type,
            });
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
    };
}

// ============================================
// Convenience wrapper
// ============================================

/// Create an engine with hooks
pub fn EngineWithHooks(comptime GameId: type, comptime Item: type, comptime Hooks: type) type {
    return Engine(GameId, Item, Hooks);
}
