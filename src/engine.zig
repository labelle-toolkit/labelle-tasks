const std = @import("std");
const Allocator = std.mem.Allocator;
const hooks = @import("hooks.zig");

const log = std.log.scoped(.tasks);

/// Worker state in the task engine
pub const WorkerState = enum {
    Idle, // Available for assignment
    Working, // Assigned to workstation
    Unavailable, // Temporarily unavailable (eating, sleeping, etc.)
};

/// Workstation status
pub const WorkstationStatus = enum {
    Blocked, // Missing inputs or outputs full
    Queued, // Ready for worker assignment
    Active, // Worker assigned and working
};

/// Step in the workstation workflow
pub const StepType = enum {
    Pickup, // Worker picking up from EIS to IIS
    Process, // Worker processing at workstation
    Store, // Worker storing from IOS to EOS
};

/// Priority for ordering
pub const Priority = enum(u8) {
    Low = 0,
    Normal = 1,
    High = 2,
    Critical = 3,
};

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

        pub const TaskPayload = hooks.TaskHookPayload(GameId, Item);
        pub const GamePayload = hooks.GameHookPayload(GameId, Item);
        const Dispatcher = hooks.HookDispatcher(GameId, Item, TaskHooks);

        /// Abstract storage state (no entity references)
        const StorageState = struct {
            has_item: bool = false,
            item_type: ?Item = null,
            priority: Priority = .Normal,
        };

        /// Internal worker state
        const WorkerData = struct {
            state: WorkerState = .Idle,
            assigned_workstation: ?GameId = null,
        };

        /// Internal workstation state
        const WorkstationData = struct {
            status: WorkstationStatus = .Blocked,
            assigned_worker: ?GameId = null,
            current_step: StepType = .Pickup,
            cycles_completed: u32 = 0,
            priority: Priority = .Normal,

            // Storage references (by GameId)
            eis: []const GameId,
            iis: []const GameId,
            ios: []const GameId,
            eos: []const GameId,

            // Selected storages for current cycle
            selected_eis: ?GameId = null,
            selected_eos: ?GameId = null,

            pub fn isProducer(self: *const WorkstationData) bool {
                return self.eis.len == 0 and self.iis.len == 0;
            }
        };

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
                .item_added => |p| self.handleItemAdded(p.storage_id, p.item),
                .item_removed => |p| self.handleItemRemoved(p.storage_id),
                .storage_cleared => |p| self.handleStorageCleared(p.storage_id),
                .worker_available => |p| self.handleWorkerAvailable(p.worker_id),
                .worker_unavailable => |p| self.handleWorkerUnavailable(p.worker_id),
                .worker_removed => |p| self.handleWorkerRemoved(p.worker_id),
                .workstation_enabled => |p| self.handleWorkstationEnabled(p.workstation_id),
                .workstation_disabled => |p| self.handleWorkstationDisabled(p.workstation_id),
                .workstation_removed => |p| self.handleWorkstationRemoved(p.workstation_id),
                .pickup_completed => |p| self.handlePickupCompleted(p.worker_id),
                .work_completed => |p| self.handleWorkCompleted(p.workstation_id),
                .store_completed => |p| self.handleStoreCompleted(p.worker_id),
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
        // Internal handlers
        // ============================================

        fn handleItemAdded(self: *Self, storage_id: GameId, item: Item) bool {
            const storage = self.storages.getPtr(storage_id) orelse {
                log.err("item_added: unknown storage {}", .{storage_id});
                return false;
            };

            if (storage.has_item) {
                log.err("item_added: storage {} already has item", .{storage_id});
                return false;
            }

            storage.has_item = true;
            storage.item_type = item;

            // Re-evaluate workstations that use this storage
            self.reevaluateWorkstations();
            return true;
        }

        fn handleItemRemoved(self: *Self, storage_id: GameId) bool {
            const storage = self.storages.getPtr(storage_id) orelse {
                log.err("item_removed: unknown storage {}", .{storage_id});
                return false;
            };

            storage.has_item = false;
            storage.item_type = null;

            self.reevaluateWorkstations();
            return true;
        }

        fn handleStorageCleared(self: *Self, storage_id: GameId) bool {
            _ = self.storages.remove(storage_id);
            return true;
        }

        fn handleWorkerAvailable(self: *Self, worker_id: GameId) bool {
            const worker = self.workers.getPtr(worker_id) orelse {
                log.err("worker_available: unknown worker {}", .{worker_id});
                return false;
            };

            worker.state = .Idle;
            worker.assigned_workstation = null;

            // Try to assign worker to a queued workstation
            self.tryAssignWorkers();
            return true;
        }

        fn handleWorkerUnavailable(self: *Self, worker_id: GameId) bool {
            const worker = self.workers.getPtr(worker_id) orelse {
                log.err("worker_unavailable: unknown worker {}", .{worker_id});
                return false;
            };

            // If worker was assigned, release from workstation
            if (worker.assigned_workstation) |ws_id| {
                if (self.workstations.getPtr(ws_id)) |ws| {
                    ws.assigned_worker = null;
                    ws.status = .Queued;

                    self.dispatcher.dispatch(.{ .worker_released = .{ .worker_id = worker_id } });
                    self.dispatcher.dispatch(.{ .workstation_queued = .{ .workstation_id = ws_id } });
                }
            }

            worker.state = .Unavailable;
            worker.assigned_workstation = null;
            return true;
        }

        fn handleWorkerRemoved(self: *Self, worker_id: GameId) bool {
            if (self.workers.getPtr(worker_id)) |worker| {
                // Release from workstation first
                if (worker.assigned_workstation) |ws_id| {
                    if (self.workstations.getPtr(ws_id)) |ws| {
                        ws.assigned_worker = null;
                        self.evaluateWorkstationStatus(ws_id);
                    }
                }
            }
            _ = self.workers.remove(worker_id);
            return true;
        }

        fn handleWorkstationEnabled(self: *Self, workstation_id: GameId) bool {
            self.evaluateWorkstationStatus(workstation_id);
            return true;
        }

        fn handleWorkstationDisabled(self: *Self, workstation_id: GameId) bool {
            const ws = self.workstations.getPtr(workstation_id) orelse {
                return false;
            };

            // Release worker if assigned
            if (ws.assigned_worker) |worker_id| {
                if (self.workers.getPtr(worker_id)) |worker| {
                    worker.state = .Idle;
                    worker.assigned_workstation = null;
                    self.dispatcher.dispatch(.{ .worker_released = .{ .worker_id = worker_id } });
                }
            }

            ws.status = .Blocked;
            ws.assigned_worker = null;
            self.dispatcher.dispatch(.{ .workstation_blocked = .{ .workstation_id = workstation_id } });
            return true;
        }

        fn handleWorkstationRemoved(self: *Self, workstation_id: GameId) bool {
            if (self.workstations.getPtr(workstation_id)) |ws| {
                // Release worker
                if (ws.assigned_worker) |worker_id| {
                    if (self.workers.getPtr(worker_id)) |worker| {
                        worker.state = .Idle;
                        worker.assigned_workstation = null;
                    }
                }

                // Free storage slices
                self.allocator.free(ws.eis);
                self.allocator.free(ws.iis);
                self.allocator.free(ws.ios);
                self.allocator.free(ws.eos);
            }
            _ = self.workstations.remove(workstation_id);
            return true;
        }

        fn handlePickupCompleted(self: *Self, worker_id: GameId) bool {
            const worker = self.workers.getPtr(worker_id) orelse {
                log.err("pickup_completed: unknown worker {}", .{worker_id});
                return false;
            };

            const ws_id = worker.assigned_workstation orelse {
                log.err("pickup_completed: worker {} not assigned to workstation", .{worker_id});
                return false;
            };

            const ws = self.workstations.getPtr(ws_id) orelse {
                log.err("pickup_completed: unknown workstation {}", .{ws_id});
                return false;
            };

            if (ws.current_step != .Pickup) {
                log.err("pickup_completed: workstation {} not in Pickup step", .{ws_id});
                return false;
            }

            // Update abstract state: item moved from EIS to IIS
            if (ws.selected_eis) |eis_id| {
                if (self.storages.getPtr(eis_id)) |eis_storage| {
                    const item = eis_storage.item_type;

                    // Clear EIS
                    eis_storage.has_item = false;
                    eis_storage.item_type = null;

                    // Fill first empty IIS
                    for (ws.iis) |iis_id| {
                        if (self.storages.getPtr(iis_id)) |iis_storage| {
                            if (!iis_storage.has_item) {
                                iis_storage.has_item = true;
                                iis_storage.item_type = item;
                                break;
                            }
                        }
                    }
                }
            }

            // Check if all IIS are filled
            var all_iis_filled = true;
            for (ws.iis) |iis_id| {
                if (self.storages.get(iis_id)) |iis_storage| {
                    if (!iis_storage.has_item) {
                        all_iis_filled = false;
                        break;
                    }
                }
            }

            if (all_iis_filled or ws.isProducer()) {
                // Move to Process step
                ws.current_step = .Process;
                self.dispatcher.dispatch(.{ .process_started = .{
                    .workstation_id = ws_id,
                    .worker_id = worker_id,
                } });
            } else {
                // Need more pickups - select next EIS
                ws.selected_eis = self.selectEis(ws_id);
                if (ws.selected_eis) |eis_id| {
                    const item = self.storages.get(eis_id).?.item_type.?;
                    self.dispatcher.dispatch(.{ .pickup_started = .{
                        .worker_id = worker_id,
                        .storage_id = eis_id,
                        .item = item,
                    } });
                }
            }

            return true;
        }

        fn handleWorkCompleted(self: *Self, workstation_id: GameId) bool {
            const ws = self.workstations.getPtr(workstation_id) orelse {
                log.err("work_completed: unknown workstation {}", .{workstation_id});
                return false;
            };

            if (ws.current_step != .Process) {
                log.err("work_completed: workstation {} not in Process step", .{workstation_id});
                return false;
            }

            const worker_id = ws.assigned_worker orelse {
                log.err("work_completed: workstation {} has no assigned worker", .{workstation_id});
                return false;
            };

            // Update abstract state: IIS → IOS transformation
            // Clear all IIS
            for (ws.iis) |iis_id| {
                if (self.storages.getPtr(iis_id)) |storage| {
                    storage.has_item = false;
                    storage.item_type = null;
                }
            }

            // Fill all IOS (game determines actual output items via process_completed hook)
            // For now, we just mark them as having items - game will set the actual entity
            for (ws.ios) |ios_id| {
                if (self.storages.getPtr(ios_id)) |storage| {
                    storage.has_item = true;
                    // item_type will be set by game via item_added or left for game to track
                }
            }

            // Emit process_completed - game handles entity transformation
            self.dispatcher.dispatch(.{ .process_completed = .{
                .workstation_id = workstation_id,
                .worker_id = worker_id,
            } });

            // Move to Store step
            ws.current_step = .Store;
            ws.selected_eos = self.selectEos(workstation_id);

            if (ws.selected_eos) |eos_id| {
                // Get item from first IOS that has one
                var item: ?Item = null;
                for (ws.ios) |ios_id| {
                    if (self.storages.get(ios_id)) |storage| {
                        if (storage.item_type) |it| {
                            item = it;
                            break;
                        }
                    }
                }

                self.dispatcher.dispatch(.{ .store_started = .{
                    .worker_id = worker_id,
                    .storage_id = eos_id,
                    .item = item orelse return true, // No item to store
                } });
            }

            return true;
        }

        fn handleStoreCompleted(self: *Self, worker_id: GameId) bool {
            const worker = self.workers.getPtr(worker_id) orelse {
                log.err("store_completed: unknown worker {}", .{worker_id});
                return false;
            };

            const ws_id = worker.assigned_workstation orelse {
                log.err("store_completed: worker {} not assigned to workstation", .{worker_id});
                return false;
            };

            const ws = self.workstations.getPtr(ws_id) orelse {
                log.err("store_completed: unknown workstation {}", .{ws_id});
                return false;
            };

            if (ws.current_step != .Store) {
                log.err("store_completed: workstation {} not in Store step", .{ws_id});
                return false;
            }

            // Update abstract state: IOS → EOS
            // Find first IOS with item and move to selected EOS
            for (ws.ios) |ios_id| {
                if (self.storages.getPtr(ios_id)) |ios_storage| {
                    if (ios_storage.has_item) {
                        const item = ios_storage.item_type;

                        // Clear IOS
                        ios_storage.has_item = false;
                        ios_storage.item_type = null;

                        // Fill EOS
                        if (ws.selected_eos) |eos_id| {
                            if (self.storages.getPtr(eos_id)) |eos_storage| {
                                eos_storage.has_item = true;
                                eos_storage.item_type = item;
                            }
                        }
                        break;
                    }
                }
            }

            // Check if all IOS are empty
            var all_ios_empty = true;
            for (ws.ios) |ios_id| {
                if (self.storages.get(ios_id)) |storage| {
                    if (storage.has_item) {
                        all_ios_empty = false;
                        break;
                    }
                }
            }

            if (all_ios_empty) {
                // Cycle complete
                ws.cycles_completed += 1;
                self.dispatcher.dispatch(.{ .cycle_completed = .{
                    .workstation_id = ws_id,
                    .cycles_completed = ws.cycles_completed,
                } });

                // Reset for next cycle
                ws.current_step = .Pickup;
                ws.selected_eis = null;
                ws.selected_eos = null;

                // Release worker
                ws.assigned_worker = null;
                worker.state = .Idle;
                worker.assigned_workstation = null;
                self.dispatcher.dispatch(.{ .worker_released = .{ .worker_id = worker_id } });

                // Re-evaluate workstation status
                self.evaluateWorkstationStatus(ws_id);

                // Try to assign workers
                self.tryAssignWorkers();
            } else {
                // More items to store
                ws.selected_eos = self.selectEos(ws_id);
                if (ws.selected_eos) |eos_id| {
                    var item: ?Item = null;
                    for (ws.ios) |ios_id| {
                        if (self.storages.get(ios_id)) |storage| {
                            if (storage.item_type) |it| {
                                item = it;
                                break;
                            }
                        }
                    }

                    if (item) |it| {
                        self.dispatcher.dispatch(.{ .store_started = .{
                            .worker_id = worker_id,
                            .storage_id = eos_id,
                            .item = it,
                        } });
                    }
                }
            }

            return true;
        }

        // ============================================
        // Internal helpers
        // ============================================

        fn evaluateWorkstationStatus(self: *Self, workstation_id: GameId) void {
            const ws = self.workstations.getPtr(workstation_id) orelse return;

            const old_status = ws.status;

            // Check if workstation can operate
            const can_operate = self.canWorkstationOperate(ws);

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
                    .Blocked => self.dispatcher.dispatch(.{ .workstation_blocked = .{ .workstation_id = workstation_id } }),
                    .Queued => self.dispatcher.dispatch(.{ .workstation_queued = .{ .workstation_id = workstation_id } }),
                    .Active => self.dispatcher.dispatch(.{ .workstation_activated = .{ .workstation_id = workstation_id } }),
                }
            }
        }

        fn canWorkstationOperate(self: *Self, ws: *const WorkstationData) bool {
            // Producer: just needs empty IOS and empty EOS
            if (ws.isProducer()) {
                // Check IOS has space
                for (ws.ios) |ios_id| {
                    if (self.storages.get(ios_id)) |storage| {
                        if (storage.has_item) return false; // IOS full
                    }
                }
                // Check EOS has space
                for (ws.eos) |eos_id| {
                    if (self.storages.get(eos_id)) |storage| {
                        if (storage.has_item) return false; // EOS full
                    }
                }
                return true;
            }

            // Regular workstation: needs items in EIS and space in EOS
            var has_input = false;
            for (ws.eis) |eis_id| {
                if (self.storages.get(eis_id)) |storage| {
                    if (storage.has_item) {
                        has_input = true;
                        break;
                    }
                }
            }
            if (!has_input) return false;

            var has_output_space = false;
            for (ws.eos) |eos_id| {
                if (self.storages.get(eos_id)) |storage| {
                    if (!storage.has_item) {
                        has_output_space = true;
                        break;
                    }
                }
            }
            if (!has_output_space) return false;

            return true;
        }

        fn reevaluateWorkstations(self: *Self) void {
            var iter = self.workstations.keyIterator();
            while (iter.next()) |ws_id| {
                self.evaluateWorkstationStatus(ws_id.*);
            }
            self.tryAssignWorkers();
        }

        fn tryAssignWorkers(self: *Self) void {
            // Collect idle workers
            var idle_workers = std.ArrayListUnmanaged(GameId){};
            defer idle_workers.deinit(self.allocator);

            var worker_iter = self.workers.iterator();
            while (worker_iter.next()) |entry| {
                if (entry.value_ptr.state == .Idle) {
                    idle_workers.append(self.allocator, entry.key_ptr.*) catch continue;
                }
            }

            if (idle_workers.items.len == 0) return;

            // Find queued workstations and assign workers
            var ws_iter = self.workstations.iterator();
            while (ws_iter.next()) |entry| {
                const ws_id = entry.key_ptr.*;
                const ws = entry.value_ptr;

                if (ws.status != .Queued) continue;

                // Use callback to select worker, or just pick first
                const worker_id = if (self.find_best_worker_fn) |callback|
                    callback(ws_id, idle_workers.items)
                else if (idle_workers.items.len > 0)
                    idle_workers.items[0]
                else
                    null;

                if (worker_id) |wid| {
                    self.assignWorkerToWorkstation(wid, ws_id);

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

        fn assignWorkerToWorkstation(self: *Self, worker_id: GameId, workstation_id: GameId) void {
            const worker = self.workers.getPtr(worker_id) orelse return;
            const ws = self.workstations.getPtr(workstation_id) orelse return;

            worker.state = .Working;
            worker.assigned_workstation = workstation_id;
            ws.assigned_worker = worker_id;
            ws.status = .Active;

            self.dispatcher.dispatch(.{ .worker_assigned = .{
                .worker_id = worker_id,
                .workstation_id = workstation_id,
            } });
            self.dispatcher.dispatch(.{ .workstation_activated = .{ .workstation_id = workstation_id } });

            // Start the workflow
            if (ws.isProducer()) {
                // Producer: go straight to Process
                ws.current_step = .Process;
                self.dispatcher.dispatch(.{ .process_started = .{
                    .workstation_id = workstation_id,
                    .worker_id = worker_id,
                } });
            } else {
                // Regular: start with Pickup
                ws.current_step = .Pickup;
                ws.selected_eis = self.selectEis(workstation_id);

                if (ws.selected_eis) |eis_id| {
                    const item = self.storages.get(eis_id).?.item_type.?;
                    self.dispatcher.dispatch(.{ .pickup_started = .{
                        .worker_id = worker_id,
                        .storage_id = eis_id,
                        .item = item,
                    } });
                }
            }
        }

        fn selectEis(self: *Self, workstation_id: GameId) ?GameId {
            const ws = self.workstations.get(workstation_id) orelse return null;

            // Find first EIS with an item
            for (ws.eis) |eis_id| {
                if (self.storages.get(eis_id)) |storage| {
                    if (storage.has_item) {
                        return eis_id;
                    }
                }
            }
            return null;
        }

        fn selectEos(self: *Self, workstation_id: GameId) ?GameId {
            const ws = self.workstations.get(workstation_id) orelse return null;

            // Find first EOS with space
            for (ws.eos) |eos_id| {
                if (self.storages.get(eos_id)) |storage| {
                    if (!storage.has_item) {
                        return eos_id;
                    }
                }
            }
            return null;
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
