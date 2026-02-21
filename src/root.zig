//! labelle-tasks: Pure state machine task orchestration engine
//!
//! This module provides a task orchestration engine that tracks abstract workflow
//! state and emits hooks to notify the game of events. The engine never mutates
//! game state directly - it only updates its internal abstract state.
//!
//! ## Quick Start
//!
//! ```zig
//! const tasks = @import("labelle-tasks");
//!
//! const Item = enum { Flour, Bread };
//!
//! // Define hooks to receive from task engine
//! const MyHooks = struct {
//!     pub fn process_completed(payload: anytype) void {
//!         // Game handles entity transformation
//!     }
//!     pub fn cycle_completed(payload: anytype) void {
//!         // Cycle finished
//!     }
//! };
//!
//! // Create engine
//! var engine = tasks.Engine(u32, Item, MyHooks).init(allocator, .{});
//! defer engine.deinit();
//!
//! // Register entities
//! engine.addStorage(eis_id, .Flour);
//! engine.addStorage(iis_id, null);
//! engine.addStorage(ios_id, null);
//! engine.addStorage(eos_id, null);
//! engine.addWorkstation(ws_id, .{ .eis = &.{eis_id}, .iis = &.{iis_id}, ... });
//! engine.addWorker(worker_id);
//!
//! // Game notifies engine of events
//! engine.handle(.{ .worker_available = .{ .worker_id = worker_id } });
//! engine.handle(.{ .pickup_completed = .{ .worker_id = worker_id } });
//! engine.handle(.{ .work_completed = .{ .workstation_id = ws_id } });
//! engine.handle(.{ .store_completed = .{ .worker_id = worker_id } });
//! ```
//!
//! ## Workflow
//!
//! Items flow through storages: EIS → IIS (Pickup) → IOS (Process) → EOS (Store)
//!
//! - **EIS**: External Input Storage - source of raw materials
//! - **IIS**: Internal Input Storage - recipe inputs
//! - **IOS**: Internal Output Storage - recipe outputs
//! - **EOS**: External Output Storage - finished products
//!
//! ## Architecture
//!
//! The engine is a pure state machine:
//! - Tracks abstract state (has_item, item_type, current_step, assigned_worker)
//! - Receives notifications from game via handle(GameHookPayload)
//! - Emits hooks to game via TaskHookPayload
//! - Never mutates game state (no entity references, no timers)
//!
//! Game owns:
//! - Entity lifecycle (prefabs, creation, destruction)
//! - Work timing (timers, accumulated work)
//! - Movement/pathfinding
//! - All ECS state

const engine_mod = @import("engine.zig");
const hooks_mod = @import("hooks.zig");

// === Core Engine ===

/// Pure state machine task orchestration engine.
/// Generic over GameId (entity identifier), Item (item enum), and TaskHooks (hook receiver).
pub const Engine = engine_mod.Engine;

// === Hooks ===

/// Payload for events emitted by task engine to game.
/// Game subscribes to these hooks to react to workflow events.
pub const TaskHookPayload = hooks_mod.TaskHookPayload;

/// Payload for events sent by game to task engine.
/// Game calls engine.handle() with these payloads.
pub const GameHookPayload = hooks_mod.GameHookPayload;

/// Hook dispatcher for calling comptime hook methods.
pub const HookDispatcher = hooks_mod.HookDispatcher;

/// Empty hooks struct for engines that don't need hooks.
pub const NoHooks = hooks_mod.NoHooks;

/// Recording hooks for testing. Records all dispatched events for assertion.
pub const RecordingHooks = hooks_mod.RecordingHooks;

// === Logging Hooks ===

const logging_hooks_mod = @import("logging_hooks.zig");

/// Default logging implementation for all task engine hooks.
/// Use directly or merge with custom hooks using MergeHooks.
pub const LoggingHooks = logging_hooks_mod.LoggingHooks;

/// Merges two hook structs, with Primary taking precedence over Fallback.
/// Use to compose custom hooks with LoggingHooks for default logging.
///
/// Example:
/// ```zig
/// const MyHooks = struct {
///     pub fn store_started(payload: anytype) void {
///         // Custom behavior
///     }
/// };
/// const Hooks = tasks.MergeHooks(MyHooks, tasks.LoggingHooks);
/// ```
pub const MergeHooks = logging_hooks_mod.MergeHooks;

// === Enums ===

const state_mod = @import("state.zig");

/// Worker state in the task engine.
pub const WorkerState = engine_mod.WorkerState;

/// Workstation status in the task pipeline.
pub const WorkstationStatus = engine_mod.WorkstationStatus;

/// Current step in the workstation cycle.
pub const StepType = engine_mod.StepType;

/// Priority levels for workstations and storages.
pub const Priority = engine_mod.Priority;

/// Storage role in the workflow (EIS, IIS, IOS, EOS).
pub const StorageRole = state_mod.StorageRole;

// === ECS Integration (RFC #28) ===

const ecs_bridge = @import("ecs_bridge.zig");
const components_mod = @import("components.zig");
const context_mod = @import("context.zig");

/// Helper to reduce game integration boilerplate.
/// Manages task engine lifecycle, vtable wrapping, and movement queue.
///
/// Example:
/// ```zig
/// const tasks = @import("labelle-tasks");
///
/// const MyHooks = struct {
///     pub fn store_started(payload: anytype) void {
///         const pos = getStoragePosition(payload.storage_id);
///         Context.queueMovement(payload.worker_id, pos.x, pos.y, .store);
///     }
/// };
///
/// pub const Context = tasks.TaskEngineContext(u64, Item, MyHooks);
///
/// // In game_init hook:
/// Context.init(allocator, getEntityDistance) catch return;
///
/// // In game_deinit hook:
/// Context.deinit();
/// ```
pub fn TaskEngineContext(comptime GameId: type, comptime Item: type, comptime Hooks: type) type {
    return context_mod.TaskEngineContext(GameId, Item, Hooks);
}

/// Type-erased interface for ECS operations.
pub fn EcsInterface(comptime GameId: type, comptime Item: type) type {
    return ecs_bridge.EcsInterface(GameId, Item);
}

/// Set the ECS interface for auto-registering components.
/// Call this during game initialization after creating the task engine.
///
/// Example:
/// ```zig
/// var task_engine = tasks.Engine(u64, Item, Hooks).init(allocator, .{});
/// tasks.setEngineInterface(u64, Item, task_engine.interface());
/// ```
pub fn setEngineInterface(comptime GameId: type, comptime Item: type, iface: EcsInterface(GameId, Item)) void {
    comptime {
        if (GameId != u64) @compileError("setEngineInterface requires GameId = u64 to match component bridge type");
    }
    ecs_bridge.EcsInterface(GameId, Item).setActive(iface);
}

/// Clear the ECS interface (for cleanup).
pub fn clearEngineInterface(comptime GameId: type, comptime Item: type) void {
    comptime {
        if (GameId != u64) @compileError("clearEngineInterface requires GameId = u64 to match component bridge type");
    }
    ecs_bridge.EcsInterface(GameId, Item).clearActive();
}

/// Pure registration functions for task engine components.
/// These functions accept the ECS interface and data directly, enabling
/// unit testing without requiring a full ECS setup.
///
/// Example:
/// ```zig
/// const Reg = tasks.Registration(u64, Item);
/// try Reg.registerStorage(iface, entity_id, .eis, .Flour, null, null);
/// try Reg.registerWorker(iface, worker_id, true);
/// ```
pub const Registration = components_mod.Registration;

/// Storage component for the task engine.
/// Auto-registers with task engine when added to an entity.
pub fn Storage(comptime Item: type) type {
    return components_mod.Storage(Item);
}

/// Worker component for the task engine.
/// Auto-registers with task engine when added to an entity.
pub fn Worker(comptime Item: type) type {
    return components_mod.Worker(Item);
}

/// Dangling item component for the task engine.
/// Auto-registers with task engine when added to an entity.
pub fn DanglingItem(comptime Item: type) type {
    return components_mod.DanglingItem(Item);
}

/// Workstation component for the task engine.
/// Auto-registers with task engine when added to an entity.
/// Nested Storage components will auto-attach via parent reference.
pub fn Workstation(comptime Item: type) type {
    return components_mod.Workstation(Item);
}

/// Bind function for plugin component integration.
/// Returns a struct with all component types parameterized by Item and EngineTypes.
/// The generator iterates public decls to find component types.
///
/// Example:
/// ```zig
/// // project.labelle
/// .plugins = .{
///     .{
///         .name = "labelle-tasks",
///         .path = "../../labelle-tasks",
///         .bind = .{
///             .{ .func = "bind", .args = .{"Items", "engine.EngineTypes"} },
///         },
///     },
/// },
/// ```
pub fn bind(comptime Item: type, comptime EngineTypes: type) type {
    const Components = components_mod.ComponentsWith(EngineTypes);
    return struct {
        pub const Storage = Components.Storage(Item);
        pub const Worker = Components.Worker(Item);
        pub const DanglingItem = Components.DanglingItem(Item);
        pub const Workstation = Components.Workstation(Item);
    };
}

/// Creates engine hooks for task engine lifecycle management.
/// Reduces game boilerplate by providing standard game_init, scene_load, and game_deinit hooks.
///
/// The game provides:
/// - GameId: Entity identifier type (usually u64)
/// - ItemType: Item enum for the task system
/// - GameHooks: Game-specific task hook handlers (store_started, pickup_dangling_started, etc.)
/// - EngineTypes: Type bundle from labelle-engine containing HookPayload, Registry, Game, etc.
///
/// Returns a struct containing:
/// - Context: The TaskEngineContext for accessing engine/registry
/// - game_init, scene_load, game_deinit: Engine hooks
///
/// Hook payloads are enriched with .registry and .game pointers for direct ECS access.
/// A default distance function (euclidean distance using Position components) is used.
/// To override, call Context.setDistanceFunction() after initialization.
///
/// Example:
/// ```zig
/// const engine = @import("labelle-engine");
/// const tasks = @import("labelle-tasks");
///
/// const GameHooks = struct {
///     pub fn store_started(payload: anytype) void {
///         const registry = payload.registry orelse return;
///         const worker = engine.entityFromU64(payload.original.worker_id);
///         registry.set(worker, MovementTarget{ ... });
///     }
/// };
///
/// pub const TaskHooks = tasks.createEngineHooks(u64, ItemType, GameHooks, engine.EngineTypes);
/// pub const Context = TaskHooks.Context;
/// ```
pub fn createEngineHooks(
    comptime GameId: type,
    comptime ItemType: type,
    comptime GameHooks: type,
    comptime EngineTypes: type,
) type {
    const Registry = EngineTypes.Registry;
    const Game = EngineTypes.Game;

    // Create a wrapper that enriches payloads with registry and game.
    // Uses active context instance for registry/game access.
    const WrappedHooks = struct {
        /// Flat enriched payload: copies all original fields to top level + adds registry/game.
        /// This preserves backward compatibility so game hooks can access payload.worker_id directly.
        fn EnrichedPayload(comptime Original: type) type {
            return struct {
                // Copy original payload fields (void if not present in original)
                worker_id: if (@hasField(Original, "worker_id")) @FieldType(Original, "worker_id") else void = if (@hasField(Original, "worker_id")) undefined else {},
                storage_id: if (@hasField(Original, "storage_id")) @FieldType(Original, "storage_id") else void = if (@hasField(Original, "storage_id")) undefined else {},
                workstation_id: if (@hasField(Original, "workstation_id")) @FieldType(Original, "workstation_id") else void = if (@hasField(Original, "workstation_id")) undefined else {},
                item: if (@hasField(Original, "item")) @FieldType(Original, "item") else void = if (@hasField(Original, "item")) undefined else {},
                item_id: if (@hasField(Original, "item_id")) @FieldType(Original, "item_id") else void = if (@hasField(Original, "item_id")) undefined else {},
                item_type: if (@hasField(Original, "item_type")) @FieldType(Original, "item_type") else void = if (@hasField(Original, "item_type")) undefined else {},
                target_storage_id: if (@hasField(Original, "target_storage_id")) @FieldType(Original, "target_storage_id") else void = if (@hasField(Original, "target_storage_id")) undefined else {},
                from_storage_id: if (@hasField(Original, "from_storage_id")) @FieldType(Original, "from_storage_id") else void = if (@hasField(Original, "from_storage_id")) undefined else {},
                to_storage_id: if (@hasField(Original, "to_storage_id")) @FieldType(Original, "to_storage_id") else void = if (@hasField(Original, "to_storage_id")) undefined else {},
                cycles_completed: if (@hasField(Original, "cycles_completed")) @FieldType(Original, "cycles_completed") else void = if (@hasField(Original, "cycles_completed")) undefined else {},

                // Added context fields
                registry: ?*Registry,
                game: ?*Game,

                fn create(original: Original) @This() {
                    var result: @This() = .{
                        .registry = context_mod.getSharedRegistry(Registry),
                        .game = context_mod.getSharedGame(Game),
                    };
                    inline for (@typeInfo(Original).@"struct".fields) |field| {
                        @field(result, field.name) = @field(original, field.name);
                    }
                    return result;
                }
            };
        }

        /// Dispatch to GameHooks if it has the declaration, enriching the payload.
        inline fn dispatch(comptime name: []const u8, payload: anytype) void {
            if (@hasDecl(GameHooks, name)) {
                const enriched = EnrichedPayload(@TypeOf(payload)).create(payload);
                @field(GameHooks, name)(enriched);
            }
        }

        // Hook forwarding - each calls dispatch with its name
        pub fn store_started(payload: anytype) void { dispatch("store_started", payload); }
        pub fn pickup_started(payload: anytype) void { dispatch("pickup_started", payload); }
        pub fn pickup_dangling_started(payload: anytype) void { dispatch("pickup_dangling_started", payload); }
        pub fn item_delivered(payload: anytype) void { dispatch("item_delivered", payload); }
        pub fn process_started(payload: anytype) void { dispatch("process_started", payload); }
        pub fn process_completed(payload: anytype) void { dispatch("process_completed", payload); }
        pub fn worker_assigned(payload: anytype) void { dispatch("worker_assigned", payload); }
        pub fn worker_released(payload: anytype) void { dispatch("worker_released", payload); }
        pub fn workstation_blocked(payload: anytype) void { dispatch("workstation_blocked", payload); }
        pub fn workstation_queued(payload: anytype) void { dispatch("workstation_queued", payload); }
        pub fn workstation_activated(payload: anytype) void { dispatch("workstation_activated", payload); }
        pub fn cycle_completed(payload: anytype) void { dispatch("cycle_completed", payload); }
        pub fn transport_started(payload: anytype) void { dispatch("transport_started", payload); }
        pub fn transport_completed(payload: anytype) void { dispatch("transport_completed", payload); }
        pub fn input_consumed(payload: anytype) void { dispatch("input_consumed", payload); }
    };

    const MergedHooks = logging_hooks_mod.MergeHooks(WrappedHooks, logging_hooks_mod.LoggingHooks);
    const Ctx = context_mod.TaskEngineContextWith(GameId, ItemType, MergedHooks, EngineTypes);

    return struct {
        pub const Context = Ctx;

        const std = @import("std");

        /// Initialize task engine during game initialization.
        /// Uses default euclidean distance function based on Position components.
        pub fn game_init(payload: EngineTypes.HookPayload) void {
            const info = payload.game_init;

            _ = Context.init(info.allocator) catch |err| {
                std.log.err("[labelle-tasks] Failed to initialize task engine: {}", .{err});
                return;
            };

            std.log.info("[labelle-tasks] Task engine initialized", .{});
        }

        /// Re-evaluate after scene is loaded (all entities now registered)
        pub fn scene_load(payload: EngineTypes.HookPayload) void {
            const info = payload.scene_load;
            std.log.debug("[labelle-tasks] scene_load: {s} - re-evaluating dangling items and workstations", .{info.name});

            if (Context.getEngine()) |task_eng| {
                task_eng.evaluateDanglingItems();
                task_eng.reevaluateWorkstations();
            }
        }

        /// Clean up task engine on game deinit
        pub fn game_deinit(payload: EngineTypes.HookPayload) void {
            _ = payload;
            Context.deinit();
            std.log.info("[labelle-tasks] Task engine cleaned up", .{});
        }
    };
}
