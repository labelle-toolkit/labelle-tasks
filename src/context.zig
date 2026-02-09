//! TaskEngineContext - Helper to reduce game integration boilerplate
//!
//! Wraps the task engine with common setup patterns:
//! - Instance-based state management (engine, registry, game pointers)
//! - Custom vtable with ensureContext callback
//! - Init/deinit lifecycle
//! - Movement queue for hook-triggered worker movements
//! - Default distance function using Position components
//!
//! Usage:
//! ```zig
//! const tasks = @import("labelle-tasks");
//!
//! const MyHooks = struct {
//!     pub fn store_started(payload: anytype) void {
//!         // Queue movement when store starts
//!         tasks.Context.queueMovement(payload.worker_id, x, y, .store);
//!     }
//! };
//!
//! pub const Context = tasks.TaskEngineContext(u64, Item, MyHooks);
//!
//! // In game init hook - uses default distance function:
//! pub fn game_init(payload: engine.HookPayload) void {
//!     _ = Context.init(payload.game_init.allocator) catch return;
//! }
//!
//! // In game deinit hook:
//! pub fn game_deinit(payload: engine.HookPayload) void {
//!     Context.deinit();
//! }
//! ```

const std = @import("std");
const ecs_bridge = @import("ecs_bridge.zig");
const engine_mod = @import("engine.zig");

/// Context for managing task engine lifecycle and game integration (with injected engine types).
/// This version accepts EngineTypes to avoid importing labelle-engine directly,
/// which prevents module collision in WASM builds.
///
/// State is stored in a heap-allocated instance. A single `active` pointer per
/// comptime instantiation provides static access for hooks and convenience wrappers.
/// Multiple instances can coexist for testing by creating instances without setting active.
pub fn TaskEngineContextWith(
    comptime GameId: type,
    comptime Item: type,
    comptime Hooks: type,
    comptime EngineTypes: type,
) type {
    // Components always use EcsInterface(u64, Item) since ECS entity IDs are u64.
    // GameId must match to ensure the same comptime static is used.
    comptime {
        if (GameId != u64) @compileError("TaskEngineContextWith requires GameId = u64 to match component bridge type");
    }

    return struct {
        const Self = @This();

        pub const Engine = engine_mod.Engine(GameId, Item, Hooks);
        pub const EcsInterface = ecs_bridge.EcsInterface(GameId, Item);

        // Injected types from labelle-engine
        const Registry = EngineTypes.Registry;
        const Position = EngineTypes.Position;
        const entityFromU64 = EngineTypes.entityFromU64;

        // ============================================
        // Active instance pointer (single remaining global)
        // ============================================

        var active: ?*Self = null;

        // ============================================
        // Instance fields (previously module-level globals)
        // ============================================

        engine: *Engine,
        allocator: std.mem.Allocator,
        registry_ptr: ?*anyopaque,
        game_ptr: ?*anyopaque,
        vtable: EcsInterface.VTable,

        // ============================================
        // Lifecycle
        // ============================================

        /// Initialize the task engine context with default distance function.
        /// Call this during game initialization (e.g., in game_init hook).
        /// Uses euclidean distance based on Position components by default.
        /// Returns the instance and sets it as the active context.
        pub fn init(allocator: std.mem.Allocator) !*Self {
            if (active != null) return error.AlreadyInitialized;

            const eng = try allocator.create(Engine);
            errdefer {
                eng.deinit();
                allocator.destroy(eng);
            }
            eng.* = Engine.init(allocator, .{}, defaultDistanceFn);

            const self = try allocator.create(Self);
            self.* = Self{
                .engine = eng,
                .allocator = allocator,
                .registry_ptr = null,
                .game_ptr = null,
                .vtable = undefined,
            };

            // Set up ECS interface with ensureContext callback
            const engine_iface = eng.interface();
            self.vtable = engine_iface.vtable.*;
            self.vtable.ensureContext = ensureContext;

            EcsInterface.setActive(.{
                .ptr = engine_iface.ptr,
                .vtable = &self.vtable,
            });

            active = self;

            std.log.info("[TaskEngineContext] Initialized", .{});
            return self;
        }

        /// Set a custom distance function (overrides default).
        /// Call after init() if you need custom distance calculations.
        pub fn setDistanceFunction(func: *const fn (GameId, GameId) ?f32) void {
            const self = active orelse return;
            self.engine.setDistanceFunction(func);
        }

        /// Default distance function using Position components.
        /// Calculates euclidean distance between two entities.
        fn defaultDistanceFn(from_id: GameId, to_id: GameId) ?f32 {
            const registry = getRegistry(Registry) orelse return null;

            const from_entity = entityFromU64(from_id);
            const to_entity = entityFromU64(to_id);

            const from_pos = registry.tryGet(Position, from_entity) orelse return null;
            const to_pos = registry.tryGet(Position, to_entity) orelse return null;

            const dx = to_pos.x - from_pos.x;
            const dy = to_pos.y - from_pos.y;
            return @sqrt(dx * dx + dy * dy);
        }

        /// Deinitialize the task engine context.
        /// Call this during game cleanup (e.g., in game_deinit hook).
        pub fn deinit() void {
            const self = active orelse return;
            active = null;

            EcsInterface.clearActive();
            self.engine.deinit();
            const alloc = self.allocator;
            alloc.destroy(self.engine);
            alloc.destroy(self);
            std.log.info("[TaskEngineContext] Deinitialized", .{});
        }

        /// ECS bridge callback - sets game/registry pointers on first component registration.
        fn ensureContext(game_ptr_raw: *anyopaque, registry_ptr_raw: *anyopaque) void {
            const self = active orelse return;
            if (self.registry_ptr == null) {
                self.registry_ptr = registry_ptr_raw;
            }
            if (self.game_ptr == null) {
                self.game_ptr = game_ptr_raw;
            }
        }

        // ============================================
        // Accessors
        // ============================================

        /// Get the active instance (if initialized).
        pub fn getInstance() ?*Self {
            return active;
        }

        /// Get the task engine instance (if initialized).
        pub fn getEngine() ?*Engine {
            const self = active orelse return null;
            return self.engine;
        }

        /// Get the game registry pointer (if set via ensureContext).
        pub fn getRegistryPtr() ?*anyopaque {
            const self = active orelse return null;
            return self.registry_ptr;
        }

        /// Get the game pointer (if set via ensureContext).
        pub fn getGamePtr() ?*anyopaque {
            const self = active orelse return null;
            return self.game_ptr;
        }

        /// Get the registry cast to a specific type.
        pub fn getRegistry(comptime RegistryType: type) ?*RegistryType {
            const self = active orelse return null;
            const ptr = self.registry_ptr orelse return null;
            return @ptrCast(@alignCast(ptr));
        }

        /// Get the game cast to a specific type.
        pub fn getGame(comptime GameType: type) ?*GameType {
            const self = active orelse return null;
            const ptr = self.game_ptr orelse return null;
            return @ptrCast(@alignCast(ptr));
        }

        // ============================================
        // Engine Operations (convenience wrappers)
        // ============================================

        /// Notify that a pickup was completed.
        pub fn pickupCompleted(worker_id: GameId) bool {
            const self = active orelse return false;
            return self.engine.pickupCompleted(worker_id);
        }

        /// Notify that a store was completed.
        pub fn storeCompleted(worker_id: GameId) bool {
            const self = active orelse return false;
            return self.engine.storeCompleted(worker_id);
        }

        /// Notify that work was completed at a workstation.
        pub fn workCompleted(workstation_id: GameId) bool {
            const self = active orelse return false;
            return self.engine.workCompleted(workstation_id);
        }

        /// Notify that an item was added to a storage.
        pub fn itemAdded(storage_id: GameId, item: Item) bool {
            const self = active orelse return false;
            return self.engine.itemAdded(storage_id, item);
        }

        /// Notify that an item was removed from a storage.
        pub fn itemRemoved(storage_id: GameId) bool {
            const self = active orelse return false;
            return self.engine.itemRemoved(storage_id);
        }

        /// Notify that a worker became available.
        pub fn workerAvailable(worker_id: GameId) bool {
            const self = active orelse return false;
            return self.engine.workerAvailable(worker_id);
        }

        /// Generic handler for when a worker arrives at its destination.
        /// Automatically determines the correct completion based on current step.
        /// Returns true if an event was handled.
        pub fn workerArrived(worker_id: GameId) bool {
            const self = active orelse return false;
            const step = self.engine.getWorkerCurrentStep(worker_id) orelse return false;
            return switch (step) {
                .Pickup => self.engine.pickupCompleted(worker_id),
                .Store => self.engine.storeCompleted(worker_id),
                .Process => false, // Process uses workCompleted when timer finishes
            };
        }

        /// Notify that a dangling pickup was completed.
        /// Uses the same handler as regular pickup - the engine differentiates
        /// based on worker.dangling_task state.
        pub fn danglingPickupCompleted(worker_id: GameId) bool {
            return pickupCompleted(worker_id);
        }

        /// Re-evaluate dangling items (call after scene load).
        pub fn evaluateDanglingItems() void {
            const self = active orelse return;
            self.engine.evaluateDanglingItems();
        }
    };
}

// Note: TaskEngineContext has been removed. Use TaskEngineContextWith instead,
// which requires passing EngineTypes to avoid WASM module collision.
// For the typical use case with labelle-engine, pass engine.EngineTypes.
