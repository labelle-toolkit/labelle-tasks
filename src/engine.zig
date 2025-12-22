//! labelle-tasks Engine
//!
//! A self-contained task orchestration engine for games with storage management.
//!
//! The engine manages:
//! - Workers and workstations with game entity IDs
//! - Storages (EIS, IIS, IOS, EOS) as separate entities
//! - Automatic step derivation based on storage configuration
//! - Process timing with configurable duration
//! - Recurring transport tasks between storages
//!
//! Example:
//! ```zig
//! const Item = enum { Vegetable, Meat, Meal };
//! var engine = Engine(u32, Item).init(allocator);
//! defer engine.deinit();
//!
//! // Create storages
//! _ = engine.addStorage(KITCHEN_EIS_ID, .{ .slots = &.{
//!     .{ .item = .Vegetable, .capacity = 10 },
//!     .{ .item = .Meat, .capacity = 10 },
//! }});
//! _ = engine.addStorage(KITCHEN_IIS_ID, .{ .slots = &.{
//!     .{ .item = .Vegetable, .capacity = 2 },  // Recipe: 2 veg
//!     .{ .item = .Meat, .capacity = 1 },       // Recipe: 1 meat
//! }});
//! _ = engine.addStorage(KITCHEN_IOS_ID, .{ .slots = &.{
//!     .{ .item = .Meal, .capacity = 1 },  // Produces: 1 meal
//! }});
//! _ = engine.addStorage(KITCHEN_EOS_ID, .{ .slots = &.{
//!     .{ .item = .Meal, .capacity = 4 },
//! }});
//!
//! // Create workstation referencing storages
//! _ = engine.addWorkstation(KITCHEN_ID, .{
//!     .eis = KITCHEN_EIS_ID,
//!     .iis = KITCHEN_IIS_ID,
//!     .ios = KITCHEN_IOS_ID,
//!     .eos = KITCHEN_EOS_ID,
//!     .process_duration = 40,
//!     .priority = .High,
//! });
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;

// Import core types from root
const root = @import("root.zig");
pub const Priority = root.Components.Priority;

// Import storage module
const storage_mod = @import("storage.zig");

// Import logging
const log_mod = @import("log.zig");
const log = log_mod.engine;

/// Step types for workstation workflows
pub const StepType = enum {
    Pickup, // Transfer EIS -> IIS
    Process, // Transform IIS -> IOS (timed)
    Store, // Transfer IOS -> EOS
};

/// Task orchestration engine parameterized by game's entity ID and Item types.
pub fn Engine(comptime GameId: type, comptime Item: type) type {
    return struct {
        const Self = @This();

        // Re-export storage types for convenience
        pub const Storage = storage_mod.Storage(GameId, Item);
        pub const Slot = Storage.Slot;
        pub const StorageData = Storage.Data;

        // ====================================================================
        // Internal Types
        // ====================================================================

        pub const WorkerId = u32;
        pub const WorkstationId = u32;
        pub const StorageId = u32;
        pub const TransportId = u32;

        pub const WorkerState = enum {
            Idle,
            Working,
            Blocked, // fighting, sleeping, etc.
        };

        pub const WorkstationStatus = enum {
            Blocked, // waiting for resources or EOS full
            Queued, // has resources, waiting for worker
            Active, // worker assigned and working
        };

        const Worker = struct {
            game_id: GameId,
            state: WorkerState = .Idle,
            assigned_to: ?WorkstationId = null,
            assigned_transport: ?TransportId = null,
        };

        const Workstation = struct {
            game_id: GameId,
            status: WorkstationStatus = .Blocked,
            priority: Priority = .Normal,

            // Storage references (optional - null means not used)
            eis: ?StorageId = null,
            iis: ?StorageId = null,
            ios: ?StorageId = null,
            eos: ?StorageId = null,

            // Processing
            process_duration: u32 = 0, // 0 means no Process step
            process_timer: u32 = 0,

            // Step tracking
            current_step: StepType = .Pickup,
            assigned_worker: ?WorkerId = null,
        };

        const Transport = struct {
            from_storage: StorageId,
            to_storage: StorageId,
            item: Item,
            priority: Priority = .Normal,
            assigned_worker: ?WorkerId = null,
            active: bool = true, // recurring transport
        };

        // ====================================================================
        // Callbacks
        // ====================================================================

        /// Callback: Find the best worker for a workstation or transport.
        pub const FindBestWorkerFn = *const fn (
            workstation_game_id: ?GameId, // null for transport tasks
            available_workers: []const GameId,
        ) ?GameId;

        /// Callback: Called when Pickup step starts.
        /// Game should start worker movement to EIS.
        /// Call notifyPickupComplete when worker arrives.
        pub const OnPickupStartedFn = *const fn (
            worker_game_id: GameId,
            workstation_game_id: GameId,
            eis_game_id: GameId,
        ) void;

        /// Callback: Called when Process step starts.
        /// Game can play animations. Engine handles timing automatically.
        pub const OnProcessStartedFn = *const fn (
            worker_game_id: GameId,
            workstation_game_id: GameId,
        ) void;

        /// Callback: Called when Process step completes.
        /// Game can play completion sounds/effects.
        pub const OnProcessCompleteFn = *const fn (
            worker_game_id: GameId,
            workstation_game_id: GameId,
        ) void;

        /// Callback: Called when Store step starts.
        /// Game should start worker movement to EOS.
        /// Call notifyStoreComplete when worker arrives.
        pub const OnStoreStartedFn = *const fn (
            worker_game_id: GameId,
            workstation_game_id: GameId,
            eos_game_id: GameId,
        ) void;

        /// Callback: Called when a worker is released from a workstation.
        pub const OnWorkerReleasedFn = *const fn (
            worker_game_id: GameId,
            workstation_game_id: GameId,
        ) void;

        /// Callback: Called when transport starts.
        /// Game should start worker movement from source to destination.
        /// Call notifyTransportComplete when worker arrives at destination.
        pub const OnTransportStartedFn = *const fn (
            worker_game_id: GameId,
            from_storage_game_id: GameId,
            to_storage_game_id: GameId,
            item: Item,
        ) void;

        // ====================================================================
        // Fields
        // ====================================================================

        allocator: Allocator,

        // Storage
        workers: std.AutoHashMap(WorkerId, Worker),
        workstations: std.AutoHashMap(WorkstationId, Workstation),
        storages: std.AutoHashMap(StorageId, StorageData),
        transports: std.AutoHashMap(TransportId, Transport),

        // Reverse lookup: game_id -> internal_id
        worker_by_game_id: std.AutoHashMap(GameId, WorkerId),
        workstation_by_game_id: std.AutoHashMap(GameId, WorkstationId),
        storage_by_game_id: std.AutoHashMap(GameId, StorageId),

        // ID generation
        next_worker_id: WorkerId = 1,
        next_workstation_id: WorkstationId = 1,
        next_storage_id: StorageId = 1,
        next_transport_id: TransportId = 1,

        // Callbacks (optional)
        find_best_worker: ?FindBestWorkerFn = null,
        on_pickup_started: ?OnPickupStartedFn = null,
        on_process_started: ?OnProcessStartedFn = null,
        on_process_complete: ?OnProcessCompleteFn = null,
        on_store_started: ?OnStoreStartedFn = null,
        on_worker_released: ?OnWorkerReleasedFn = null,
        on_transport_started: ?OnTransportStartedFn = null,

        // Cycle tracking per workstation
        cycles: std.AutoHashMap(WorkstationId, u32),

        // ====================================================================
        // Logging Helpers
        // ====================================================================

        fn fmtGameId(id: GameId) u64 {
            return log_mod.fmtGameId(GameId, id);
        }

        fn fmtItem(item: Item) []const u8 {
            return log_mod.fmtItem(Item, item);
        }

        // ====================================================================
        // Initialization
        // ====================================================================

        pub fn init(allocator: Allocator) Self {
            return .{
                .allocator = allocator,
                .workers = std.AutoHashMap(WorkerId, Worker).init(allocator),
                .workstations = std.AutoHashMap(WorkstationId, Workstation).init(allocator),
                .storages = std.AutoHashMap(StorageId, StorageData).init(allocator),
                .transports = std.AutoHashMap(TransportId, Transport).init(allocator),
                .worker_by_game_id = std.AutoHashMap(GameId, WorkerId).init(allocator),
                .workstation_by_game_id = std.AutoHashMap(GameId, WorkstationId).init(allocator),
                .storage_by_game_id = std.AutoHashMap(GameId, StorageId).init(allocator),
                .cycles = std.AutoHashMap(WorkstationId, u32).init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            // Free storage quantities
            var storage_iter = self.storages.iterator();
            while (storage_iter.next()) |entry| {
                entry.value_ptr.deinit();
            }

            self.workers.deinit();
            self.workstations.deinit();
            self.storages.deinit();
            self.transports.deinit();
            self.worker_by_game_id.deinit();
            self.workstation_by_game_id.deinit();
            self.storage_by_game_id.deinit();
            self.cycles.deinit();
        }

        // ====================================================================
        // Callback Registration
        // ====================================================================

        pub fn setFindBestWorker(self: *Self, callback: FindBestWorkerFn) void {
            self.find_best_worker = callback;
        }

        pub fn setOnPickupStarted(self: *Self, callback: OnPickupStartedFn) void {
            self.on_pickup_started = callback;
        }

        pub fn setOnProcessStarted(self: *Self, callback: OnProcessStartedFn) void {
            self.on_process_started = callback;
        }

        pub fn setOnProcessComplete(self: *Self, callback: OnProcessCompleteFn) void {
            self.on_process_complete = callback;
        }

        pub fn setOnStoreStarted(self: *Self, callback: OnStoreStartedFn) void {
            self.on_store_started = callback;
        }

        pub fn setOnWorkerReleased(self: *Self, callback: OnWorkerReleasedFn) void {
            self.on_worker_released = callback;
        }

        pub fn setOnTransportStarted(self: *Self, callback: OnTransportStartedFn) void {
            self.on_transport_started = callback;
        }

        // ====================================================================
        // Storage Management
        // ====================================================================

        pub const AddStorageOptions = struct {
            slots: []const Slot,
        };

        /// Register a storage with the engine.
        pub fn addStorage(self: *Self, game_id: GameId, options: AddStorageOptions) StorageId {
            const id = self.next_storage_id;
            self.next_storage_id += 1;

            // Allocate quantities array
            const quantities = self.allocator.alloc(u32, options.slots.len) catch @panic("OOM");
            @memset(quantities, 0);

            self.storages.put(id, .{
                .game_id = game_id,
                .slots = options.slots,
                .quantities = quantities,
                .allocator = self.allocator,
            }) catch @panic("OOM");

            self.storage_by_game_id.put(game_id, id) catch @panic("OOM");

            log.debug("storage added: game_id={d}, storage_id={d}, slots={d}", .{
                fmtGameId(game_id),
                id,
                options.slots.len,
            });

            return id;
        }

        /// Get storage data by game ID.
        pub fn getStorage(self: *Self, game_id: GameId) ?*StorageData {
            const storage_id = self.storage_by_game_id.get(game_id) orelse return null;
            return self.storages.getPtr(storage_id);
        }

        /// Add items to a storage. Returns amount actually added.
        pub fn addToStorage(self: *Self, game_id: GameId, item: Item, quantity: u32) u32 {
            const storage = self.getStorage(game_id) orelse return 0;
            const added = storage.add(item, quantity);

            // Check if any workstation can now start
            if (added > 0) {
                self.checkWorkstationsReadiness();
                // Also check if any transports can now proceed
                self.tryAssignAllIdleWorkersToTransports();
            }

            return added;
        }

        /// Remove items from a storage. Returns amount actually removed.
        pub fn removeFromStorage(self: *Self, game_id: GameId, item: Item, quantity: u32) u32 {
            const storage = self.getStorage(game_id) orelse return 0;
            return storage.remove(item, quantity);
        }

        /// Get quantity of an item in a storage.
        pub fn getStorageQuantity(self: *Self, game_id: GameId, item: Item) u32 {
            const storage = self.getStorage(game_id) orelse return 0;
            return storage.getQuantity(item);
        }

        // ====================================================================
        // Worker Management
        // ====================================================================

        pub const AddWorkerOptions = struct {};

        /// Register a worker with the engine.
        pub fn addWorker(self: *Self, game_id: GameId, options: AddWorkerOptions) WorkerId {
            _ = options;
            const id = self.next_worker_id;
            self.next_worker_id += 1;

            self.workers.put(id, .{
                .game_id = game_id,
            }) catch @panic("OOM");

            self.worker_by_game_id.put(game_id, id) catch @panic("OOM");

            log.debug("worker added: game_id={d}, worker_id={d}", .{ fmtGameId(game_id), id });

            // Try to assign this worker to any queued work
            self.tryAssignIdleWorker(id);

            return id;
        }

        /// Get worker state by game ID.
        pub fn getWorkerState(self: *Self, game_id: GameId) ?WorkerState {
            const worker_id = self.worker_by_game_id.get(game_id) orelse return null;
            const worker = self.workers.get(worker_id) orelse return null;
            return worker.state;
        }

        // ====================================================================
        // Workstation Management
        // ====================================================================

        pub const AddWorkstationOptions = struct {
            eis: ?GameId = null,
            iis: ?GameId = null,
            ios: ?GameId = null,
            eos: ?GameId = null,
            process_duration: u32 = 0,
            priority: Priority = .Normal,
        };

        /// Register a workstation with the engine.
        pub fn addWorkstation(self: *Self, game_id: GameId, options: AddWorkstationOptions) WorkstationId {
            const id = self.next_workstation_id;
            self.next_workstation_id += 1;

            // Resolve storage IDs
            const eis_id = if (options.eis) |eis_game_id| self.storage_by_game_id.get(eis_game_id) else null;
            const iis_id = if (options.iis) |iis_game_id| self.storage_by_game_id.get(iis_game_id) else null;
            const ios_id = if (options.ios) |ios_game_id| self.storage_by_game_id.get(ios_game_id) else null;
            const eos_id = if (options.eos) |eos_game_id| self.storage_by_game_id.get(eos_game_id) else null;

            // Determine first step based on storages
            const first_step: StepType = if (iis_id != null) .Pickup else if (options.process_duration > 0) .Process else .Store;

            self.workstations.put(id, .{
                .game_id = game_id,
                .eis = eis_id,
                .iis = iis_id,
                .ios = ios_id,
                .eos = eos_id,
                .process_duration = options.process_duration,
                .priority = options.priority,
                .current_step = first_step,
            }) catch @panic("OOM");

            self.workstation_by_game_id.put(game_id, id) catch @panic("OOM");
            self.cycles.put(id, 0) catch @panic("OOM");

            log.debug("workstation added: game_id={d}, workstation_id={d}, priority={s}, first_step={s}", .{
                fmtGameId(game_id),
                id,
                @tagName(options.priority),
                @tagName(first_step),
            });

            // Check if this workstation can start immediately (e.g., producer with no inputs)
            self.checkWorkstationsReadiness();

            return id;
        }

        /// Get workstation status by game ID.
        pub fn getWorkstationStatus(self: *Self, game_id: GameId) ?WorkstationStatus {
            const ws_id = self.workstation_by_game_id.get(game_id) orelse return null;
            const ws = self.workstations.get(ws_id) orelse return null;
            return ws.status;
        }

        /// Get number of cycles completed for a workstation.
        pub fn getCyclesCompleted(self: *Self, game_id: GameId) u32 {
            const ws_id = self.workstation_by_game_id.get(game_id) orelse return 0;
            return self.cycles.get(ws_id) orelse 0;
        }

        // ====================================================================
        // Transport Management
        // ====================================================================

        pub const AddTransportOptions = struct {
            from: GameId,
            to: GameId,
            item: Item,
            priority: Priority = .Normal,
        };

        /// Add a recurring transport task.
        pub fn addTransport(self: *Self, options: AddTransportOptions) TransportId {
            const id = self.next_transport_id;
            self.next_transport_id += 1;

            const from_id = self.storage_by_game_id.get(options.from) orelse @panic("Invalid from storage");
            const to_id = self.storage_by_game_id.get(options.to) orelse @panic("Invalid to storage");

            self.transports.put(id, .{
                .from_storage = from_id,
                .to_storage = to_id,
                .item = options.item,
                .priority = options.priority,
            }) catch @panic("OOM");

            log.debug("transport added: transport_id={d}, item={s}, from={d}, to={d}, priority={s}", .{
                id,
                fmtItem(options.item),
                fmtGameId(options.from),
                fmtGameId(options.to),
                @tagName(options.priority),
            });

            // Try to assign idle workers to this transport if items are available
            self.tryAssignAllIdleWorkersToTransports();

            return id;
        }

        // ====================================================================
        // Event Notifications (Game -> Engine)
        // ====================================================================

        /// Notify that Pickup step is complete (worker arrived at EIS with items).
        /// Engine transfers EIS -> IIS and advances to Process step.
        pub fn notifyPickupComplete(self: *Self, worker_game_id: GameId) void {
            const worker_id = self.worker_by_game_id.get(worker_game_id) orelse return;
            const worker = self.workers.getPtr(worker_id) orelse return;
            const ws_id = worker.assigned_to orelse return;
            const ws = self.workstations.getPtr(ws_id) orelse return;

            if (ws.current_step != .Pickup) return;

            log.info("pickup complete: worker={d}, workstation={d}", .{
                fmtGameId(worker.game_id),
                fmtGameId(ws.game_id),
            });

            // Transfer EIS -> IIS
            if (ws.eis) |eis_id| {
                if (ws.iis) |iis_id| {
                    const eis = self.storages.getPtr(eis_id) orelse return;
                    const iis = self.storages.getPtr(iis_id) orelse return;
                    _ = eis.transferRecipeTo(iis, iis.slots);
                }
            }

            // Advance to next step
            self.advanceToNextStep(ws_id);
        }

        /// Notify that Store step is complete (worker arrived at EOS).
        /// Engine transfers IOS -> EOS and completes cycle.
        pub fn notifyStoreComplete(self: *Self, worker_game_id: GameId) void {
            const worker_id = self.worker_by_game_id.get(worker_game_id) orelse return;
            const worker = self.workers.getPtr(worker_id) orelse return;
            const ws_id = worker.assigned_to orelse return;
            const ws = self.workstations.getPtr(ws_id) orelse return;

            if (ws.current_step != .Store) return;

            log.info("store complete: worker={d}, workstation={d}", .{
                fmtGameId(worker.game_id),
                fmtGameId(ws.game_id),
            });

            // Transfer IOS -> EOS
            if (ws.ios) |ios_id| {
                if (ws.eos) |eos_id| {
                    const ios = self.storages.getPtr(ios_id) orelse return;
                    const eos = self.storages.getPtr(eos_id) orelse return;

                    // Transfer all items from IOS to EOS (only what fits)
                    for (ios.slots, 0..) |slot, i| {
                        const qty = ios.quantities[i];
                        if (qty > 0) {
                            const added = eos.add(slot.item, qty);
                            ios.quantities[i] -= added;
                        }
                    }
                }
            }

            // Complete cycle
            self.handleCycleComplete(ws_id, worker_id);
        }

        /// Notify that transport is complete (worker arrived at destination).
        pub fn notifyTransportComplete(self: *Self, worker_game_id: GameId) void {
            const worker_id = self.worker_by_game_id.get(worker_game_id) orelse return;
            const worker = self.workers.getPtr(worker_id) orelse return;
            const transport_id = worker.assigned_transport orelse return;
            const transport = self.transports.getPtr(transport_id) orelse return;

            // Transfer item from source to destination
            const from = self.storages.getPtr(transport.from_storage) orelse return;
            const to = self.storages.getPtr(transport.to_storage) orelse return;

            const removed = from.remove(transport.item, 1);
            if (removed > 0) {
                const added = to.add(transport.item, removed);
                // Return any items that didn't fit back to source
                if (added < removed) {
                    _ = from.add(transport.item, removed - added);
                }

                log.info("transport complete: worker={d}, item={s}, from={d}, to={d}, transferred={d}", .{
                    fmtGameId(worker.game_id),
                    fmtItem(transport.item),
                    fmtGameId(from.game_id),
                    fmtGameId(to.game_id),
                    added,
                });
            }

            // Release worker
            worker.state = .Idle;
            worker.assigned_transport = null;
            transport.assigned_worker = null;

            // Check if workstations can now start
            self.checkWorkstationsReadiness();

            // Try to assign worker to more work
            self.tryAssignIdleWorker(worker_id);
        }

        /// Notify that a worker has become idle.
        pub fn notifyWorkerIdle(self: *Self, game_id: GameId) void {
            const worker_id = self.worker_by_game_id.get(game_id) orelse return;
            const worker = self.workers.getPtr(worker_id) orelse return;

            log.debug("worker idle: worker={d}", .{fmtGameId(game_id)});

            worker.state = .Idle;

            if (worker.assigned_to == null and worker.assigned_transport == null) {
                // Check if any workstations can start (e.g., EOS freed up)
                self.checkWorkstationsReadiness();
                self.tryAssignIdleWorker(worker_id);
            }
        }

        /// Notify that a worker has become busy (fighting, sleeping, etc.)
        pub fn notifyWorkerBusy(self: *Self, game_id: GameId) void {
            const worker_id = self.worker_by_game_id.get(game_id) orelse return;
            const worker = self.workers.getPtr(worker_id) orelse return;

            log.debug("worker blocked: worker={d}", .{fmtGameId(game_id)});

            worker.state = .Blocked;

            // Release from workstation
            if (worker.assigned_to) |ws_id| {
                const ws = self.workstations.getPtr(ws_id) orelse return;
                ws.assigned_worker = null;
                ws.status = .Blocked;
                worker.assigned_to = null;

                if (self.on_worker_released) |callback| {
                    callback(worker.game_id, ws.game_id);
                }
            }

            // Release from transport
            if (worker.assigned_transport) |transport_id| {
                const transport = self.transports.getPtr(transport_id) orelse return;
                transport.assigned_worker = null;
                worker.assigned_transport = null;
            }
        }

        /// Worker abandons their current work.
        pub fn abandonWork(self: *Self, game_id: GameId) void {
            const worker_id = self.worker_by_game_id.get(game_id) orelse return;
            const worker = self.workers.getPtr(worker_id) orelse return;

            if (worker.assigned_to) |ws_id| {
                const ws = self.workstations.getPtr(ws_id) orelse return;
                log.info("worker abandoned workstation: worker={d}, workstation={d}", .{
                    fmtGameId(game_id),
                    fmtGameId(ws.game_id),
                });
                ws.assigned_worker = null;
                ws.status = .Blocked;
                worker.assigned_to = null;
                worker.state = .Idle;
            }

            if (worker.assigned_transport) |transport_id| {
                const transport = self.transports.getPtr(transport_id) orelse return;
                log.info("worker abandoned transport: worker={d}, transport_id={d}", .{
                    fmtGameId(game_id),
                    transport_id,
                });
                transport.assigned_worker = null;
                worker.assigned_transport = null;
                worker.state = .Idle;
            }
        }

        // ====================================================================
        // Update (call each tick)
        // ====================================================================

        /// Update engine state. Call this each game tick.
        /// Handles process timers.
        pub fn update(self: *Self) void {
            var iter = self.workstations.iterator();
            while (iter.next()) |entry| {
                const ws = entry.value_ptr;

                if (ws.status == .Active and ws.current_step == .Process and ws.process_timer > 0) {
                    ws.process_timer -= 1;

                    if (ws.process_timer == 0) {
                        // Process complete - transform IIS -> IOS
                        self.completeProcess(entry.key_ptr.*);
                    }
                }
            }
        }

        // ====================================================================
        // Internal Logic
        // ====================================================================

        fn checkWorkstationsReadiness(self: *Self) void {
            var iter = self.workstations.iterator();
            while (iter.next()) |entry| {
                const ws_id = entry.key_ptr.*;
                const ws = entry.value_ptr;

                if (ws.status == .Blocked and ws.assigned_worker == null) {
                    if (self.canWorkstationStart(ws_id)) {
                        ws.status = .Queued;
                        self.tryAssignWorkerToWorkstation(ws_id);
                    }
                }
            }
        }

        fn canWorkstationStart(self: *Self, ws_id: WorkstationId) bool {
            const ws = self.workstations.get(ws_id) orelse return false;

            // Check if EIS has enough for IIS recipe (if IIS exists)
            if (ws.iis) |iis_id| {
                const iis = self.storages.get(iis_id) orelse return false;

                if (ws.eis) |eis_id| {
                    const eis = self.storages.get(eis_id) orelse return false;
                    if (!eis.canFulfillRecipe(iis.slots)) {
                        return false;
                    }
                }
            }

            // Check if EOS has space for IOS output (if both exist)
            if (ws.ios) |ios_id| {
                if (ws.eos) |eos_id| {
                    const ios = self.storages.get(ios_id) orelse return false;
                    const eos = self.storages.get(eos_id) orelse return false;
                    if (!eos.hasSpaceForOutput(ios.slots)) {
                        return false;
                    }
                }
            }

            return true;
        }

        fn tryAssignWorkerToWorkstation(self: *Self, ws_id: WorkstationId) void {
            const ws = self.workstations.getPtr(ws_id) orelse return;
            if (ws.status != .Queued) return;
            if (ws.assigned_worker != null) return;

            // Collect available workers
            var available: std.ArrayList(GameId) = .empty;
            defer available.deinit(self.allocator);

            var worker_iter = self.workers.iterator();
            while (worker_iter.next()) |entry| {
                const worker = entry.value_ptr;
                if (worker.state == .Idle and worker.assigned_to == null and worker.assigned_transport == null) {
                    available.append(self.allocator, worker.game_id) catch continue;
                }
            }

            if (available.items.len == 0) return;

            // Ask game which worker to use
            const chosen_game_id = if (self.find_best_worker) |callback|
                callback(ws.game_id, available.items)
            else
                available.items[0];

            const chosen_id = chosen_game_id orelse return;
            const worker_id = self.worker_by_game_id.get(chosen_id) orelse return;

            self.assignWorkerToWorkstation(worker_id, ws_id);
        }

        fn tryAssignIdleWorker(self: *Self, worker_id: WorkerId) void {
            const worker = self.workers.getPtr(worker_id) orelse return;
            if (worker.state != .Idle) return;
            if (worker.assigned_to != null or worker.assigned_transport != null) return;

            // Find highest priority queued workstation
            var best_ws_id: ?WorkstationId = null;
            var best_priority: ?Priority = null;

            var ws_iter = self.workstations.iterator();
            while (ws_iter.next()) |entry| {
                const ws = entry.value_ptr;
                if (ws.status == .Queued and ws.assigned_worker == null) {
                    if (best_priority == null or @intFromEnum(ws.priority) > @intFromEnum(best_priority.?)) {
                        best_ws_id = entry.key_ptr.*;
                        best_priority = ws.priority;
                    }
                }
            }

            if (best_ws_id) |ws_id| {
                self.assignWorkerToWorkstation(worker_id, ws_id);
                return;
            }

            // No workstation, try transport
            self.tryAssignWorkerToTransport(worker_id);
        }

        fn tryAssignWorkerToTransport(self: *Self, worker_id: WorkerId) void {
            const worker = self.workers.getPtr(worker_id) orelse return;
            if (worker.state != .Idle) return;
            if (worker.assigned_to != null or worker.assigned_transport != null) return;

            // Find transport with items to move
            var best_transport_id: ?TransportId = null;
            var best_priority: ?Priority = null;

            var transport_iter = self.transports.iterator();
            while (transport_iter.next()) |entry| {
                const transport = entry.value_ptr;
                if (!transport.active or transport.assigned_worker != null) continue;

                // Check if source has items and destination has space
                const from = self.storages.get(transport.from_storage) orelse continue;
                const to = self.storages.get(transport.to_storage) orelse continue;

                if (from.getQuantity(transport.item) > 0 and to.hasSpaceFor(transport.item, 1)) {
                    if (best_priority == null or @intFromEnum(transport.priority) > @intFromEnum(best_priority.?)) {
                        best_transport_id = entry.key_ptr.*;
                        best_priority = transport.priority;
                    }
                }
            }

            if (best_transport_id) |transport_id| {
                self.assignWorkerToTransport(worker_id, transport_id);
            }
        }

        fn tryAssignAllIdleWorkersToTransports(self: *Self) void {
            var worker_iter = self.workers.iterator();
            while (worker_iter.next()) |entry| {
                const worker = entry.value_ptr;
                if (worker.state == .Idle and worker.assigned_to == null and worker.assigned_transport == null) {
                    self.tryAssignWorkerToTransport(entry.key_ptr.*);
                }
            }
        }

        fn assignWorkerToWorkstation(self: *Self, worker_id: WorkerId, ws_id: WorkstationId) void {
            const worker = self.workers.getPtr(worker_id) orelse return;
            const ws = self.workstations.getPtr(ws_id) orelse return;

            log.info("worker assigned to workstation: worker={d}, workstation={d}, step={s}", .{
                fmtGameId(worker.game_id),
                fmtGameId(ws.game_id),
                @tagName(ws.current_step),
            });

            worker.state = .Working;
            worker.assigned_to = ws_id;
            ws.assigned_worker = worker_id;
            ws.status = .Active;

            self.startCurrentStep(ws_id);
        }

        fn assignWorkerToTransport(self: *Self, worker_id: WorkerId, transport_id: TransportId) void {
            const worker = self.workers.getPtr(worker_id) orelse return;
            const transport = self.transports.getPtr(transport_id) orelse return;

            const from = self.storages.get(transport.from_storage) orelse return;
            const to = self.storages.get(transport.to_storage) orelse return;

            log.info("worker assigned to transport: worker={d}, item={s}, from={d}, to={d}", .{
                fmtGameId(worker.game_id),
                fmtItem(transport.item),
                fmtGameId(from.game_id),
                fmtGameId(to.game_id),
            });

            worker.state = .Working;
            worker.assigned_transport = transport_id;
            transport.assigned_worker = worker_id;

            // Notify game
            if (self.on_transport_started) |callback| {
                callback(worker.game_id, from.game_id, to.game_id, transport.item);
            }
        }

        fn startCurrentStep(self: *Self, ws_id: WorkstationId) void {
            const ws = self.workstations.getPtr(ws_id) orelse return;
            const worker_id = ws.assigned_worker orelse return;
            const worker = self.workers.getPtr(worker_id) orelse return;

            switch (ws.current_step) {
                .Pickup => {
                    if (self.on_pickup_started) |callback| {
                        if (ws.eis) |eis_id| {
                            const eis = self.storages.get(eis_id) orelse return;
                            callback(worker.game_id, ws.game_id, eis.game_id);
                        }
                    }
                },
                .Process => {
                    ws.process_timer = ws.process_duration;
                    if (self.on_process_started) |callback| {
                        callback(worker.game_id, ws.game_id);
                    }
                },
                .Store => {
                    if (self.on_store_started) |callback| {
                        if (ws.eos) |eos_id| {
                            const eos = self.storages.get(eos_id) orelse return;
                            callback(worker.game_id, ws.game_id, eos.game_id);
                        }
                    }
                },
            }
        }

        fn advanceToNextStep(self: *Self, ws_id: WorkstationId) void {
            const ws = self.workstations.getPtr(ws_id) orelse return;
            const prev_step = ws.current_step;

            switch (ws.current_step) {
                .Pickup => {
                    if (ws.process_duration > 0) {
                        ws.current_step = .Process;
                    } else if (ws.ios != null) {
                        ws.current_step = .Store;
                    } else {
                        self.handleCycleComplete(ws_id, ws.assigned_worker.?);
                        return;
                    }
                },
                .Process => {
                    if (ws.ios != null) {
                        ws.current_step = .Store;
                    } else {
                        self.handleCycleComplete(ws_id, ws.assigned_worker.?);
                        return;
                    }
                },
                .Store => {
                    // Handled by notifyStoreComplete
                    return;
                },
            }

            log.debug("step transition: workstation={d}, from={s}, to={s}", .{
                fmtGameId(ws.game_id),
                @tagName(prev_step),
                @tagName(ws.current_step),
            });

            self.startCurrentStep(ws_id);
        }

        fn completeProcess(self: *Self, ws_id: WorkstationId) void {
            const ws = self.workstations.getPtr(ws_id) orelse return;
            const worker_id = ws.assigned_worker orelse return;
            const worker = self.workers.getPtr(worker_id) orelse return;

            // Transform IIS -> IOS (clear IIS, fill IOS)
            if (ws.iis) |iis_id| {
                const iis = self.storages.getPtr(iis_id) orelse return;
                iis.clear();
            }
            if (ws.ios) |ios_id| {
                const ios = self.storages.getPtr(ios_id) orelse return;
                ios.fillToCapacity();
            }

            // Notify game
            if (self.on_process_complete) |callback| {
                callback(worker.game_id, ws.game_id);
            }

            // Advance to next step
            self.advanceToNextStep(ws_id);
        }

        fn handleCycleComplete(self: *Self, ws_id: WorkstationId, worker_id: WorkerId) void {
            const ws = self.workstations.getPtr(ws_id) orelse return;
            const worker = self.workers.getPtr(worker_id) orelse return;

            // Increment cycle count
            const cycle_count = self.cycles.getPtr(ws_id) orelse return;
            cycle_count.* += 1;

            log.info("cycle complete: workstation={d}, worker={d}, cycle={d}", .{
                fmtGameId(ws.game_id),
                fmtGameId(worker.game_id),
                cycle_count.*,
            });

            // Reset to first step
            ws.current_step = if (ws.iis != null) .Pickup else if (ws.process_duration > 0) .Process else .Store;

            // Release worker
            self.releaseWorker(worker_id, ws_id);

            // Check if can start another cycle
            if (self.canWorkstationStart(ws_id)) {
                ws.status = .Queued;
                self.tryAssignWorkerToWorkstation(ws_id);
            }
        }

        fn releaseWorker(self: *Self, worker_id: WorkerId, ws_id: WorkstationId) void {
            const worker = self.workers.getPtr(worker_id) orelse return;
            const ws = self.workstations.getPtr(ws_id) orelse return;

            const worker_game_id = worker.game_id;
            const ws_game_id = ws.game_id;

            worker.state = .Idle;
            worker.assigned_to = null;
            ws.assigned_worker = null;
            ws.status = .Blocked;

            if (self.on_worker_released) |callback| {
                callback(worker_game_id, ws_game_id);
            }

            // Try to assign worker to more work
            self.tryAssignIdleWorker(worker_id);
        }
    };
}
