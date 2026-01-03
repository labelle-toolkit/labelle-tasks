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
const labelle_engine = @import("labelle-engine");

/// Context for managing task engine lifecycle and game integration.
/// Eliminates boilerplate for vtable wrapping, global state, and movement queuing.
pub fn TaskEngineContext(
    comptime GameId: type,
    comptime Item: type,
    comptime Hooks: type,
) type {
    return struct {
        const Self = @This();

        pub const Engine = engine_mod.Engine(GameId, Item, Hooks);
        pub const EcsInterface = ecs_bridge.EcsInterface(GameId, Item);
        pub const InterfaceStorage = ecs_bridge.InterfaceStorage(GameId, Item);

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
            const registry = getRegistry(labelle_engine.Registry) orelse return null;
            const Position = labelle_engine.render.Position;

            const from_entity = labelle_engine.entityFromU64(from_id);
            const to_entity = labelle_engine.entityFromU64(to_id);

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
            clearMovementQueue();
            std.log.info("[TaskEngineContext] Deinitialized", .{});
        }

        /// ECS bridge callback - sets game/registry pointers on first component registration.
        fn ensureContext(game_ptr_raw: *anyopaque, registry_ptr_raw: *anyopaque) void {
            if (game_registry == null) {
                game_registry = registry_ptr_raw;
            }
            if (game_ptr == null) {
                game_ptr = game_ptr_raw;
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

        /// Notify that a dangling pickup was completed.
        pub fn danglingPickupCompleted(worker_id: GameId) bool {
            const eng = task_engine orelse return false;
            return eng.danglingPickupCompleted(worker_id);
        }

        /// Re-evaluate dangling items (call after scene load).
        pub fn evaluateDanglingItems() void {
            if (task_engine) |eng| {
                eng.evaluateDanglingItems();
            }
        }

        // ============================================
        // Movement Queue
        // ============================================

        pub const MovementAction = enum {
            pickup,
            store,
            pickup_dangling,
        };

        pub const PendingMovement = struct {
            worker_id: GameId,
            target_x: f32,
            target_y: f32,
            action: MovementAction,
        };

        var pending_movements: std.ArrayListUnmanaged(PendingMovement) = .{};
        var movements_allocator: std.mem.Allocator = std.heap.page_allocator;

        /// Queue a movement for a worker (call from hooks).
        pub fn queueMovement(worker_id: GameId, target_x: f32, target_y: f32, action: MovementAction) void {
            pending_movements.append(movements_allocator, .{
                .worker_id = worker_id,
                .target_x = target_x,
                .target_y = target_y,
                .action = action,
            }) catch |err| {
                std.log.err("[TaskEngineContext] Failed to queue movement: {}", .{err});
            };
        }

        /// Take all pending movements (transfers ownership to caller).
        pub fn takePendingMovements() []PendingMovement {
            if (pending_movements.items.len == 0) {
                return &.{};
            }
            return pending_movements.toOwnedSlice(movements_allocator) catch &.{};
        }

        /// Free a slice returned by takePendingMovements.
        pub fn freePendingMovements(slice: []PendingMovement) void {
            if (slice.len > 0) {
                movements_allocator.free(slice);
            }
        }

        fn clearMovementQueue() void {
            pending_movements.deinit(movements_allocator);
            pending_movements = .{};
        }
    };
}
