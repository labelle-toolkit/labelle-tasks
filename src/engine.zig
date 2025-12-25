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
//! // EIS and EOS accept slices for flexible multi-storage routing
//! _ = engine.addWorkstation(KITCHEN_ID, .{
//!     .eis = &.{KITCHEN_EIS_ID},
//!     .iis = KITCHEN_IIS_ID,
//!     .ios = KITCHEN_IOS_ID,
//!     .eos = &.{KITCHEN_EOS_ID},
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

            // Storage references (empty slice means not used)
            // Multiple EIS/EOS supported for flexible input/output routing
            eis: []const StorageId = &.{},
            iis: ?StorageId = null,
            ios: ?StorageId = null,
            eos: []const StorageId = &.{},

            // Processing
            process_duration: u32 = 0, // 0 means no Process step
            process_timer: u32 = 0,

            // Step tracking
            current_step: StepType = .Pickup,
            assigned_worker: ?WorkerId = null,

            // Track which EIS/EOS was selected for current cycle
            selected_eis: ?StorageId = null,
            selected_eos: ?StorageId = null,
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

            // Free workstation EIS/EOS arrays
            var ws_iter = self.workstations.iterator();
            while (ws_iter.next()) |entry| {
                const ws = entry.value_ptr;
                if (ws.eis.len > 0) {
                    self.allocator.free(ws.eis);
                }
                if (ws.eos.len > 0) {
                    self.allocator.free(ws.eos);
                }
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
            /// External Input Storages - multiple sources for ingredients
            eis: []const GameId = &.{},
            iis: ?GameId = null,
            ios: ?GameId = null,
            /// External Output Storages - multiple destinations for outputs
            eos: []const GameId = &.{},
            process_duration: u32 = 0,
            priority: Priority = .Normal,
        };

        /// Resolve an array of game IDs to storage IDs, allocating memory for the result.
        /// Returns empty slice if input is empty, otherwise allocates and resolves each ID.
        fn resolveStorageIds(self: *Self, game_ids: []const GameId, comptime name: []const u8) []const StorageId {
            if (game_ids.len == 0) return &.{};

            const ids = self.allocator.alloc(StorageId, game_ids.len) catch @panic("OOM");
            for (game_ids, 0..) |gid, i| {
                ids[i] = self.storage_by_game_id.get(gid) orelse @panic("Invalid " ++ name ++ " storage");
            }
            return ids;
        }

        /// Register a workstation with the engine.
        pub fn addWorkstation(self: *Self, game_id: GameId, options: AddWorkstationOptions) WorkstationId {
            const id = self.next_workstation_id;
            self.next_workstation_id += 1;

            // Resolve single IIS/IOS storage IDs first (for validation)
            const iis_id = if (options.iis) |iis_game_id| self.storage_by_game_id.get(iis_game_id) else null;
            const ios_id = if (options.ios) |ios_game_id| self.storage_by_game_id.get(ios_game_id) else null;

            // Validate configuration before allocating
            if (iis_id != null and options.eis.len == 0) {
                @panic("Workstation has IIS but no EIS - cannot route inputs");
            }
            if (ios_id != null and options.eos.len == 0) {
                @panic("Workstation has IOS but no EOS - cannot route outputs");
            }

            // Resolve storage ID arrays (allocates memory)
            const eis_ids = self.resolveStorageIds(options.eis, "EIS");
            const eos_ids = self.resolveStorageIds(options.eos, "EOS");

            // Determine first step based on storages
            const first_step: StepType = if (iis_id != null) .Pickup else if (options.process_duration > 0) .Process else .Store;

            self.workstations.put(id, .{
                .game_id = game_id,
                .eis = eis_ids,
                .iis = iis_id,
                .ios = ios_id,
                .eos = eos_ids,
                .process_duration = options.process_duration,
                .priority = options.priority,
                .current_step = first_step,
            }) catch @panic("OOM");

            self.workstation_by_game_id.put(game_id, id) catch @panic("OOM");
            self.cycles.put(id, 0) catch @panic("OOM");

            log.debug("workstation added: game_id={d}, workstation_id={d}, priority={s}, first_step={s}, eis_count={d}, eos_count={d}", .{
                fmtGameId(game_id),
                id,
                @tagName(options.priority),
                @tagName(first_step),
                eis_ids.len,
                eos_ids.len,
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
        /// If transfer fails (EIS no longer has recipe), workstation is blocked.
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

            // Transfer selected EIS -> IIS
            var transfer_success = false;
            if (ws.selected_eis) |eis_id| {
                if (ws.iis) |iis_id| {
                    const eis = self.storages.getPtr(eis_id) orelse return;
                    const iis = self.storages.getPtr(iis_id) orelse return;
                    transfer_success = eis.transferRecipeTo(iis, iis.slots);
                }
            }

            if (!transfer_success) {
                // Transfer failed - EIS no longer has recipe or IIS can't accept
                // Block workstation and release worker
                log.warn("pickup transfer failed: worker={d}, workstation={d}", .{
                    fmtGameId(worker.game_id),
                    fmtGameId(ws.game_id),
                });
                ws.status = .Blocked;
                ws.selected_eis = null;
                ws.selected_eos = null;
                self.releaseWorker(worker_id, ws_id);
                return;
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

            // Transfer IOS -> selected EOS
            if (ws.ios) |ios_id| {
                if (ws.selected_eos) |eos_id| {
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

            // Check if any EIS has enough for IIS recipe (if IIS exists)
            if (ws.iis) |iis_id| {
                const iis = self.storages.get(iis_id) orelse return false;

                if (ws.eis.len > 0) {
                    // Check if ANY EIS can fulfill the recipe
                    var any_can_fulfill = false;
                    for (ws.eis) |eis_id| {
                        const eis = self.storages.get(eis_id) orelse continue;
                        if (eis.canFulfillRecipe(iis.slots)) {
                            any_can_fulfill = true;
                            break;
                        }
                    }
                    if (!any_can_fulfill) {
                        return false;
                    }
                }
            }

            // Check if any EOS has space for IOS output (if both exist)
            if (ws.ios) |ios_id| {
                if (ws.eos.len > 0) {
                    const ios = self.storages.get(ios_id) orelse return false;
                    // Check if ANY EOS has space for the output
                    var any_has_space = false;
                    for (ws.eos) |eos_id| {
                        const eos = self.storages.get(eos_id) orelse continue;
                        if (eos.hasSpaceForOutput(ios.slots)) {
                            any_has_space = true;
                            break;
                        }
                    }
                    if (!any_has_space) {
                        return false;
                    }
                }
            }

            return true;
        }

        /// Find an EIS that can fulfill the recipe for a workstation
        fn findSuitableEis(self: *Self, ws: *const Workstation) ?StorageId {
            const iis_id = ws.iis orelse return null;
            const iis = self.storages.get(iis_id) orelse return null;

            for (ws.eis) |eis_id| {
                const eis = self.storages.get(eis_id) orelse continue;
                if (eis.canFulfillRecipe(iis.slots)) {
                    return eis_id;
                }
            }
            return null;
        }

        /// Find an EOS that has space for the output
        fn findSuitableEos(self: *Self, ws: *const Workstation) ?StorageId {
            const ios_id = ws.ios orelse return null;
            const ios = self.storages.get(ios_id) orelse return null;

            for (ws.eos) |eos_id| {
                const eos = self.storages.get(eos_id) orelse continue;
                if (eos.hasSpaceForOutput(ios.slots)) {
                    return eos_id;
                }
            }
            return null;
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

            // Select the EIS to use for this cycle (EOS is selected at Store time)
            ws.selected_eis = self.findSuitableEis(ws);

            log.info("worker assigned to workstation: worker={d}, workstation={d}, step={s}, eis={?d}", .{
                fmtGameId(worker.game_id),
                fmtGameId(ws.game_id),
                @tagName(ws.current_step),
                ws.selected_eis,
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
                        if (ws.selected_eis) |eis_id| {
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
                    // Select EOS at Store time (not at assignment) so we get current availability
                    ws.selected_eos = self.findSuitableEos(ws);

                    if (ws.selected_eos == null) {
                        // No EOS available - block workstation and release worker
                        log.warn("no suitable EOS at store time: worker={d}, workstation={d}", .{
                            fmtGameId(worker.game_id),
                            fmtGameId(ws.game_id),
                        });
                        ws.status = .Blocked;
                        ws.selected_eis = null;
                        self.releaseWorker(worker_id, ws_id);
                        return;
                    }

                    if (self.on_store_started) |callback| {
                        if (ws.selected_eos) |eos_id| {
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

            // Reset to first step and clear selected storages
            ws.current_step = if (ws.iis != null) .Pickup else if (ws.process_duration > 0) .Process else .Store;
            ws.selected_eis = null;
            ws.selected_eos = null;

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

// ============================================================================
// Engine with Hooks
// ============================================================================

const hooks = @import("hooks.zig");

/// Task orchestration engine with hook support.
///
/// This is an extension of `Engine` that emits hooks for lifecycle events.
/// Use this when you want to observe engine events without using callbacks,
/// or when integrating with labelle-engine's hook system.
///
/// The `Dispatcher` parameter should be a type created by `hooks.HookDispatcher`
/// or `hooks.MergeTasksHooks`.
///
/// Example:
/// ```zig
/// const MyHooks = struct {
///     pub fn pickup_started(payload: tasks.hooks.HookPayload(u32, Item)) void {
///         const info = payload.pickup_started;
///         std.log.info("Pickup started!", .{});
///     }
/// };
///
/// const Dispatcher = tasks.hooks.HookDispatcher(u32, Item, MyHooks);
/// var engine = tasks.EngineWithHooks(u32, Item, Dispatcher).init(allocator);
/// ```
pub fn EngineWithHooks(comptime GameId: type, comptime Item: type, comptime Dispatcher: type) type {
    const BaseEngine = Engine(GameId, Item);

    return struct {
        const Self = @This();

        // Re-export types from base engine
        pub const Storage = BaseEngine.Storage;
        pub const Slot = BaseEngine.Slot;
        pub const StorageData = BaseEngine.StorageData;
        pub const WorkerId = BaseEngine.WorkerId;
        pub const WorkstationId = BaseEngine.WorkstationId;
        pub const StorageId = BaseEngine.StorageId;
        pub const TransportId = BaseEngine.TransportId;
        pub const WorkerState = BaseEngine.WorkerState;
        pub const WorkstationStatus = BaseEngine.WorkstationStatus;
        pub const FindBestWorkerFn = BaseEngine.FindBestWorkerFn;
        pub const AddWorkerOptions = BaseEngine.AddWorkerOptions;
        pub const AddWorkstationOptions = BaseEngine.AddWorkstationOptions;
        pub const AddStorageOptions = BaseEngine.AddStorageOptions;
        pub const AddTransportOptions = BaseEngine.AddTransportOptions;

        /// The underlying base engine.
        base: BaseEngine,

        // ====================================================================
        // Initialization
        // ====================================================================

        pub fn init(allocator: Allocator) Self {
            var base = BaseEngine.init(allocator);

            // Wire up internal callbacks to emit hooks
            base.on_pickup_started = emitPickupStarted;
            base.on_process_started = emitProcessStarted;
            base.on_process_complete = emitProcessComplete;
            base.on_store_started = emitStoreStarted;
            base.on_worker_released = emitWorkerReleased;
            base.on_transport_started = emitTransportStarted;

            return .{ .base = base };
        }

        pub fn deinit(self: *Self) void {
            self.base.deinit();
        }

        // ====================================================================
        // Callback Registration (for decision callbacks)
        // ====================================================================

        /// Set custom FindBestWorker callback.
        /// This callback is still required for worker selection logic.
        pub fn setFindBestWorker(self: *Self, callback: FindBestWorkerFn) void {
            self.base.find_best_worker = callback;
        }

        // ====================================================================
        // Worker Management
        // ====================================================================

        pub fn addWorker(self: *Self, game_id: GameId, options: AddWorkerOptions) WorkerId {
            return self.base.addWorker(game_id, options);
        }

        pub fn removeWorker(self: *Self, game_id: GameId) void {
            self.base.removeWorker(game_id);
        }

        pub fn getWorkerState(self: *Self, game_id: GameId) ?WorkerState {
            return self.base.getWorkerState(game_id);
        }

        // ====================================================================
        // Storage Management
        // ====================================================================

        pub fn addStorage(self: *Self, game_id: GameId, options: AddStorageOptions) StorageId {
            return self.base.addStorage(game_id, options);
        }

        pub fn addToStorage(self: *Self, game_id: GameId, item: Item, quantity: u32) u32 {
            return self.base.addToStorage(game_id, item, quantity);
        }

        pub fn removeFromStorage(self: *Self, game_id: GameId, item: Item, quantity: u32) u32 {
            return self.base.removeFromStorage(game_id, item, quantity);
        }

        pub fn getStorageQuantity(self: *Self, game_id: GameId, item: Item) u32 {
            return self.base.getStorageQuantity(game_id, item);
        }

        // ====================================================================
        // Workstation Management
        // ====================================================================

        pub fn addWorkstation(self: *Self, game_id: GameId, options: AddWorkstationOptions) WorkstationId {
            const ws_id = self.base.addWorkstation(game_id, options);

            // Check if workstation is immediately ready
            if (self.base.canWorkstationStart(ws_id)) {
                const ws = self.base.workstations.get(ws_id) orelse return ws_id;
                Dispatcher.emit(.{ .workstation_queued = .{
                    .workstation_id = game_id,
                    .priority = ws.priority,
                } });
            }

            return ws_id;
        }

        pub fn removeWorkstation(self: *Self, game_id: GameId) void {
            self.base.removeWorkstation(game_id);
        }

        pub fn getWorkstationStatus(self: *Self, game_id: GameId) ?WorkstationStatus {
            return self.base.getWorkstationStatus(game_id);
        }

        // ====================================================================
        // Transport Management
        // ====================================================================

        pub fn addTransport(self: *Self, options: AddTransportOptions) TransportId {
            return self.base.addTransport(options);
        }

        // ====================================================================
        // Event Notifications (Game -> Engine)
        // ====================================================================

        /// Notify that a worker completed their pickup step.
        pub fn notifyPickupComplete(self: *Self, worker_game_id: GameId) void {
            self.base.notifyPickupComplete(worker_game_id);
        }

        /// Notify that a worker completed their store step.
        /// Emits: cycle_completed hook
        pub fn notifyStoreComplete(self: *Self, worker_game_id: GameId) void {
            // Get cycle count before
            const worker_id = self.base.worker_by_game_id.get(worker_game_id) orelse return;
            const worker = self.base.workers.get(worker_id) orelse return;
            const ws_id = worker.assigned_to orelse return;
            const old_cycles = self.base.cycles.get(ws_id) orelse 0;

            self.base.notifyStoreComplete(worker_game_id);

            // Check if cycle completed
            const new_cycles = self.base.cycles.get(ws_id) orelse 0;
            if (new_cycles > old_cycles) {
                const ws = self.base.workstations.get(ws_id) orelse return;
                Dispatcher.emit(.{ .cycle_completed = .{
                    .workstation_id = ws.game_id,
                    .worker_id = worker_game_id,
                    .cycles_completed = new_cycles,
                } });
            }
        }

        /// Notify that a transport is complete.
        /// Emits: transport_completed hook
        pub fn notifyTransportComplete(self: *Self, worker_game_id: GameId) void {
            // Get transport info before completion
            const worker_id = self.base.worker_by_game_id.get(worker_game_id) orelse return;
            const worker = self.base.workers.get(worker_id) orelse return;
            const transport_id = worker.assigned_transport orelse return;
            const transport = self.base.transports.get(transport_id) orelse return;

            // Get storage game IDs
            const from_storage = self.base.storages.get(transport.from_storage) orelse return;
            const to_storage = self.base.storages.get(transport.to_storage) orelse return;

            self.base.notifyTransportComplete(worker_game_id);

            // Emit transport completed
            Dispatcher.emit(.{ .transport_completed = .{
                .worker_id = worker_game_id,
                .from_storage_id = from_storage.game_id,
                .to_storage_id = to_storage.game_id,
                .item = transport.item,
            } });
        }

        /// Notify that a worker has become idle.
        /// Emits: worker_assigned, workstation_activated (if assigned)
        pub fn notifyWorkerIdle(self: *Self, game_id: GameId) void {
            // Get worker state before
            const worker_id = self.base.worker_by_game_id.get(game_id) orelse return;
            const worker_before = self.base.workers.get(worker_id) orelse return;
            const was_assigned = worker_before.assigned_to != null or worker_before.assigned_transport != null;

            self.base.notifyWorkerIdle(game_id);

            // Check if worker got assigned to workstation
            const worker_after = self.base.workers.get(worker_id) orelse return;
            if (!was_assigned) {
                if (worker_after.assigned_to) |ws_id| {
                    const ws = self.base.workstations.get(ws_id) orelse return;
                    Dispatcher.emit(.{ .worker_assigned = .{
                        .worker_id = game_id,
                        .workstation_id = ws.game_id,
                    } });
                    Dispatcher.emit(.{ .workstation_activated = .{
                        .workstation_id = ws.game_id,
                        .priority = ws.priority,
                    } });
                } else if (worker_after.assigned_transport != null) {
                    Dispatcher.emit(.{ .worker_assigned = .{
                        .worker_id = game_id,
                        .workstation_id = null, // Transport assignment
                    } });
                }
            }
        }

        /// Notify that a worker has become busy.
        /// Emits: workstation_blocked
        pub fn notifyWorkerBusy(self: *Self, game_id: GameId) void {
            const ws_id = self.getWorkerAssignedWorkstation(game_id);
            self.base.notifyWorkerBusy(game_id);
            self.emitWorkstationBlockedIfAssigned(ws_id);
        }

        /// Worker abandons their current work.
        /// Emits: workstation_blocked
        pub fn abandonWork(self: *Self, game_id: GameId) void {
            const ws_id = self.getWorkerAssignedWorkstation(game_id);
            self.base.abandonWork(game_id);
            self.emitWorkstationBlockedIfAssigned(ws_id);
        }

        /// Update process timers. Call once per game tick.
        pub fn update(self: *Self) void {
            self.base.update();
        }

        // ====================================================================
        // Query Methods
        // ====================================================================

        pub fn getCyclesCompleted(self: *Self, game_id: GameId) u32 {
            return self.base.getCyclesCompleted(game_id);
        }

        pub fn getWorkerAssignment(self: *Self, worker_game_id: GameId) ?GameId {
            return self.base.getWorkerAssignment(worker_game_id);
        }

        pub fn getAssignedWorker(self: *Self, workstation_game_id: GameId) ?GameId {
            return self.base.getAssignedWorker(workstation_game_id);
        }

        // ====================================================================
        // Internal Helpers
        // ====================================================================

        fn getWorkerAssignedWorkstation(self: *Self, game_id: GameId) ?WorkstationId {
            const worker_id = self.base.worker_by_game_id.get(game_id) orelse return null;
            const worker = self.base.workers.get(worker_id) orelse return null;
            return worker.assigned_to;
        }

        fn emitWorkstationBlockedIfAssigned(self: *Self, ws_id: ?WorkstationId) void {
            const id = ws_id orelse return;
            const ws = self.base.workstations.get(id) orelse return;
            Dispatcher.emit(.{ .workstation_blocked = .{
                .workstation_id = ws.game_id,
                .priority = ws.priority,
            } });
        }

        // ====================================================================
        // Internal Callbacks (emit hooks)
        // ====================================================================

        fn emitPickupStarted(worker_game_id: GameId, workstation_game_id: GameId, eis_game_id: GameId) void {
            Dispatcher.emit(.{ .pickup_started = .{
                .worker_id = worker_game_id,
                .workstation_id = workstation_game_id,
                .eis_id = eis_game_id,
            } });
        }

        fn emitProcessStarted(worker_game_id: GameId, workstation_game_id: GameId) void {
            Dispatcher.emit(.{ .process_started = .{
                .worker_id = worker_game_id,
                .workstation_id = workstation_game_id,
            } });
        }

        fn emitProcessComplete(worker_game_id: GameId, workstation_game_id: GameId) void {
            Dispatcher.emit(.{ .process_completed = .{
                .worker_id = worker_game_id,
                .workstation_id = workstation_game_id,
            } });
        }

        fn emitStoreStarted(worker_game_id: GameId, workstation_game_id: GameId, eos_game_id: GameId) void {
            Dispatcher.emit(.{ .store_started = .{
                .worker_id = worker_game_id,
                .workstation_id = workstation_game_id,
                .eos_id = eos_game_id,
            } });
        }

        fn emitWorkerReleased(worker_game_id: GameId, workstation_game_id: GameId) void {
            Dispatcher.emit(.{ .worker_released = .{
                .worker_id = worker_game_id,
                .workstation_id = workstation_game_id,
            } });
        }

        fn emitTransportStarted(worker_game_id: GameId, from_game_id: GameId, to_game_id: GameId, item: Item) void {
            Dispatcher.emit(.{ .transport_started = .{
                .worker_id = worker_game_id,
                .from_storage_id = from_game_id,
                .to_storage_id = to_game_id,
                .item = item,
            } });
        }
    };
}
