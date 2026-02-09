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

/// Components parameterized by EngineTypes to avoid direct labelle-engine imports.
/// This prevents WASM module collision when both labelle-engine and labelle-tasks
/// try to import the same engine module.
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

                /// Component callback - called after hierarchy is complete (RFC #169).
                /// Registers the storage with the task engine and attaches to parent workstation.
                pub fn onReady(payload: ComponentPayload) void {
                    const iface = Interface.getActive() orelse {
                        std.log.warn("[tasks.Storage] No ECS interface set - storage {d} not registered", .{payload.entity_id});
                        return;
                    };

                    // Get component data from registry
                    const entity = entityFromU64(payload.entity_id);
                    const game = payload.getGame(Game);
                    const registry = game.getRegistry();
                    const self = registry.tryGet(Self, entity) orelse {
                        std.log.err("[tasks.Storage] Could not get component data for entity {d}", .{payload.entity_id});
                        return;
                    };

                    // Register storage with task engine
                    iface.addStorage(payload.entity_id, self.role, self.initial_item, self.accepts) catch |err| {
                        std.log.err("[tasks.Storage] Failed to add storage {d}: {}", .{ payload.entity_id, err });
                        return;
                    };

                    // Attach to parent workstation if set (RFC #169)
                    if (isValidEntity(self.workstation)) {
                        const workstation_id = entityToU64(self.workstation);
                        iface.attachStorageToWorkstation(payload.entity_id, workstation_id, self.role) catch |err| {
                            std.log.err("[tasks.Storage] Failed to attach storage {d} to workstation {d}: {}", .{
                                payload.entity_id,
                                workstation_id,
                                err,
                            });
                            return;
                        };
                        std.log.info("[tasks.Storage] Storage {d} attached to workstation {d} as {s}", .{
                            payload.entity_id,
                            workstation_id,
                            @tagName(self.role),
                        });
                    }
                }

                /// Component callback - called when component is removed from entity.
                /// Automatically unregisters the storage from the task engine.
                pub fn onRemove(payload: ComponentPayload) void {
                    const iface = Interface.getActive() orelse return;
                    iface.removeStorage(payload.entity_id);
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

                /// Component callback - called when component is added to entity.
                pub fn onAdd(payload: ComponentPayload) void {
                    const iface = Interface.getActive() orelse {
                        std.log.warn("[tasks.Worker] No ECS interface set - worker {d} not registered", .{payload.entity_id});
                        return;
                    };

                    // Get component data from registry
                    const entity = entityFromU64(payload.entity_id);
                    const game = payload.getGame(Game);
                    const registry = game.getRegistry();
                    const self = registry.tryGet(Self, entity) orelse {
                        std.log.err("[tasks.Worker] Could not get component data for entity {d}", .{payload.entity_id});
                        return;
                    };

                    iface.addWorker(payload.entity_id) catch |err| {
                        std.log.err("[tasks.Worker] Failed to add worker {d}: {}", .{ payload.entity_id, err });
                        return;
                    };

                    // If worker starts available, notify the engine
                    if (self.available) {
                        _ = iface.workerAvailable(payload.entity_id);
                    }
                }

                /// Component callback - called when component is removed from entity.
                pub fn onRemove(payload: ComponentPayload) void {
                    const iface = Interface.getActive() orelse return;
                    iface.removeWorker(payload.entity_id);
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

                    iface.addWorkstation(payload.entity_id) catch |err| {
                        std.log.err("[tasks.Workstation] Failed to add workstation {d}: {}", .{ payload.entity_id, err });
                        return;
                    };

                    std.log.info("[tasks.Workstation] Entity {d} registered (storages will self-attach)", .{payload.entity_id});
                }

                /// Component callback - called when component is removed.
                pub fn onRemove(payload: ComponentPayload) void {
                    const iface = Interface.getActive() orelse return;
                    iface.removeWorkstation(payload.entity_id);
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

                /// Component callback - called when component is added to entity.
                pub fn onAdd(payload: ComponentPayload) void {
                    const iface = Interface.getActive() orelse {
                        std.log.warn("[tasks.DanglingItem] No ECS interface set - item {d} not registered", .{payload.entity_id});
                        return;
                    };

                    // Get component data from registry
                    const entity = entityFromU64(payload.entity_id);
                    const game = payload.getGame(Game);
                    const registry = game.getRegistry();
                    const self = registry.tryGet(Self, entity) orelse {
                        std.log.err("[tasks.DanglingItem] Could not get component data for entity {d}", .{payload.entity_id});
                        return;
                    };

                    iface.addDanglingItem(payload.entity_id, self.item_type) catch |err| {
                        std.log.err("[tasks.DanglingItem] Failed to add dangling item {d}: {}", .{ payload.entity_id, err });
                    };
                }

                /// Component callback - called when component is removed from entity.
                pub fn onRemove(payload: ComponentPayload) void {
                    const iface = Interface.getActive() orelse return;
                    iface.removeDanglingItem(payload.entity_id);
                }
            };
        }
    };
}
