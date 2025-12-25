//! labelle-tasks Engine
//!
//! A self-contained task orchestration engine for games.
//!
//! The engine manages task assignment and progression internally.
//! Games interact via:
//! - Registering workers and workstations with game entity IDs
//! - Providing callbacks for game-specific logic (pathfinding, animations)
//! - Notifying the engine of game events (step complete, worker idle)
//!
//! Example:
//! ```zig
//! var engine = Engine(u32).init(allocator);
//! defer engine.deinit();
//!
//! // Register callbacks
//! engine.setFindBestWorker(myFindWorkerFn);
//! engine.setOnStepStarted(myStepStartedFn);
//!
//! // Register game entities
//! engine.addWorker(chef_entity_id, .{});
//! const station = engine.addWorkstation(stove_entity_id, .{
//!     .steps = &.{ .Pickup, .Cook, .Store },
//!     .priority = .High,
//! });
//!
//! // Game events
//! engine.notifyResourcesAvailable(station);
//! engine.notifyStepComplete(chef_entity_id);
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;

// Import core types from root
const root = @import("root.zig");
pub const Priority = root.Priority;
pub const StepType = root.StepType;
pub const StepDef = root.StepDef;

/// Task orchestration engine parameterized by game's entity ID type.
///
/// The engine is generic over `GameId` so games can use whatever ID type
/// they prefer (u32, u64, custom struct, etc.).
pub fn Engine(comptime GameId: type) type {
    return struct {
        const Self = @This();

        // ====================================================================
        // Internal Types
        // ====================================================================

        pub const WorkerId = u32;
        pub const WorkstationId = u32;

        pub const WorkerState = enum {
            Idle,
            Working,
            Blocked, // fighting, sleeping, etc.
        };

        pub const WorkstationStatus = enum {
            Blocked, // waiting for resources
            Queued, // has resources, waiting for worker
            Active, // worker assigned and working
        };

        const Worker = struct {
            game_id: GameId,
            state: WorkerState = .Idle,
            assigned_to: ?WorkstationId = null,
            skills: ?SkillSet = null, // optional skill filtering
        };

        const Workstation = struct {
            game_id: GameId,
            status: WorkstationStatus = .Blocked,
            priority: Priority = .Normal,
            steps: []const StepDef,
            current_step: u8 = 0,
            assigned_worker: ?WorkerId = null,
            room: ?[]const u8 = null, // optional room grouping
        };

        /// Skill set for worker capability filtering.
        /// If null, worker can do any task. If set, worker can only do
        /// tasks at workstations that require skills the worker has.
        pub const SkillSet = struct {
            bits: u32 = 0,

            pub fn has(self: SkillSet, skill: u5) bool {
                return (self.bits & (@as(u32, 1) << skill)) != 0;
            }

            pub fn add(self: *SkillSet, skill: u5) void {
                self.bits |= (@as(u32, 1) << skill);
            }
        };

        // ====================================================================
        // Callbacks
        // ====================================================================

        /// Callback: Find the best worker for a workstation.
        /// Called when a workstation needs a worker assigned.
        /// Return null if no suitable worker is available.
        ///
        /// Parameters:
        /// - workstation_game_id: The game's ID for the workstation
        /// - step: The step type that will be started
        /// - available_workers: Slice of game IDs for available workers
        ///
        /// The game can use its own logic (pathfinding, priorities, etc.)
        /// to select the best worker.
        pub const FindBestWorkerFn = *const fn (
            workstation_game_id: GameId,
            step: StepType,
            available_workers: []const GameId,
        ) ?GameId;

        /// Callback: Called when a step is started.
        /// The game should start movement, animation, timer, etc.
        pub const OnStepStartedFn = *const fn (
            worker_game_id: GameId,
            workstation_game_id: GameId,
            step: StepDef,
        ) void;

        /// Callback: Called when a step is completed.
        /// The game can update UI, play sounds, etc.
        pub const OnStepCompletedFn = *const fn (
            worker_game_id: GameId,
            workstation_game_id: GameId,
            step: StepDef,
        ) void;

        /// Callback: Called when a worker is released from a workstation.
        /// The game can update UI, reassign worker, etc.
        pub const OnWorkerReleasedFn = *const fn (
            worker_game_id: GameId,
            workstation_game_id: GameId,
        ) void;

        /// Callback: Called when a workstation completes all steps (cycle done).
        /// Return true if the workstation should start another cycle.
        pub const ShouldContinueFn = *const fn (
            workstation_game_id: GameId,
            worker_game_id: GameId,
            cycles_completed: u32,
        ) bool;

        // ====================================================================
        // Fields
        // ====================================================================

        allocator: Allocator,

        // Storage
        workers: std.AutoHashMap(WorkerId, Worker),
        workstations: std.AutoHashMap(WorkstationId, Workstation),

        // Reverse lookup: game_id -> internal_id
        worker_by_game_id: std.AutoHashMap(GameId, WorkerId),
        workstation_by_game_id: std.AutoHashMap(GameId, WorkstationId),

        // ID generation
        next_worker_id: WorkerId = 1,
        next_workstation_id: WorkstationId = 1,

        // Callbacks (optional)
        find_best_worker: ?FindBestWorkerFn = null,
        on_step_started: ?OnStepStartedFn = null,
        on_step_completed: ?OnStepCompletedFn = null,
        on_worker_released: ?OnWorkerReleasedFn = null,
        should_continue: ?ShouldContinueFn = null,

        // Cycle tracking per workstation
        cycles: std.AutoHashMap(WorkstationId, u32),

        // ====================================================================
        // Initialization
        // ====================================================================

        pub fn init(allocator: Allocator) Self {
            return .{
                .allocator = allocator,
                .workers = std.AutoHashMap(WorkerId, Worker).init(allocator),
                .workstations = std.AutoHashMap(WorkstationId, Workstation).init(allocator),
                .worker_by_game_id = std.AutoHashMap(GameId, WorkerId).init(allocator),
                .workstation_by_game_id = std.AutoHashMap(GameId, WorkstationId).init(allocator),
                .cycles = std.AutoHashMap(WorkstationId, u32).init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self.workers.deinit();
            self.workstations.deinit();
            self.worker_by_game_id.deinit();
            self.workstation_by_game_id.deinit();
            self.cycles.deinit();
        }

        // ====================================================================
        // Callback Registration
        // ====================================================================

        pub fn setFindBestWorker(self: *Self, callback: FindBestWorkerFn) void {
            self.find_best_worker = callback;
        }

        pub fn setOnStepStarted(self: *Self, callback: OnStepStartedFn) void {
            self.on_step_started = callback;
        }

        pub fn setOnStepCompleted(self: *Self, callback: OnStepCompletedFn) void {
            self.on_step_completed = callback;
        }

        pub fn setOnWorkerReleased(self: *Self, callback: OnWorkerReleasedFn) void {
            self.on_worker_released = callback;
        }

        pub fn setShouldContinue(self: *Self, callback: ShouldContinueFn) void {
            self.should_continue = callback;
        }

        // ====================================================================
        // Worker Management
        // ====================================================================

        pub const AddWorkerOptions = struct {
            skills: ?SkillSet = null,
        };

        /// Register a worker with the engine.
        /// Returns the internal worker ID (for debugging/advanced use).
        pub fn addWorker(self: *Self, game_id: GameId, options: AddWorkerOptions) WorkerId {
            const id = self.next_worker_id;
            self.next_worker_id += 1;

            self.workers.put(id, .{
                .game_id = game_id,
                .skills = options.skills,
            }) catch @panic("OOM");

            self.worker_by_game_id.put(game_id, id) catch @panic("OOM");

            return id;
        }

        /// Remove a worker from the engine.
        /// If worker is assigned, they will be released first.
        pub fn removeWorker(self: *Self, game_id: GameId) void {
            const worker_id = self.worker_by_game_id.get(game_id) orelse return;
            const worker = self.workers.getPtr(worker_id) orelse return;

            // Release from workstation if assigned
            if (worker.assigned_to) |ws_id| {
                self.releaseWorker(worker_id, ws_id);
            }

            _ = self.workers.remove(worker_id);
            _ = self.worker_by_game_id.remove(game_id);
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
            steps: []const StepDef,
            priority: Priority = .Normal,
            room: ?[]const u8 = null,
        };

        /// Register a workstation with the engine.
        /// Returns the internal workstation ID.
        pub fn addWorkstation(self: *Self, game_id: GameId, options: AddWorkstationOptions) WorkstationId {
            const id = self.next_workstation_id;
            self.next_workstation_id += 1;

            self.workstations.put(id, .{
                .game_id = game_id,
                .steps = options.steps,
                .priority = options.priority,
                .room = options.room,
            }) catch @panic("OOM");

            self.workstation_by_game_id.put(game_id, id) catch @panic("OOM");
            self.cycles.put(id, 0) catch @panic("OOM");

            return id;
        }

        /// Remove a workstation from the engine.
        /// If a worker is assigned, they will be released first.
        pub fn removeWorkstation(self: *Self, game_id: GameId) void {
            const ws_id = self.workstation_by_game_id.get(game_id) orelse return;
            const ws = self.workstations.getPtr(ws_id) orelse return;

            // Release worker if assigned
            if (ws.assigned_worker) |worker_id| {
                self.releaseWorker(worker_id, ws_id);
            }

            _ = self.workstations.remove(ws_id);
            _ = self.workstation_by_game_id.remove(game_id);
            _ = self.cycles.remove(ws_id);
        }

        /// Get workstation status by game ID.
        pub fn getWorkstationStatus(self: *Self, game_id: GameId) ?WorkstationStatus {
            const ws_id = self.workstation_by_game_id.get(game_id) orelse return null;
            const ws = self.workstations.get(ws_id) orelse return null;
            return ws.status;
        }

        /// Get current step index for a workstation.
        pub fn getCurrentStep(self: *Self, game_id: GameId) ?u8 {
            const ws_id = self.workstation_by_game_id.get(game_id) orelse return null;
            const ws = self.workstations.get(ws_id) orelse return null;
            return ws.current_step;
        }

        // ====================================================================
        // Event Notifications (Game -> Engine)
        // ====================================================================

        /// Notify that resources are available for a workstation.
        /// This triggers: Blocked -> Queued -> (find worker) -> Active
        pub fn notifyResourcesAvailable(self: *Self, game_id: GameId) void {
            const ws_id = self.workstation_by_game_id.get(game_id) orelse return;
            const ws = self.workstations.getPtr(ws_id) orelse return;

            if (ws.status != .Blocked) return;

            // If worker already assigned (continuing cycle), go Active
            if (ws.assigned_worker != null) {
                ws.status = .Active;
                self.startCurrentStep(ws_id);
            } else {
                // Need to find a worker
                ws.status = .Queued;
                self.tryAssignWorker(ws_id);
            }
        }

        /// Notify that a worker completed their current step.
        /// This triggers: advance to next step, or cycle completion.
        pub fn notifyStepComplete(self: *Self, worker_game_id: GameId) void {
            const worker_id = self.worker_by_game_id.get(worker_game_id) orelse return;
            const worker = self.workers.getPtr(worker_id) orelse return;

            const ws_id = worker.assigned_to orelse return;
            const ws = self.workstations.getPtr(ws_id) orelse return;

            // Notify game of step completion
            if (self.on_step_completed) |callback| {
                const step = ws.steps[ws.current_step];
                callback(worker.game_id, ws.game_id, step);
            }

            // Advance to next step
            ws.current_step += 1;

            if (ws.current_step < ws.steps.len) {
                // More steps - start next one
                self.startCurrentStep(ws_id);
            } else {
                // Cycle complete
                self.handleCycleComplete(ws_id, worker_id);
            }
        }

        /// Notify that a worker has become idle (finished fighting, woke up, etc.)
        /// This triggers: try to assign to a queued workstation.
        pub fn notifyWorkerIdle(self: *Self, game_id: GameId) void {
            const worker_id = self.worker_by_game_id.get(game_id) orelse return;
            const worker = self.workers.getPtr(worker_id) orelse return;

            if (worker.state != .Idle) {
                worker.state = .Idle;
            }

            // If not assigned, try to find work
            if (worker.assigned_to == null) {
                self.tryAssignToQueuedWorkstation(worker_id);
            }
        }

        /// Notify that a worker has become busy (fighting, sleeping, etc.)
        /// This triggers: worker marked as Blocked, released from workstation.
        pub fn notifyWorkerBusy(self: *Self, game_id: GameId) void {
            const worker_id = self.worker_by_game_id.get(game_id) orelse return;
            const worker = self.workers.getPtr(worker_id) orelse return;

            worker.state = .Blocked;

            // Release from workstation (but preserve step progress)
            if (worker.assigned_to) |ws_id| {
                const ws = self.workstations.getPtr(ws_id) orelse return;
                ws.assigned_worker = null;
                ws.status = .Blocked; // Goes back to blocked, keeps current_step
                worker.assigned_to = null;

                if (self.on_worker_released) |callback| {
                    callback(worker.game_id, ws.game_id);
                }
            }
        }

        /// Worker abandons their current work (e.g., fight, death, shift end).
        /// The workstation keeps its current step progress and goes to Blocked.
        /// Worker becomes Idle and can be assigned to other work.
        pub fn abandonWork(self: *Self, game_id: GameId) void {
            const worker_id = self.worker_by_game_id.get(game_id) orelse return;
            const worker = self.workers.getPtr(worker_id) orelse return;

            if (worker.assigned_to) |ws_id| {
                const ws = self.workstations.getPtr(ws_id) orelse return;

                // Unassign but preserve step progress
                ws.assigned_worker = null;
                ws.status = .Blocked; // Goes back to blocked, keeps current_step
                worker.assigned_to = null;
                worker.state = .Idle;
            }
        }

        // ====================================================================
        // Internal Logic
        // ====================================================================

        fn startCurrentStep(self: *Self, ws_id: WorkstationId) void {
            const ws = self.workstations.getPtr(ws_id) orelse return;
            const worker_id = ws.assigned_worker orelse return;
            const worker = self.workers.getPtr(worker_id) orelse return;

            if (ws.current_step >= ws.steps.len) return;

            const step = ws.steps[ws.current_step];

            if (self.on_step_started) |callback| {
                callback(worker.game_id, ws.game_id, step);
            }
        }

        fn tryAssignWorker(self: *Self, ws_id: WorkstationId) void {
            const ws = self.workstations.getPtr(ws_id) orelse return;

            if (ws.status != .Queued) return;
            if (ws.assigned_worker != null) return;

            // Collect available workers
            var available: std.ArrayList(GameId) = .empty;
            defer available.deinit(self.allocator);

            var iter = self.workers.iterator();
            while (iter.next()) |entry| {
                const worker = entry.value_ptr;
                if (worker.state == .Idle and worker.assigned_to == null) {
                    available.append(self.allocator, worker.game_id) catch continue;
                }
            }

            if (available.items.len == 0) return;

            // Ask game which worker to use
            const chosen_game_id = if (self.find_best_worker) |callback|
                callback(ws.game_id, ws.steps[ws.current_step].type, available.items)
            else
                available.items[0]; // Default: first available

            const chosen_id = chosen_game_id orelse return;
            const worker_id = self.worker_by_game_id.get(chosen_id) orelse return;

            self.assignWorkerToWorkstation(worker_id, ws_id);
        }

        fn tryAssignToQueuedWorkstation(self: *Self, worker_id: WorkerId) void {
            const worker = self.workers.getPtr(worker_id) orelse return;

            if (worker.state != .Idle) return;
            if (worker.assigned_to != null) return;

            // Find highest priority queued workstation
            var best_ws_id: ?WorkstationId = null;
            var best_priority: ?Priority = null;

            var iter = self.workstations.iterator();
            while (iter.next()) |entry| {
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
            }
        }

        fn assignWorkerToWorkstation(self: *Self, worker_id: WorkerId, ws_id: WorkstationId) void {
            const worker = self.workers.getPtr(worker_id) orelse return;
            const ws = self.workstations.getPtr(ws_id) orelse return;

            worker.state = .Working;
            worker.assigned_to = ws_id;
            ws.assigned_worker = worker_id;
            ws.status = .Active;

            self.startCurrentStep(ws_id);
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

            // Worker is now idle - try to assign to another workstation
            self.tryAssignToQueuedWorkstation(worker_id);
        }

        fn handleCycleComplete(self: *Self, ws_id: WorkstationId, worker_id: WorkerId) void {
            const ws = self.workstations.getPtr(ws_id) orelse return;
            const worker = self.workers.getPtr(worker_id) orelse return;

            // Increment cycle count
            const cycle_count = self.cycles.getPtr(ws_id) orelse return;
            cycle_count.* += 1;

            // Reset step index
            ws.current_step = 0;

            // Ask if should continue
            const should_cont = if (self.should_continue) |callback|
                callback(ws.game_id, worker.game_id, cycle_count.*)
            else
                false;

            if (should_cont) {
                // Worker continues - workstation goes to Blocked waiting for resources
                ws.status = .Blocked;
                // Worker stays assigned
            } else {
                // Release worker
                self.releaseWorker(worker_id, ws_id);
            }
        }

        // ====================================================================
        // Query Methods
        // ====================================================================

        /// Get the number of cycles completed for a workstation.
        pub fn getCyclesCompleted(self: *Self, game_id: GameId) u32 {
            const ws_id = self.workstation_by_game_id.get(game_id) orelse return 0;
            return self.cycles.get(ws_id) orelse 0;
        }

        /// Get which workstation a worker is assigned to (if any).
        pub fn getWorkerAssignment(self: *Self, worker_game_id: GameId) ?GameId {
            const worker_id = self.worker_by_game_id.get(worker_game_id) orelse return null;
            const worker = self.workers.get(worker_id) orelse return null;
            const ws_id = worker.assigned_to orelse return null;
            const ws = self.workstations.get(ws_id) orelse return null;
            return ws.game_id;
        }

        /// Get which worker is assigned to a workstation (if any).
        pub fn getAssignedWorker(self: *Self, workstation_game_id: GameId) ?GameId {
            const ws_id = self.workstation_by_game_id.get(workstation_game_id) orelse return null;
            const ws = self.workstations.get(ws_id) orelse return null;
            const worker_id = ws.assigned_worker orelse return null;
            const worker = self.workers.get(worker_id) orelse return null;
            return worker.game_id;
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
///     pub fn step_started(payload: tasks.hooks.HookPayload(u32)) void {
///         const info = payload.step_started;
///         std.log.info("Step started!", .{});
///     }
/// };
///
/// const Dispatcher = tasks.hooks.HookDispatcher(u32, MyHooks);
/// var engine = tasks.EngineWithHooks(u32, Dispatcher).init(allocator);
/// ```
pub fn EngineWithHooks(comptime GameId: type, comptime Dispatcher: type) type {
    const BaseEngine = Engine(GameId);

    return struct {
        const Self = @This();

        // Re-export types from base engine
        pub const WorkerId = BaseEngine.WorkerId;
        pub const WorkstationId = BaseEngine.WorkstationId;
        pub const WorkerState = BaseEngine.WorkerState;
        pub const WorkstationStatus = BaseEngine.WorkstationStatus;
        pub const SkillSet = BaseEngine.SkillSet;
        pub const FindBestWorkerFn = BaseEngine.FindBestWorkerFn;
        pub const OnStepStartedFn = BaseEngine.OnStepStartedFn;
        pub const OnStepCompletedFn = BaseEngine.OnStepCompletedFn;
        pub const OnWorkerReleasedFn = BaseEngine.OnWorkerReleasedFn;
        pub const ShouldContinueFn = BaseEngine.ShouldContinueFn;
        pub const AddWorkerOptions = BaseEngine.AddWorkerOptions;
        pub const AddWorkstationOptions = BaseEngine.AddWorkstationOptions;

        /// The underlying base engine.
        base: BaseEngine,

        // ====================================================================
        // Initialization
        // ====================================================================

        pub fn init(allocator: Allocator) Self {
            var base = BaseEngine.init(allocator);

            // Wire up internal callbacks to emit hooks
            base.on_step_started = emitStepStarted;
            base.on_step_completed = emitStepCompleted;
            base.on_worker_released = emitWorkerReleased;

            return .{ .base = base };
        }

        pub fn deinit(self: *Self) void {
            self.base.deinit();
        }

        // ====================================================================
        // Callback Registration (optional, in addition to hooks)
        // ====================================================================

        /// Set custom FindBestWorker callback.
        /// This callback is still required for worker selection logic.
        pub fn setFindBestWorker(self: *Self, callback: FindBestWorkerFn) void {
            self.base.find_best_worker = callback;
        }

        /// Set custom ShouldContinue callback.
        /// This callback is still required for cycle continuation logic.
        pub fn setShouldContinue(self: *Self, callback: ShouldContinueFn) void {
            self.base.should_continue = callback;
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
        // Workstation Management
        // ====================================================================

        pub fn addWorkstation(self: *Self, game_id: GameId, options: AddWorkstationOptions) WorkstationId {
            return self.base.addWorkstation(game_id, options);
        }

        pub fn removeWorkstation(self: *Self, game_id: GameId) void {
            self.base.removeWorkstation(game_id);
        }

        pub fn getWorkstationStatus(self: *Self, game_id: GameId) ?WorkstationStatus {
            return self.base.getWorkstationStatus(game_id);
        }

        pub fn getCurrentStep(self: *Self, game_id: GameId) ?u8 {
            return self.base.getCurrentStep(game_id);
        }

        // ====================================================================
        // Event Notifications (Game -> Engine)
        // ====================================================================

        /// Notify that resources are available for a workstation.
        /// Emits: workstation_queued or workstation_activated, worker_assigned (if worker found)
        pub fn notifyResourcesAvailable(self: *Self, game_id: GameId) void {
            // Get workstation state before notification
            const ws_id = self.base.workstation_by_game_id.get(game_id) orelse return;
            const ws = self.base.workstations.getPtr(ws_id) orelse return;
            const old_status = ws.status;
            const priority = ws.priority;

            // Call base implementation
            self.base.notifyResourcesAvailable(game_id);

            // Get new state after notification
            const new_ws = self.base.workstations.get(ws_id) orelse return;
            const new_status = new_ws.status;

            // Emit status change hooks
            if (old_status != new_status) {
                switch (new_status) {
                    .Queued => Dispatcher.emit(.{ .workstation_queued = .{
                        .workstation_id = game_id,
                        .priority = priority,
                    } }),
                    .Active => {
                        Dispatcher.emit(.{ .workstation_activated = .{
                            .workstation_id = game_id,
                            .priority = priority,
                        } });
                        // If became active, a worker was assigned
                        if (new_ws.assigned_worker) |worker_id| {
                            const worker = self.base.workers.get(worker_id) orelse return;
                            Dispatcher.emit(.{ .worker_assigned = .{
                                .worker_id = worker.game_id,
                                .workstation_id = game_id,
                            } });
                        }
                    },
                    .Blocked => {},
                }
            }
        }

        /// Notify that a worker completed their current step.
        /// Hooks are emitted via callbacks.
        pub fn notifyStepComplete(self: *Self, worker_game_id: GameId) void {
            // Get cycle count before
            const worker_id = self.base.worker_by_game_id.get(worker_game_id) orelse return;
            const worker = self.base.workers.get(worker_id) orelse return;
            const ws_id = worker.assigned_to orelse return;
            const old_cycles = self.base.cycles.get(ws_id) orelse 0;

            self.base.notifyStepComplete(worker_game_id);

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

        /// Notify that a worker has become idle.
        /// Emits: worker_assigned, workstation_activated (if assigned to queued workstation)
        pub fn notifyWorkerIdle(self: *Self, game_id: GameId) void {
            // Get worker state before
            const worker_id = self.base.worker_by_game_id.get(game_id) orelse return;
            const worker_before = self.base.workers.get(worker_id) orelse return;
            const was_assigned = worker_before.assigned_to != null;

            self.base.notifyWorkerIdle(game_id);

            // Check if worker got assigned
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
                }
            }
        }

        /// Notify that a worker has become busy.
        /// Emits: workstation_blocked (via worker_released callback)
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

        /// Helper: Get the workstation a worker is assigned to (internal ID).
        fn getWorkerAssignedWorkstation(self: *Self, game_id: GameId) ?BaseEngine.WorkstationId {
            const worker_id = self.base.worker_by_game_id.get(game_id) orelse return null;
            const worker = self.base.workers.get(worker_id) orelse return null;
            return worker.assigned_to;
        }

        /// Helper: Emit workstation_blocked hook if workstation ID is valid.
        fn emitWorkstationBlockedIfAssigned(self: *Self, ws_id: ?BaseEngine.WorkstationId) void {
            const id = ws_id orelse return;
            const ws = self.base.workstations.get(id) orelse return;
            Dispatcher.emit(.{ .workstation_blocked = .{
                .workstation_id = ws.game_id,
                .priority = ws.priority,
            } });
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
        // Internal Callbacks (emit hooks)
        // ====================================================================

        fn emitStepStarted(worker_game_id: GameId, workstation_game_id: GameId, step: StepDef) void {
            Dispatcher.emit(.{ .step_started = .{
                .worker_id = worker_game_id,
                .workstation_id = workstation_game_id,
                .step = step,
            } });
        }

        fn emitStepCompleted(worker_game_id: GameId, workstation_game_id: GameId, step: StepDef) void {
            Dispatcher.emit(.{ .step_completed = .{
                .worker_id = worker_game_id,
                .workstation_id = workstation_game_id,
                .step = step,
            } });
        }

        fn emitWorkerReleased(worker_game_id: GameId, workstation_game_id: GameId) void {
            Dispatcher.emit(.{ .worker_released = .{
                .worker_id = worker_game_id,
                .workstation_id = workstation_game_id,
            } });
        }
    };
}
