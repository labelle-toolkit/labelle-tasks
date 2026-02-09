//! ECS Components for labelle-tasks
//!
//! These components are exported by labelle-tasks for games to use directly.
//! When added/removed from entities, they automatically register/unregister
//! with the task engine via the ECS bridge interface.
//!
//! Usage:
//! ```zig
//! const tasks = @import("labelle-tasks");
//! const Item = enum { Flour, Bread };
//!
//! // Set the interface during game init
//! tasks.setEngineInterface(u64, Item, task_engine.interface());
//!
//! // Use in ECS
//! registry.add(entity, tasks.Storage(Item){
//!     .role = .eis,
//!     .initial_item = .Flour,
//! });
//! ```

const std = @import("std");
const ecs_bridge = @import("ecs_bridge.zig");

pub const StorageRole = ecs_bridge.StorageRole;

/// Pure registration functions for task engine components.
/// These functions accept the interface and data directly, enabling
/// unit testing without requiring a full ECS setup.
pub fn Registration(comptime GameId: type, comptime Item: type) type {
    const Interface = ecs_bridge.EcsInterface(GameId, Item);

    return struct {
        /// Register a storage with the task engine and optionally attach to a workstation.
        pub fn registerStorage(
            iface: Interface,
            entity_id: GameId,
            role: StorageRole,
            initial_item: ?Item,
            accepts: ?Item,
            workstation_id: ?GameId,
        ) !void {
            try iface.addStorage(entity_id, role, initial_item, accepts);
            if (workstation_id) |ws_id| {
                try iface.attachStorageToWorkstation(entity_id, ws_id, role);
            }
        }

        /// Unregister a storage from the task engine.
        pub fn unregisterStorage(iface: Interface, entity_id: GameId) void {
            iface.removeStorage(entity_id);
        }

        /// Register a worker with the task engine.
        /// If available is true, also notifies the engine that the worker is ready.
        pub fn registerWorker(iface: Interface, entity_id: GameId, available: bool) !void {
            try iface.addWorker(entity_id);
            if (available) {
                _ = iface.workerAvailable(entity_id);
            }
        }

        /// Unregister a worker from the task engine.
        pub fn unregisterWorker(iface: Interface, entity_id: GameId) void {
            iface.removeWorker(entity_id);
        }

        /// Register a workstation with the task engine.
        pub fn registerWorkstation(iface: Interface, entity_id: GameId) !void {
            try iface.addWorkstation(entity_id);
        }

        /// Unregister a workstation from the task engine.
        pub fn unregisterWorkstation(iface: Interface, entity_id: GameId) void {
            iface.removeWorkstation(entity_id);
        }

        /// Register a dangling item with the task engine.
        pub fn registerDanglingItem(iface: Interface, entity_id: GameId, item_type: Item) !void {
            try iface.addDanglingItem(entity_id, item_type);
        }

        /// Unregister a dangling item from the task engine.
        pub fn unregisterDanglingItem(iface: Interface, entity_id: GameId) void {
            iface.removeDanglingItem(entity_id);
        }
    };
}

/// Components parameterized by EngineTypes to avoid direct labelle-engine imports.
/// This prevents WASM module collision when both labelle-engine and labelle-tasks
/// try to import the same engine module.
///
/// Note: Components use `EcsInterface(u64, Item)` because ECS entity IDs are always u64.
/// The task engine must also be initialized with `GameId = u64` so the bridge's
/// comptime-scoped active pointer matches (enforced by TaskEngineContextWith).
pub fn ComponentsWith(comptime EngineTypes: type) type {
    const Entity = EngineTypes.Entity;
    const ComponentPayload = EngineTypes.ComponentPayload;
    const Game = EngineTypes.Game;
    const entityFromU64 = EngineTypes.entityFromU64;
    const entityToU64 = EngineTypes.entityToU64;

    return struct {

        /// Storage component for the task engine.
        /// Represents a slot that can hold one item.
        ///
        /// When this component is added to an entity, it automatically registers
        /// with the task engine. When removed, it unregisters.
        ///
        /// Parent Reference (RFC #169): When nested inside a Workstation component,
        /// the `workstation` field is automatically populated by the loader.
        pub fn Storage(comptime Item: type) type {
            const Interface = ecs_bridge.EcsInterface(u64, Item);

            return struct {
                /// Role in the workflow (EIS, IIS, IOS, EOS)
                role: StorageRole = .eis,

                /// Item currently in storage (null = empty)
                initial_item: ?Item = null,

                /// Item type this storage accepts (null = any)
                accepts: ?Item = null,

                /// Parent workstation entity (RFC #169).
                /// Auto-populated by loader when nested inside a Workstation component.
                workstation: Entity = getInvalidEntity(),

                const Self = @This();

                /// Get an invalid entity value (works across ECS backends)
                fn getInvalidEntity() Entity {
                    if (@hasDecl(Entity, "invalid")) {
                        return Entity.invalid;
                    } else {
                        // Use 0 as invalid entity - works for integer and struct-based entities
                        const T = @typeInfo(Entity);
                        switch (T) {
                            .int => return 0,
                            .@"struct" => {
                                const BackingInt = T.@"struct".backing_integer orelse u32;
                                return @bitCast(@as(BackingInt, 0));
                            },
                            else => @compileError("Entity must be an integer or packed struct type"),
                        }
                    }
                }

                /// Check if an entity is valid (not the invalid sentinel)
                fn isValidEntity(entity: Entity) bool {
                    return entityToU64(entity) != 0;
                }

                const Reg = Registration(u64, Item);

                /// Component callback - called after hierarchy is complete (RFC #169).
                /// Registers the storage with the task engine and attaches to parent workstation.
                pub fn onReady(payload: ComponentPayload) void {
                    const iface = Interface.getActive() orelse {
                        std.log.warn("[tasks.Storage] No ECS interface set - storage {d} not registered", .{payload.entity_id});
                        return;
                    };

                    const entity = entityFromU64(payload.entity_id);
                    const game = payload.getGame(Game);
                    const registry = game.getRegistry();
                    const self = registry.tryGet(Self, entity) orelse {
                        std.log.err("[tasks.Storage] Could not get component data for entity {d}", .{payload.entity_id});
                        return;
                    };

                    const ws_id: ?u64 = if (isValidEntity(self.workstation)) entityToU64(self.workstation) else null;
                    Reg.registerStorage(iface, payload.entity_id, self.role, self.initial_item, self.accepts, ws_id) catch |err| {
                        std.log.err("[tasks.Storage] Failed to register storage {d}: {}", .{ payload.entity_id, err });
                        return;
                    };

                    if (ws_id) |wid| {
                        std.log.info("[tasks.Storage] Storage {d} attached to workstation {d} as {s}", .{
                            payload.entity_id,
                            wid,
                            @tagName(self.role),
                        });
                    }
                }

                /// Component callback - called when component is removed from entity.
                /// Automatically unregisters the storage from the task engine.
                pub fn onRemove(payload: ComponentPayload) void {
                    const iface = Interface.getActive() orelse return;
                    Reg.unregisterStorage(iface, payload.entity_id);
                }
            };
        }

        /// Worker component for the task engine.
        /// Represents an entity that can perform work at workstations.
        ///
        /// When this component is added to an entity, it automatically registers
        /// with the task engine as idle. When removed, it unregisters.
        pub fn Worker(comptime Item: type) type {
            const Interface = ecs_bridge.EcsInterface(u64, Item);

            return struct {
                /// Whether the worker starts as available (default: true)
                available: bool = true,

                const Self = @This();
                const Reg = Registration(u64, Item);

                /// Component callback - called when component is added to entity.
                pub fn onAdd(payload: ComponentPayload) void {
                    const iface = Interface.getActive() orelse {
                        std.log.warn("[tasks.Worker] No ECS interface set - worker {d} not registered", .{payload.entity_id});
                        return;
                    };

                    const entity = entityFromU64(payload.entity_id);
                    const game = payload.getGame(Game);
                    const registry = game.getRegistry();
                    const self = registry.tryGet(Self, entity) orelse {
                        std.log.err("[tasks.Worker] Could not get component data for entity {d}", .{payload.entity_id});
                        return;
                    };

                    Reg.registerWorker(iface, payload.entity_id, self.available) catch |err| {
                        std.log.err("[tasks.Worker] Failed to register worker {d}: {}", .{ payload.entity_id, err });
                        return;
                    };
                }

                /// Component callback - called when component is removed from entity.
                pub fn onRemove(payload: ComponentPayload) void {
                    const iface = Interface.getActive() orelse return;
                    Reg.unregisterWorker(iface, payload.entity_id);
                }
            };
        }

        /// Workstation component for the task engine.
        /// Represents a processing station (oven, forge, loom, etc.).
        ///
        /// When this component is added to an entity, it automatically registers
        /// with the task engine. Nested Storage components will auto-attach via
        /// parent reference (RFC #169).
        pub fn Workstation(comptime Item: type) type {
            const Interface = ecs_bridge.EcsInterface(u64, Item);

            return struct {
                /// Processing duration in frames (0 = use default)
                process_duration: u32 = 120,

                /// Nested storage entities - auto-created from prefab definitions.
                /// Storage components will have their `workstation` field auto-populated.
                storages: []const Entity = &.{},

                const Reg = Registration(u64, Item);

                /// Component callback - called when component is added.
                /// Registers immediately so it's available when Storage.onReady fires.
                pub fn onAdd(payload: ComponentPayload) void {
                    const iface = Interface.getActive() orelse {
                        std.log.warn("[tasks.Workstation] No ECS interface set - workstation {d} not registered", .{payload.entity_id});
                        return;
                    };

                    // Ensure game context is set up (for distance calculations, etc.)
                    const game = payload.getGame(Game);
                    const registry = game.getRegistry();
                    iface.ensureContext(game, registry);

                    Reg.registerWorkstation(iface, payload.entity_id) catch |err| {
                        std.log.err("[tasks.Workstation] Failed to register workstation {d}: {}", .{ payload.entity_id, err });
                        return;
                    };

                    std.log.info("[tasks.Workstation] Entity {d} registered (storages will self-attach)", .{payload.entity_id});
                }

                /// Component callback - called when component is removed.
                pub fn onRemove(payload: ComponentPayload) void {
                    const iface = Interface.getActive() orelse return;
                    Reg.unregisterWorkstation(iface, payload.entity_id);
                    std.log.info("[tasks.Workstation] Entity {d} removed", .{payload.entity_id});
                }
            };
        }

        /// Dangling item component for the task engine.
        /// Represents an item that is not in any storage and needs to be delivered.
        ///
        /// When this component is added to an entity, it registers as a dangling item
        /// that idle workers can pick up and deliver to an empty EIS.
        pub fn DanglingItem(comptime Item: type) type {
            const Interface = ecs_bridge.EcsInterface(u64, Item);

            return struct {
                /// The type of item this entity represents
                item_type: Item,

                const Self = @This();
                const Reg = Registration(u64, Item);

                /// Component callback - called when component is added to entity.
                pub fn onAdd(payload: ComponentPayload) void {
                    const iface = Interface.getActive() orelse {
                        std.log.warn("[tasks.DanglingItem] No ECS interface set - item {d} not registered", .{payload.entity_id});
                        return;
                    };

                    const entity = entityFromU64(payload.entity_id);
                    const game = payload.getGame(Game);
                    const registry = game.getRegistry();
                    const self = registry.tryGet(Self, entity) orelse {
                        std.log.err("[tasks.DanglingItem] Could not get component data for entity {d}", .{payload.entity_id});
                        return;
                    };

                    Reg.registerDanglingItem(iface, payload.entity_id, self.item_type) catch |err| {
                        std.log.err("[tasks.DanglingItem] Failed to register dangling item {d}: {}", .{ payload.entity_id, err });
                    };
                }

                /// Component callback - called when component is removed from entity.
                pub fn onRemove(payload: ComponentPayload) void {
                    const iface = Interface.getActive() orelse return;
                    Reg.unregisterDanglingItem(iface, payload.entity_id);
                }
            };
        }
    };
}
