//! Base engine implementation.
//!
//! This is the internal implementation used by the public `Engine` type.
//! Users should use `Engine` from the main engine module instead.

const std = @import("std");
const Allocator = std.mem.Allocator;

// Import types
const types = @import("types.zig");
pub const Priority = types.Priority;
pub const StepType = types.StepType;

// Import storage module
const storage_mod = @import("../storage.zig");

// Import logging
const log_mod = @import("../log.zig");
const log = log_mod.engine;

/// Internal base engine implementation.
/// Use `Engine` which wraps this with hook support.
pub fn BaseEngine(comptime GameId: type, comptime Item: type) type {
    return struct {
        const Self = @This();

        // Re-export storage type for convenience
        pub const Storage = storage_mod.Storage(GameId, Item);

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
            // Multiple storages supported for flexible input/output routing
            eis: []const StorageId = &.{},
            iis: []const StorageId = &.{},
            ios: []const StorageId = &.{},
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
        storages: std.AutoHashMap(StorageId, Storage),
        storage_quantities: std.AutoHashMap(StorageId, u32),
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
                .storages = std.AutoHashMap(StorageId, Storage).init(allocator),
                .storage_quantities = std.AutoHashMap(StorageId, u32).init(allocator),
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

            // Free workstation storage ID arrays
            var ws_iter = self.workstations.iterator();
            while (ws_iter.next()) |entry| {
                const ws = entry.value_ptr;
                if (ws.eis.len > 0) {
                    self.allocator.free(ws.eis);
                }
                if (ws.iis.len > 0) {
                    self.allocator.free(ws.iis);
                }
                if (ws.ios.len > 0) {
                    self.allocator.free(ws.ios);
                }
                if (ws.eos.len > 0) {
                    self.allocator.free(ws.eos);
                }
            }

            self.workers.deinit();
            self.workstations.deinit();
            self.storages.deinit();
            self.storage_quantities.deinit();
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
            item: Item,
        };

        /// Register a storage with the engine.
        pub fn addStorage(self: *Self, game_id: GameId, options: AddStorageOptions) StorageId {
            const id = self.next_storage_id;
            self.next_storage_id += 1;

            self.storages.put(id, .{
                .game_id = game_id,
                .item = options.item,
            }) catch @panic("OOM");

            self.storage_quantities.put(id, 0) catch @panic("OOM");
            self.storage_by_game_id.put(game_id, id) catch @panic("OOM");

            log.debug("storage added: game_id={d}, storage_id={d}, item={s}", .{
                fmtGameId(game_id),
                id,
                fmtItem(options.item),
            });

            return id;
        }

        /// Get storage data by game ID.
        pub fn getStorage(self: *Self, game_id: GameId) ?*Storage {
            const storage_id = self.storage_by_game_id.get(game_id) orelse return null;
            return self.storages.getPtr(storage_id);
        }

        /// Add items to a storage. Returns amount actually added.
        pub fn addToStorage(self: *Self, game_id: GameId, item: Item, quantity: u32) u32 {
            const storage_id = self.storage_by_game_id.get(game_id) orelse return 0;
            const storage = self.storages.get(storage_id) orelse return 0;

            // Check if storage accepts this item type
            if (!storage.isAllowed(item)) return 0;

            // Update quantity
            const qty_ptr = self.storage_quantities.getPtr(storage_id) orelse return 0;
            qty_ptr.* += quantity;

            if (quantity > 0) {
                log.debug("storage add: storage={d}, item={s}, added={d}, new_qty={d}", .{
                    fmtGameId(game_id),
                    fmtItem(item),
                    quantity,
                    qty_ptr.*,
                });

                self.checkWorkstationsReadiness();
                self.tryAssignAllIdleWorkersToTransports();
            }

            return quantity;
        }

        /// Remove items from a storage. Returns amount actually removed.
        pub fn removeFromStorage(self: *Self, game_id: GameId, item: Item, quantity: u32) u32 {
            const storage_id = self.storage_by_game_id.get(game_id) orelse return 0;
            const storage = self.storages.get(storage_id) orelse return 0;

            // Check if storage accepts this item type
            if (!storage.isAllowed(item)) return 0;

            // Update quantity
            const qty_ptr = self.storage_quantities.getPtr(storage_id) orelse return 0;
            const to_remove = @min(quantity, qty_ptr.*);
            qty_ptr.* -= to_remove;

            if (to_remove > 0) {
                log.debug("storage remove: storage={d}, item={s}, removed={d}, new_qty={d}", .{
                    fmtGameId(game_id),
                    fmtItem(item),
                    to_remove,
                    qty_ptr.*,
                });
            }

            return to_remove;
        }

        /// Get quantity of an item in a storage.
        pub fn getStorageQuantity(self: *Self, game_id: GameId, item: Item) u32 {
            const storage_id = self.storage_by_game_id.get(game_id) orelse return 0;
            const storage = self.storages.get(storage_id) orelse return 0;

            // Check if storage accepts this item type
            if (!storage.isAllowed(item)) return 0;

            return self.storage_quantities.get(storage_id) orelse 0;
        }

        /// Get quantity by storage ID (internal use).
        fn getStorageQuantityById(self: *Self, storage_id: StorageId) u32 {
            return self.storage_quantities.get(storage_id) orelse 0;
        }

        /// Add quantity by storage ID (internal use).
        fn addStorageQuantityById(self: *Self, storage_id: StorageId, qty: u32) void {
            const qty_ptr = self.storage_quantities.getPtr(storage_id) orelse return;
            qty_ptr.* += qty;
        }

        /// Remove quantity by storage ID (internal use). Returns actual amount removed.
        fn removeStorageQuantityById(self: *Self, storage_id: StorageId, qty: u32) u32 {
            const qty_ptr = self.storage_quantities.getPtr(storage_id) orelse return 0;
            const to_remove = @min(qty, qty_ptr.*);
            qty_ptr.* -= to_remove;
            return to_remove;
        }

        /// Clear storage quantity by ID (internal use).
        fn clearStorageById(self: *Self, storage_id: StorageId) void {
            const qty_ptr = self.storage_quantities.getPtr(storage_id) orelse return;
            qty_ptr.* = 0;
        }

        /// Fill storage with 1 item by ID (internal use).
        fn fillStorageById(self: *Self, storage_id: StorageId) void {
            const qty_ptr = self.storage_quantities.getPtr(storage_id) orelse return;
            qty_ptr.* = 1;
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

        /// Remove a worker from the engine.
        /// If the worker is assigned to a workstation or transport, they are released first.
        pub fn removeWorker(self: *Self, game_id: GameId) void {
            const worker_id = self.worker_by_game_id.get(game_id) orelse return;
            const worker = self.workers.getPtr(worker_id) orelse return;

            // Release from workstation if assigned
            if (worker.assigned_to) |ws_id| {
                const ws = self.workstations.getPtr(ws_id) orelse return;
                ws.assigned_worker = null;
                ws.status = .Blocked;
                ws.selected_eis = null;
                ws.selected_eos = null;

                if (self.on_worker_released) |callback| {
                    callback(worker.game_id, ws.game_id);
                }
            }

            // Release from transport if assigned
            if (worker.assigned_transport) |transport_id| {
                if (self.transports.getPtr(transport_id)) |transport| {
                    transport.assigned_worker = null;
                }
            }

            log.debug("worker removed: game_id={d}, worker_id={d}", .{ fmtGameId(game_id), worker_id });

            // Remove from maps
            _ = self.workers.remove(worker_id);
            _ = self.worker_by_game_id.remove(game_id);
        }

        /// Get the workstation game ID that a worker is assigned to.
        /// Returns null if worker is not assigned to any workstation.
        pub fn getWorkerAssignment(self: *Self, worker_game_id: GameId) ?GameId {
            const worker_id = self.worker_by_game_id.get(worker_game_id) orelse return null;
            const worker = self.workers.get(worker_id) orelse return null;
            const ws_id = worker.assigned_to orelse return null;
            const ws = self.workstations.get(ws_id) orelse return null;
            return ws.game_id;
        }

        // ====================================================================
        // Workstation Management
        // ====================================================================

        pub const AddWorkstationOptions = struct {
            /// External Input Storages - multiple sources for ingredients
            eis: []const GameId = &.{},
            /// Internal Input Storages - recipe requirements (one storage per ingredient)
            iis: []const GameId = &.{},
            /// Internal Output Storages - outputs produced (one storage per output)
            ios: []const GameId = &.{},
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

            // Validate configuration before allocating
            if (options.iis.len > 0 and options.eis.len == 0) {
                @panic("Workstation has IIS but no EIS - cannot route inputs");
            }
            if (options.ios.len > 0 and options.eos.len == 0) {
                @panic("Workstation has IOS but no EOS - cannot route outputs");
            }

            // Resolve storage ID arrays (allocates memory)
            const eis_ids = self.resolveStorageIds(options.eis, "EIS");
            const iis_ids = self.resolveStorageIds(options.iis, "IIS");
            const ios_ids = self.resolveStorageIds(options.ios, "IOS");
            const eos_ids = self.resolveStorageIds(options.eos, "EOS");

            // Determine first step based on storages
            const first_step: StepType = if (iis_ids.len > 0) .Pickup else if (options.process_duration > 0) .Process else .Store;

            self.workstations.put(id, .{
                .game_id = game_id,
                .eis = eis_ids,
                .iis = iis_ids,
                .ios = ios_ids,
                .eos = eos_ids,
                .process_duration = options.process_duration,
                .priority = options.priority,
                .current_step = first_step,
            }) catch @panic("OOM");

            self.workstation_by_game_id.put(game_id, id) catch @panic("OOM");
            self.cycles.put(id, 0) catch @panic("OOM");

            log.debug("workstation added: game_id={d}, workstation_id={d}, priority={s}, first_step={s}, eis_count={d}, iis_count={d}, ios_count={d}, eos_count={d}", .{
                fmtGameId(game_id),
                id,
                @tagName(options.priority),
                @tagName(first_step),
                eis_ids.len,
                iis_ids.len,
                ios_ids.len,
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

        /// Remove a workstation from the engine.
        /// If a worker is assigned, they are released first.
        pub fn removeWorkstation(self: *Self, game_id: GameId) void {
            const ws_id = self.workstation_by_game_id.get(game_id) orelse return;
            const ws = self.workstations.getPtr(ws_id) orelse return;

            // Release assigned worker if any
            if (ws.assigned_worker) |worker_id| {
                if (self.workers.getPtr(worker_id)) |worker| {
                    if (self.on_worker_released) |callback| {
                        callback(worker.game_id, ws.game_id);
                    }
                    worker.state = .Idle;
                    worker.assigned_to = null;
                }
            }

            log.debug("workstation removed: game_id={d}, workstation_id={d}", .{ fmtGameId(game_id), ws_id });

            // Free allocated storage ID arrays
            if (ws.eis.len > 0) {
                self.allocator.free(ws.eis);
            }
            if (ws.iis.len > 0) {
                self.allocator.free(ws.iis);
            }
            if (ws.ios.len > 0) {
                self.allocator.free(ws.ios);
            }
            if (ws.eos.len > 0) {
                self.allocator.free(ws.eos);
            }

            // Remove from maps
            _ = self.workstations.remove(ws_id);
            _ = self.workstation_by_game_id.remove(game_id);
            _ = self.cycles.remove(ws_id);
        }

        /// Get the worker game ID assigned to a workstation.
        /// Returns null if no worker is assigned.
        pub fn getAssignedWorker(self: *Self, workstation_game_id: GameId) ?GameId {
            const ws_id = self.workstation_by_game_id.get(workstation_game_id) orelse return null;
            const ws = self.workstations.get(ws_id) orelse return null;
            const worker_id = ws.assigned_worker orelse return null;
            const worker = self.workers.get(worker_id) orelse return null;
            return worker.game_id;
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
        /// If transfer fails (EIS no longer has items), workstation is blocked.
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

            // Transfer items from EIS to IIS
            // For each IIS, find a matching EIS and transfer 1 item
            var transfer_success = true;
            for (ws.iis) |iis_id| {
                const iis = self.storages.get(iis_id) orelse {
                    transfer_success = false;
                    break;
                };

                // Find an EIS with the matching item
                var transferred = false;
                for (ws.eis) |eis_id| {
                    const eis = self.storages.get(eis_id) orelse continue;
                    const eis_qty = self.getStorageQuantityById(eis_id);
                    if (std.meta.eql(eis.item, iis.item) and eis_qty >= 1) {
                        // Transfer 1 item from EIS to IIS
                        _ = self.removeStorageQuantityById(eis_id, 1);
                        self.addStorageQuantityById(iis_id, 1);
                        transferred = true;
                        break;
                    }
                }

                if (!transferred) {
                    transfer_success = false;
                    break;
                }
            }

            if (!transfer_success) {
                // Transfer failed - EIS no longer has items
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

            // Transfer items from IOS to EOS
            // For each IOS, find a matching EOS and transfer the items
            for (ws.ios) |ios_id| {
                const ios = self.storages.get(ios_id) orelse continue;
                const ios_qty = self.getStorageQuantityById(ios_id);
                if (ios_qty == 0) continue;

                // Find an EOS with the matching item type
                for (ws.eos) |eos_id| {
                    const eos = self.storages.get(eos_id) orelse continue;
                    if (std.meta.eql(eos.item, ios.item)) {
                        // Transfer all items from IOS to EOS
                        self.addStorageQuantityById(eos_id, ios_qty);
                        self.clearStorageById(ios_id);
                        break;
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
            const from = self.storages.get(transport.from_storage) orelse return;
            const to = self.storages.get(transport.to_storage) orelse return;

            const removed = self.removeStorageQuantityById(transport.from_storage, 1);
            if (removed > 0) {
                // Since there's no capacity limit, all items will be added
                self.addStorageQuantityById(transport.to_storage, removed);

                log.info("transport complete: worker={d}, item={s}, from={d}, to={d}, transferred={d}", .{
                    fmtGameId(worker.game_id),
                    fmtItem(transport.item),
                    fmtGameId(from.game_id),
                    fmtGameId(to.game_id),
                    removed,
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

        pub fn checkWorkstationsReadiness(self: *Self) void {
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

        pub fn canWorkstationStart(self: *Self, ws_id: WorkstationId) bool {
            const ws = self.workstations.get(ws_id) orelse return false;

            // Check if EIS has all items needed for IIS recipe
            // Each IIS storage defines one ingredient needed
            for (ws.iis) |iis_id| {
                const iis = self.storages.get(iis_id) orelse return false;

                // Find an EIS that has this item
                var found = false;
                for (ws.eis) |eis_id| {
                    const eis = self.storages.get(eis_id) orelse continue;
                    const eis_qty = self.getStorageQuantityById(eis_id);
                    // Check if EIS has the same item type as IIS and has quantity >= 1
                    if (std.meta.eql(eis.item, iis.item) and eis_qty >= 1) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    return false;
                }
            }

            // Check if any EOS can accept IOS outputs
            // Each IOS storage defines one output produced
            for (ws.ios) |ios_id| {
                const ios = self.storages.get(ios_id) orelse return false;

                // Find an EOS that accepts this item type
                var found = false;
                for (ws.eos) |eos_id| {
                    const eos = self.storages.get(eos_id) orelse continue;
                    // Check if EOS accepts the same item type as IOS
                    if (std.meta.eql(eos.item, ios.item)) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    return false;
                }
            }

            return true;
        }

        /// Find an EIS that has items needed for the recipe
        /// Returns the first EIS that has any of the needed items
        fn findSuitableEis(self: *Self, ws: *const Workstation) ?StorageId {
            if (ws.iis.len == 0) return null;

            // Find an EIS that has any needed item
            for (ws.eis) |eis_id| {
                const eis = self.storages.get(eis_id) orelse continue;
                const eis_qty = self.getStorageQuantityById(eis_id);
                // Check if this EIS has any item needed by IIS
                for (ws.iis) |iis_id| {
                    const iis = self.storages.get(iis_id) orelse continue;
                    if (std.meta.eql(eis.item, iis.item) and eis_qty >= 1) {
                        return eis_id;
                    }
                }
            }
            return null;
        }

        /// Find an EOS that can accept the output items
        /// Returns the first EOS that accepts any of the output items
        fn findSuitableEos(self: *Self, ws: *const Workstation) ?StorageId {
            if (ws.ios.len == 0) return null;

            // Find an EOS that accepts any output item
            for (ws.eos) |eos_id| {
                const eos = self.storages.get(eos_id) orelse continue;
                // Check if this EOS accepts any item from IOS
                for (ws.ios) |ios_id| {
                    const ios = self.storages.get(ios_id) orelse continue;
                    if (std.meta.eql(eos.item, ios.item)) {
                        return eos_id;
                    }
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

                // Check if source has items and destination can accept item type
                const from = self.storages.get(transport.from_storage) orelse continue;
                const to = self.storages.get(transport.to_storage) orelse continue;

                const from_qty = self.getStorageQuantityById(transport.from_storage);
                // Check if source has items and accepts the right type
                if (from.isAllowed(transport.item) and from_qty > 0 and to.isAllowed(transport.item)) {
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
                    } else if (ws.ios.len > 0) {
                        ws.current_step = .Store;
                    } else {
                        self.handleCycleComplete(ws_id, ws.assigned_worker.?);
                        return;
                    }
                },
                .Process => {
                    if (ws.ios.len > 0) {
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

            // Transform IIS -> IOS (clear all IIS, fill all IOS with 1 item each)
            for (ws.iis) |iis_id| {
                self.clearStorageById(iis_id);
            }
            for (ws.ios) |ios_id| {
                self.fillStorageById(ios_id);
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
            ws.current_step = if (ws.iis.len > 0) .Pickup else if (ws.process_duration > 0) .Process else .Store;
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
