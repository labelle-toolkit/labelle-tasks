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
//! - Hook-based event emission for lifecycle events
//!
//! Example:
//! ```zig
//! const tasks = @import("labelle_tasks");
//! const Item = enum { Vegetable, Meat, Meal };
//!
//! // Define hook handlers (optional)
//! const MyHooks = struct {
//!     pub fn cycle_completed(payload: tasks.hooks.HookPayload(u32, Item)) void {
//!         const info = payload.cycle_completed;
//!         std.log.info("Cycle {d} completed!", .{info.cycles_completed});
//!     }
//! };
//!
//! const Dispatcher = tasks.hooks.HookDispatcher(u32, Item, MyHooks);
//! var engine = tasks.Engine(u32, Item, Dispatcher).init(allocator);
//! defer engine.deinit();
//!
//! // Create storages (each storage holds one item type)
//! _ = engine.addStorage(VEG_EIS_ID, .{ .item = .Vegetable });
//! _ = engine.addStorage(MEAT_EIS_ID, .{ .item = .Meat });
//! _ = engine.addStorage(VEG_IIS_ID, .{ .item = .Vegetable });  // Recipe needs 1 vegetable
//! _ = engine.addStorage(MEAT_IIS_ID, .{ .item = .Meat });      // Recipe needs 1 meat
//! _ = engine.addStorage(KITCHEN_IOS_ID, .{ .item = .Meal });   // Produces 1 meal
//! _ = engine.addStorage(KITCHEN_EOS_ID, .{ .item = .Meal });
//!
//! // Create workstation referencing storages
//! _ = engine.addWorkstation(KITCHEN_ID, .{
//!     .eis = &.{ VEG_EIS_ID, MEAT_EIS_ID },
//!     .iis = &.{ VEG_IIS_ID, MEAT_IIS_ID },  // Recipe: 1 veg + 1 meat
//!     .ios = &.{KITCHEN_IOS_ID},              // Produces: 1 meal
//!     .eos = &.{KITCHEN_EOS_ID},
//!     .process_duration = 40,
//!     .priority = .High,
//! });
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;

// Import submodules
const base_mod = @import("engine/base.zig");
const types_mod = @import("engine/types.zig");
const hooks_mod = @import("hooks.zig");

// Re-export types
pub const Priority = types_mod.Priority;
pub const StepType = types_mod.StepType;

// Re-export BaseEngine for internal use (accessible via base field)
pub const BaseEngine = base_mod.BaseEngine;

// ============================================================================
// Engine with Hooks
// ============================================================================

/// Task orchestration engine with hook support.
///
/// The engine manages workers, workstations, storages, and transports,
/// emitting hooks for lifecycle events. Use hooks to observe engine events
/// without using callbacks, ideal for labelle-engine integration.
///
/// The `Dispatcher` parameter should be a type created by `hooks.HookDispatcher`
/// or `hooks.MergeTasksHooks`. Use `hooks.NoOpDispatcher` if you don't need hooks.
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
/// var engine = tasks.Engine(u32, Item, Dispatcher).init(allocator);
/// ```
pub fn Engine(comptime GameId: type, comptime Item: type, comptime Dispatcher: type) type {
    const Base = BaseEngine(GameId, Item);

    return struct {
        const Self = @This();

        // Re-export types from base engine
        pub const Storage = Base.Storage;
        pub const WorkerId = Base.WorkerId;
        pub const WorkstationId = Base.WorkstationId;
        pub const StorageId = Base.StorageId;
        pub const TransportId = Base.TransportId;
        pub const WorkerState = Base.WorkerState;
        pub const WorkstationStatus = Base.WorkstationStatus;
        pub const FindBestWorkerFn = Base.FindBestWorkerFn;
        pub const AddWorkerOptions = Base.AddWorkerOptions;
        pub const AddWorkstationOptions = Base.AddWorkstationOptions;
        pub const AddStorageOptions = Base.AddStorageOptions;
        pub const AddTransportOptions = Base.AddTransportOptions;

        /// The underlying base engine.
        base: Base,

        // ====================================================================
        // Initialization
        // ====================================================================

        pub fn init(allocator: Allocator) Self {
            var base = Base.init(allocator);

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

        pub fn addToStorage(self: *Self, game_id: GameId, item: Item) bool {
            return self.base.addToStorage(game_id, item);
        }

        pub fn removeFromStorage(self: *Self, game_id: GameId, item: Item) bool {
            return self.base.removeFromStorage(game_id, item);
        }

        pub fn hasItem(self: *Self, game_id: GameId, item: Item) bool {
            return self.base.hasItem(game_id, item);
        }

        pub fn isEmpty(self: *Self, game_id: GameId) bool {
            return self.base.isEmpty(game_id);
        }

        pub fn getStorage(self: *Self, game_id: GameId) ?*Storage {
            return self.base.getStorage(game_id);
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
        /// Emits: cycle_completed, worker_assigned (if re-assigned), workstation_activated hooks
        pub fn notifyStoreComplete(self: *Self, worker_game_id: GameId) void {
            // Get state before
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

            // Check if worker was re-assigned to new work
            self.emitWorkerAssignedIfChanged(worker_id, worker_game_id);
        }

        /// Notify that a transport is complete.
        /// Emits: transport_completed, worker_assigned (if re-assigned) hooks
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

            // Check if worker was re-assigned to new work
            self.emitWorkerAssignedIfChanged(worker_id, worker_game_id);
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

        fn getWorkerAssignedWorkstation(self: *Self, game_id: GameId) ?Base.WorkstationId {
            const worker_id = self.base.worker_by_game_id.get(game_id) orelse return null;
            const worker = self.base.workers.get(worker_id) orelse return null;
            return worker.assigned_to;
        }

        fn emitWorkstationBlockedIfAssigned(self: *Self, ws_id: ?Base.WorkstationId) void {
            const id = ws_id orelse return;
            const ws = self.base.workstations.get(id) orelse return;
            Dispatcher.emit(.{ .workstation_blocked = .{
                .workstation_id = ws.game_id,
                .priority = ws.priority,
            } });
        }

        /// Check if worker was re-assigned after completing a task and emit worker_assigned hook.
        fn emitWorkerAssignedIfChanged(self: *Self, worker_id: Base.WorkerId, worker_game_id: GameId) void {
            const worker = self.base.workers.get(worker_id) orelse return;

            // Check if worker was re-assigned to a workstation
            if (worker.assigned_to) |ws_id| {
                const ws = self.base.workstations.get(ws_id) orelse return;
                Dispatcher.emit(.{ .worker_assigned = .{
                    .worker_id = worker_game_id,
                    .workstation_id = ws.game_id,
                } });
                Dispatcher.emit(.{ .workstation_activated = .{
                    .workstation_id = ws.game_id,
                    .priority = ws.priority,
                } });
            } else if (worker.assigned_transport != null) {
                // Re-assigned to a transport task
                Dispatcher.emit(.{ .worker_assigned = .{
                    .worker_id = worker_game_id,
                    .workstation_id = null, // Transport assignment
                } });
            }
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
