//! TaskEngineContext - Helper to reduce game integration boilerplate
//!
//! Wraps the task engine with common setup patterns:
//! - Global state management (engine, registry, game pointers)
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
//!     Context.init(payload.game_init.allocator) catch return;
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

// ============================================
// Shared Global State (accessible from hooks without Context type)
// ============================================
// These are set by TaskEngineContext.ensureContext and can be accessed
// by enriched hook payloads without knowing the specific Context type.

var shared_registry: ?*anyopaque = null;
var shared_game: ?*anyopaque = null;

/// Get the shared registry pointer (for use by enriched hook payloads)
pub fn getSharedRegistry(comptime RegistryType: type) ?*RegistryType {
    const ptr = shared_registry orelse return null;
    return @ptrCast(@alignCast(ptr));
}

/// Get the shared game pointer (for use by enriched hook payloads)
pub fn getSharedGame(comptime GameType: type) ?*GameType {
    const ptr = shared_game orelse return null;
    return @ptrCast(@alignCast(ptr));
}

/// Context for managing task engine lifecycle and game integration (with injected engine types).
/// This version accepts EngineTypes to avoid importing labelle-engine directly,
/// which prevents module collision in WASM builds.
/// Eliminates boilerplate for vtable wrapping, global state, and movement queuing.
pub fn TaskEngineContextWith(
    comptime GameId: type,
    comptime Item: type,
    comptime Hooks: type,
    comptime EngineTypes: type,
) type {
    return struct {
        const Self = @This();

        pub const Engine = engine_mod.Engine(GameId, Item, Hooks);
        pub const EcsInterface = ecs_bridge.EcsInterface(GameId, Item);
        pub const InterfaceStorage = ecs_bridge.InterfaceStorage(GameId, Item);

        // Injected types from labelle-engine
        const Registry = EngineTypes.Registry;
        const Position = EngineTypes.Position;
        const entityFromU64 = EngineTypes.entityFromU64;

        // ============================================
        // Global State
        // ============================================

        var task_engine: ?*Engine = null;
        var engine_allocator: ?std.mem.Allocator = null;
        var game_registry: ?*anyopaque = null;
        var game_ptr: ?*anyopaque = null;
        var distance_fn: ?*const fn (GameId, GameId) ?f32 = null;

        // Custom vtable with ensureContext
        var custom_vtable: EcsInterface.VTable = undefined;

        // ============================================
        // Lifecycle
        // ============================================

        /// Initialize the task engine context with default distance function.
        /// Call this during game initialization (e.g., in game_init hook).
        /// Uses euclidean distance based on Position components by default.
        pub fn init(allocator: std.mem.Allocator) !void {
            if (task_engine != null) return;

            engine_allocator = allocator;
            distance_fn = defaultDistanceFn;

            const eng = try allocator.create(Engine);
            eng.* = Engine.init(allocator, .{}, defaultDistanceFn);
            task_engine = eng;

            // Set up ECS interface with ensureContext callback
            const engine_iface = eng.interface();
            custom_vtable = engine_iface.vtable.*;
            custom_vtable.ensureContext = ensureContext;

            const custom_iface = EcsInterface{
                .ptr = engine_iface.ptr,
                .vtable = &custom_vtable,
            };
            InterfaceStorage.setInterface(custom_iface);

            std.log.info("[TaskEngineContext] Initialized", .{});
        }

        /// Set a custom distance function (overrides default).
        /// Call after init() if you need custom distance calculations.
        pub fn setDistanceFunction(func: *const fn (GameId, GameId) ?f32) void {
            distance_fn = func;
            if (task_engine) |eng| {
                eng.setDistanceFunction(func);
            }
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
            if (task_engine) |eng| {
                InterfaceStorage.clearInterface();
                eng.deinit();
                if (engine_allocator) |allocator| {
                    allocator.destroy(eng);
                }
            }
            task_engine = null;
            engine_allocator = null;
            game_registry = null;
            game_ptr = null;
            // Clear shared globals
            shared_registry = null;
            shared_game = null;
            std.log.info("[TaskEngineContext] Deinitialized", .{});
        }

        /// ECS bridge callback - sets game/registry pointers on first component registration.
        fn ensureContext(game_ptr_raw: *anyopaque, registry_ptr_raw: *anyopaque) void {
            if (game_registry == null) {
                game_registry = registry_ptr_raw;
                // Also set shared globals for hook payload enrichment
                shared_registry = registry_ptr_raw;
            }
            if (game_ptr == null) {
                game_ptr = game_ptr_raw;
                // Also set shared globals for hook payload enrichment
                shared_game = game_ptr_raw;
            }
        }

        // ============================================
        // Accessors
        // ============================================

        /// Get the task engine instance (if initialized).
        pub fn getEngine() ?*Engine {
            return task_engine;
        }

        /// Get the game registry pointer (if set via ensureContext).
        pub fn getRegistryPtr() ?*anyopaque {
            return game_registry;
        }

        /// Get the game pointer (if set via ensureContext).
        pub fn getGamePtr() ?*anyopaque {
            return game_ptr;
        }

        /// Get the registry cast to a specific type.
        pub fn getRegistry(comptime RegistryType: type) ?*RegistryType {
            const ptr = game_registry orelse return null;
            return @ptrCast(@alignCast(ptr));
        }

        /// Get the game cast to a specific type.
        pub fn getGame(comptime GameType: type) ?*GameType {
            const ptr = game_ptr orelse return null;
            return @ptrCast(@alignCast(ptr));
        }

        // ============================================
        // Engine Operations (convenience wrappers)
        // ============================================

        /// Notify that a pickup was completed.
        pub fn pickupCompleted(worker_id: GameId) bool {
            const eng = task_engine orelse return false;
            return eng.pickupCompleted(worker_id);
        }

        /// Notify that a store was completed.
        pub fn storeCompleted(worker_id: GameId) bool {
            const eng = task_engine orelse return false;
            return eng.storeCompleted(worker_id);
        }

        /// Notify that work was completed at a workstation.
        pub fn workCompleted(workstation_id: GameId) bool {
            const eng = task_engine orelse return false;
            return eng.workCompleted(workstation_id);
        }

        /// Notify that an item was added to a storage.
        pub fn itemAdded(storage_id: GameId, item: Item) bool {
            const eng = task_engine orelse return false;
            return eng.itemAdded(storage_id, item);
        }

        /// Notify that an item was removed from a storage.
        pub fn itemRemoved(storage_id: GameId) bool {
            const eng = task_engine orelse return false;
            return eng.itemRemoved(storage_id);
        }

        /// Notify that a worker became available.
        pub fn workerAvailable(worker_id: GameId) bool {
            const eng = task_engine orelse return false;
            return eng.workerAvailable(worker_id);
        }

        /// Generic handler for when a worker arrives at its destination.
        /// Automatically determines the correct completion based on current step.
        /// Returns true if an event was handled.
        pub fn workerArrived(worker_id: GameId) bool {
            const eng = task_engine orelse return false;
            const step = eng.getWorkerCurrentStep(worker_id) orelse return false;
            return switch (step) {
                .Pickup => eng.pickupCompleted(worker_id),
                .Store => eng.storeCompleted(worker_id),
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
            if (task_engine) |eng| {
                eng.evaluateDanglingItems();
            }
        }
    };
}

// Note: TaskEngineContext has been removed. Use TaskEngineContextWith instead,
// which requires passing EngineTypes to avoid WASM module collision.
// For the typical use case with labelle-engine, pass engine.EngineTypes.
