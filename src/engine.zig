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

            // If an empty EIS was added, check if any dangling items can be delivered
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

            // Update reverse index for all storage IDs
            const all_storages = [_][]const GameId{ config.eis, config.iis, config.ios, config.eos };
            for (all_storages) |storage_ids| {
                for (storage_ids) |sid| {
                    self.addReverseIndexEntry(sid, workstation_id);
                }
            }

            // Evaluate initial status
            self.evaluateWorkstationStatus(workstation_id);
        }

        /// Remove a workstation from the engine
        pub fn removeWorkstation(self: *Self, workstation_id: GameId) void {
            // Release assigned worker before removing
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
                // Clean up reverse index entries
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

            // Append storage to appropriate list based on role
            const list = switch (role) {
                .eis => &ws.eis,
                .iis => &ws.iis,
                .ios => &ws.ios,
                .eos => &ws.eos,
            };
            try list.append(self.allocator, storage_id);

            // Update reverse index
            self.addReverseIndexEntry(storage_id, workstation_id);

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
        pub fn reevaluateAffectedWorkstations(self: *Self, storage_id: GameId) void {
            if (self.storage_to_workstations.get(storage_id)) |ws_ids| {
                for (ws_ids.items) |ws_id| {
                    self.evaluateWorkstationStatus(ws_id);
                }
            }
            self.tryAssignWorkers();
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
            // Prevent duplicate entries
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
            // Clean up empty entries
            if (list.items.len == 0) {
                list.deinit(self.allocator);
                _ = self.storage_to_workstations.remove(storage_id);
            }
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

        /// Remove a worker from all tracking sets
        pub fn removeWorkerTracking(self: *Self, worker_id: GameId) void {
            _ = self.idle_workers_set.remove(worker_id);
        }

        /// Mark a workstation as queued in the tracking set
        pub fn markWorkstationQueued(self: *Self, workstation_id: GameId) void {
            self.queued_workstations_set.put(workstation_id, {}) catch
                @panic("markWorkstationQueued: allocation failed, engine state is inconsistent");
        }

        /// Mark a workstation as non-queued in the tracking set
        pub fn markWorkstationNotQueued(self: *Self, workstation_id: GameId) void {
            _ = self.queued_workstations_set.remove(workstation_id);
        }

        /// Remove a workstation from all tracking sets
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
        // Introspection API
        // ============================================

        /// Full storage state snapshot for diagnostics
        pub fn getStorageInfo(self: *const Self, storage_id: GameId) ?StorageInfo {
            const s = self.storages.get(storage_id) orelse return null;
            return .{
                .has_item = s.has_item,
                .item_type = s.item_type,
                .role = s.role,
                .accepts = s.accepts,
                .priority = s.priority,
            };
        }

        pub const StorageInfo = struct {
            has_item: bool,
            item_type: ?Item,
            role: StorageRole,
            accepts: ?Item,
            priority: Priority,
        };

        /// Full worker state snapshot for diagnostics
        pub fn getWorkerInfo(self: *const Self, worker_id: GameId) ?WorkerInfo {
            const w = self.workers.get(worker_id) orelse return null;
            return .{
                .state = w.state,
                .assigned_workstation = w.assigned_workstation,
                .has_dangling_task = w.dangling_task != null,
            };
        }

        pub const WorkerInfo = struct {
            state: WorkerState,
            assigned_workstation: ?GameId,
            has_dangling_task: bool,
        };

        /// Full workstation state snapshot for diagnostics
        pub fn getWorkstationInfo(self: *const Self, workstation_id: GameId) ?WorkstationInfo {
            const ws = self.workstations.get(workstation_id) orelse return null;
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

        /// Check if a storage is full (has an item)
        pub fn isStorageFull(self: *const Self, storage_id: GameId) bool {
            const storage = self.storages.get(storage_id) orelse return false;
            return storage.has_item;
        }

        /// Get the workstation a worker is assigned to (if any)
        pub fn getWorkerAssignment(self: *const Self, worker_id: GameId) ?GameId {
            const worker = self.workers.get(worker_id) orelse return null;
            return worker.assigned_workstation;
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
        pub fn getCounts(self: *const Self) EngineCounts {
            return .{
                .storages = self.storages.count(),
                .workers = self.workers.count(),
                .workstations = self.workstations.count(),
                .dangling_items = self.dangling_items.count(),
                .idle_workers = self.idle_workers_set.count(),
                .queued_workstations = self.queued_workstations_set.count(),
            };
        }

        /// Dump engine state to a writer for diagnostics.
        /// Output is sorted by entity ID for deterministic results.
        pub fn dumpState(self: *const Self, writer: anytype) !void {
            const counts = self.getCounts();
            try writer.print("=== Task Engine State ===\n", .{});
            try writer.print("Storages: {d}  Workers: {d}  Workstations: {d}  Dangling: {d}\n", .{
                counts.storages, counts.workers, counts.workstations, counts.dangling_items,
            });
            try writer.print("Idle workers: {d}  Queued workstations: {d}\n\n", .{
                counts.idle_workers, counts.queued_workstations,
            });

            // Storages (sorted by ID for deterministic output)
            var s_keys: std.ArrayListUnmanaged(GameId) = .{};
            defer s_keys.deinit(self.allocator);
            var s_iter = self.storages.keyIterator();
            while (s_iter.next()) |key| try s_keys.append(self.allocator, key.*);
            std.mem.sort(GameId, s_keys.items, {}, std.sort.asc(GameId));
            for (s_keys.items) |id| {
                const s = self.storages.get(id).?;
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
            defer w_keys.deinit(self.allocator);
            var w_iter = self.workers.keyIterator();
            while (w_iter.next()) |key| try w_keys.append(self.allocator, key.*);
            std.mem.sort(GameId, w_keys.items, {}, std.sort.asc(GameId));
            for (w_keys.items) |id| {
                const w = self.workers.get(id).?;
                try writer.print("  Worker {d}: state={s} ws={?d} dangling={}\n", .{
                    id,
                    @tagName(w.state),
                    w.assigned_workstation,
                    w.dangling_task != null,
                });
            }

            // Workstations (sorted by ID)
            var ws_keys: std.ArrayListUnmanaged(GameId) = .{};
            defer ws_keys.deinit(self.allocator);
            var ws_iter = self.workstations.keyIterator();
            while (ws_iter.next()) |key| try ws_keys.append(self.allocator, key.*);
            std.mem.sort(GameId, ws_keys.items, {}, std.sort.asc(GameId));
            for (ws_keys.items) |id| {
                const ws = self.workstations.get(id).?;
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
            if (self.dangling_items.count() > 0) {
                var d_keys: std.ArrayListUnmanaged(GameId) = .{};
                defer d_keys.deinit(self.allocator);
                var d_iter = self.dangling_items.keyIterator();
                while (d_iter.next()) |key| try d_keys.append(self.allocator, key.*);
                std.mem.sort(GameId, d_keys.items, {}, std.sort.asc(GameId));
                for (d_keys.items) |id| {
                    const item_type = self.dangling_items.get(id).?;
                    try writer.print("  Dangling {d}: type={s}\n", .{ id, @tagName(item_type) });
                }
            }
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

        /// Find an empty EIS that accepts the given item type, excluding reserved ones.
        /// Returns null if no suitable EIS found.
        pub fn findEmptyEisForItemExcluding(self: *const Self, item_type: Item, excluded: *const std.AutoHashMap(GameId, void)) ?GameId {
            var iter = self.storages.iterator();
            while (iter.next()) |entry| {
                const storage_id = entry.key_ptr.*;
                const storage = entry.value_ptr.*;
                // Must be EIS, must be empty, must accept this item type, must not be excluded
                if (storage.role == .eis and !storage.has_item and !excluded.contains(storage_id)) {
                    // accepts == null means accepts any item
                    if (storage.accepts == null or storage.accepts.? == item_type) {
                        return storage_id;
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
            if (self.idle_workers_set.count() == 0) return;

            // Snapshot idle workers into local buffer (same reentrancy-safe pattern as tryAssignWorkers)
            var idle_buf: std.ArrayListUnmanaged(GameId) = .{};
            defer idle_buf.deinit(self.allocator);
            idle_buf.ensureTotalCapacity(self.allocator, self.idle_workers_set.count()) catch return;
            var idle_iter = self.idle_workers_set.keyIterator();
            while (idle_iter.next()) |wid| {
                idle_buf.appendAssumeCapacity(wid.*);
            }
            if (idle_buf.items.len == 0) return;

            log.debug("evaluateDanglingItems: {d} idle workers, {d} dangling items", .{
                idle_buf.items.len,
                self.dangling_items.count(),
            });


            var assigned_items = std.AutoHashMap(GameId, GameId).init(self.allocator);
            defer assigned_items.deinit();
            // BUG FIX: Track EIS with pending deliveries to prevent assigning multiple items to same EIS
            var reserved_eis = std.AutoHashMap(GameId, void).init(self.allocator);
            defer reserved_eis.deinit();
            var worker_iter = self.workers.iterator();
            while (worker_iter.next()) |worker_entry| {
                if (worker_entry.value_ptr.dangling_task) |task| {
                    assigned_items.put(task.item_id, worker_entry.key_ptr.*) catch continue;
                    // Track the target EIS as reserved (pending delivery)
                    reserved_eis.put(task.target_eis_id, {}) catch continue;
                }
            }

            // BUG FIX: Track workers assigned during this evaluation to prevent double-assignment
            var assigned_workers = std.AutoHashMap(GameId, void).init(self.allocator);
            defer assigned_workers.deinit();

            // For each dangling item, try to find a worker and EIS
            var dangling_iter = self.dangling_items.iterator();
            while (dangling_iter.next()) |entry| {
                const item_id = entry.key_ptr.*;
                const item_type = entry.value_ptr.*;

                // BUG FIX: Check if another worker is already assigned to this item
                if (assigned_items.get(item_id)) |assigned_worker_id| {
                    log.debug("evaluateDanglingItems: item {d} already assigned to worker {d}, skipping", .{
                        item_id,
                        assigned_worker_id,
                    });
                    continue;
                }

                // Find an empty EIS that accepts this item type (excluding reserved ones)
                const target_eis = self.findEmptyEisForItemExcluding(item_type, &reserved_eis) orelse continue;

                // Find nearest idle worker to the dangling item
                const worker_id = self.findNearest(item_id, idle_buf.items) orelse continue;

                // BUG FIX: Check if this worker was already assigned in this evaluation
                if (assigned_workers.contains(worker_id)) {
                    log.debug("evaluateDanglingItems: worker {d} already assigned in this evaluation, skipping item {d}", .{
                        worker_id,
                        item_id,
                    });
                    continue;
                }

                // Assign worker to pick up this dangling item
                if (self.workers.getPtr(worker_id)) |worker| {
                    log.debug("evaluateDanglingItems: assigning worker {d} to item {d}", .{
                        worker_id,
                        item_id,
                    });

                    worker.state = .Working;
                    self.markWorkerBusy(worker_id);
                    worker.dangling_task = .{
                        .item_id = item_id,
                        .target_eis_id = target_eis,
                    };

                    // Track this assignment to prevent double-assignment in this evaluation
                    assigned_workers.put(worker_id, {}) catch continue;
                    assigned_items.put(item_id, worker_id) catch continue;
                    // BUG FIX: Track this EIS as reserved for subsequent iterations
                    reserved_eis.put(target_eis, {}) catch continue;

                    // Dispatch hook to notify game
                    self.dispatcher.dispatch(.{ .pickup_dangling_started = .{
                        .worker_id = worker_id,
                        .item_id = item_id,
                        .item_type = item_type,
                        .target_eis_id = target_eis,
                    } });

                    // Remove assigned worker from idle_buf so findNearest won't return it again
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
            // Clean up reverse index entry for this storage
            if (self.storage_to_workstations.fetchRemove(id)) |kv| {
                var list = kv.value;
                list.deinit(self.allocator);
            }
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
