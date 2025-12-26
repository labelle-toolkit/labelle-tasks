# RFC 026: Prefab-based Workstation Setup

**Status**: Draft
**Issue**: [#26](https://github.com/labelle-toolkit/labelle-tasks/issues/26)
**Author**: @alexandrecalvao
**Created**: 2025-12-26

## Summary

Integrate labelle-tasks with labelle-engine's existing prefab and entity reference system to define complete workstations using .zon files.

## Motivation

labelle-engine already has a powerful system for:
- Prefab definitions with components
- Entity references in component fields (`Entity` type)
- Entity lists in component fields (`[]const Entity` type)
- Nested prefabs with component overrides
- Relative positioning for child entities

labelle-tasks should leverage this existing infrastructure rather than inventing new patterns.

## Real-world Example: labelle_flying_platform

The flying platform demo already implements a pattern very similar to this proposal:

### Room Component with Entity Lists

```zig
// components/room.zig
pub const Room = struct {
    movement_nodes: []const engine.Entity = &.{},
};
```

### Usage in Prefab (simple_kitchen.zon)

```zig
.Room = .{
    .movement_nodes = .{
        .{
            .components = .{
                .Position = .{ .x = 26, .y = -93 },
                .Shape = .{ .type = .circle, .radius = 4 },
                .MovementNode = .{},
            },
        },
        .{
            .components = .{
                .Position = .{ .x = 78, .y = -93 },
                .Shape = .{ .type = .circle, .radius = 4 },
                .MovementNode = .{},
            },
        },
        // ... more nodes
    },
},
```

This demonstrates that **inline entity definitions with multiple components work today** in labelle-engine. The movement nodes have no sprites - they only have Shape for debug visualization. Internal storages (IIS/IOS) can follow the same pattern.

## labelle-engine Patterns (Reference)

### Entity References in Components

Components can reference other entities using `Entity` or `[]const Entity` fields:

```zig
// Component with single entity reference
const Weapon = struct {
    projectile: Entity = Entity.invalid,
};

// Component with entity list
const Room = struct {
    movement_nodes: []const Entity = &.{},
};
```

### Usage in .zon Files

```zig
// Prefab reference with component overrides
.Weapon = .{
    .projectile = .{
        .prefab = "bullet",
        .components = .{ .Damage = .{ .value = 25 } }
    },
},

// Entity list with prefab references
.Room = .{
    .movement_nodes = .{
        .{ .prefab = "patrol_point", .components = .{ .Position = .{ .x = 50 } } },
        .{ .prefab = "patrol_point", .components = .{ .Position = .{ .x = 100 } } },
    },
},

// Mixed prefab and inline definitions
.Room = .{
    .movement_nodes = .{
        .{ .prefab = "patrol_point" },
        .{ .components = .{ .Position = .{ .x = 50 }, .Shape = .{ .type = .circle } } },
    },
},
```

## Proposed Design for labelle-tasks

### 1. TaskWorkstation Component

Define a component that uses entity references for storages:

```zig
// In labelle-tasks EcsComponents
pub fn EcsComponents(comptime ItemType: type) type {
    return struct {
        pub const ItemSet = std.EnumSet(ItemType);

        /// Workstation that processes items through a recipe
        pub const TaskWorkstation = struct {
            /// External Input Storages - where raw materials come from
            eis: []const Entity = &.{},
            /// Internal Input Storages - recipe inputs (defines what's needed)
            iis: []const Entity = &.{},
            /// Internal Output Storages - recipe outputs (defines what's produced)
            ios: []const Entity = &.{},
            /// External Output Storages - where finished products go
            eos: []const Entity = &.{},
            /// Duration in ticks for processing
            process_duration: u32 = 0,
            /// Priority for worker assignment
            priority: Priority = .Normal,
        };

        /// Storage that holds items
        pub const TaskStorage = struct {
            /// What item type this storage accepts
            accepts: ItemSet = ItemSet.initFull(),
        };

        /// Worker that can perform tasks
        pub const TaskWorker = struct {
            priority: u4 = 5,
        };

        /// Transport route between storages
        pub const TaskTransport = struct {
            from: Entity = Entity.invalid,
            to: Entity = Entity.invalid,
            item: ItemType,
            priority: Priority = .Normal,
        };
    };
}
```

### 2. Storage Prefabs

Define reusable storage prefabs:

```zig
// prefabs/vegetable_storage.zon
.{
    .components = .{
        .Position = .{ .x = 0, .y = 0 },
        .Sprite = .{ .name = "crate.png" },
        .TaskStorage = .{ .accepts = .{ .Vegetable = true } },
    },
}

// prefabs/meal_storage.zon
.{
    .components = .{
        .Position = .{ .x = 0, .y = 0 },
        .Sprite = .{ .name = "plate_rack.png" },
        .TaskStorage = .{ .accepts = .{ .Meal = true } },
    },
}
```

### 3. Workstation Prefabs with Nested Storages

```zig
// prefabs/kitchen.zon
.{
    .components = .{
        .Position = .{ .x = 0, .y = 0 },
        .Sprite = .{ .name = "kitchen.png", .z_index = 10 },
        .TaskWorkstation = .{
            .process_duration = 40,
            .priority = .High,
            // EIS - where ingredients come from
            .eis = .{
                .{
                    .prefab = "vegetable_storage",
                    .components = .{ .Position = .{ .x = -30, .y = 0 } }
                },
                .{
                    .prefab = "meat_storage",
                    .components = .{ .Position = .{ .x = -30, .y = 20 } }
                },
            },
            // IIS - recipe requirements (1 vegetable + 1 meat)
            .iis = .{
                .{ .components = .{ .TaskStorage = .{ .accepts = .{ .Vegetable = true } } } },
                .{ .components = .{ .TaskStorage = .{ .accepts = .{ .Meat = true } } } },
            },
            // IOS - recipe output (1 meal)
            .ios = .{
                .{ .components = .{ .TaskStorage = .{ .accepts = .{ .Meal = true } } } },
            },
            // EOS - where meals go
            .eos = .{
                .{
                    .prefab = "meal_storage",
                    .components = .{ .Position = .{ .x = 30, .y = 0 } }
                },
            },
        },
    },
}
```

### 4. Producer Workstation (No Inputs)

```zig
// prefabs/water_well.zon
.{
    .components = .{
        .Position = .{ .x = 0, .y = 0 },
        .Sprite = .{ .name = "well.png" },
        .TaskWorkstation = .{
            .process_duration = 20,
            .priority = .Low,
            // No EIS/IIS - producer workstation
            .ios = .{
                .{ .components = .{ .TaskStorage = .{ .accepts = .{ .Water = true } } } },
            },
            .eos = .{
                .{
                    .prefab = "water_storage",
                    .components = .{ .Position = .{ .x = 15, .y = 0 } }
                },
            },
        },
    },
}
```

### 5. Scene Definition

```zig
// scenes/bakery.zon
.{
    .name = "bakery",
    .scripts = .{ "task_engine" },
    .camera = .{ .x = 320, .y = 180 },
    .entities = .{
        // Workstations
        .{
            .prefab = "flour_mill",
            .components = .{ .Position = .{ .x = 50, .y = 100 } }
        },
        .{
            .prefab = "oven",
            .components = .{ .Position = .{ .x = 150, .y = 100 } }
        },

        // Workers
        .{
            .prefab = "baker",
            .components = .{ .Position = .{ .x = 100, .y = 150 } }
        },

        // Transports (inline definition)
        .{
            .components = .{
                .TaskTransport = .{
                    .from = .{ .prefab = "flour_mill" },  // Reference by prefab?
                    .to = .{ .prefab = "oven" },
                    .item = .Flour,
                },
            },
        },
    },
}
```

## Implementation Plan

### Phase 1: Update EcsComponents

Modify `labelle-tasks` EcsComponents to use `Entity` and `[]const Entity` fields:

```zig
pub const TaskWorkstation = struct {
    eis: []const Entity = &.{},
    iis: []const Entity = &.{},
    ios: []const Entity = &.{},
    eos: []const Entity = &.{},
    process_duration: u32 = 0,
    priority: Priority = .Normal,
};
```

### Phase 2: Task Engine Observer System

Create a system that observes `TaskWorkstation` components and syncs with the task engine:

```zig
// In a labelle-tasks plugin
pub const TasksPlugin = struct {
    pub const EngineHooks = struct {
        pub fn entity_created(payload: engine.HookPayload) void {
            const info = payload.entity_created;
            const game = @ptrCast(*Game, @alignCast(info.game));

            // Check if entity has TaskWorkstation component
            if (game.getRegistry().tryGet(info.entity, TaskWorkstation)) |ws| {
                // Register with task engine
                task_engine.addWorkstation(info.entity, .{
                    .eis = ws.eis,
                    .iis = ws.iis,
                    .ios = ws.ios,
                    .eos = ws.eos,
                    .process_duration = ws.process_duration,
                    .priority = ws.priority,
                });
            }

            // Check if entity has TaskStorage component
            if (game.getRegistry().tryGet(info.entity, TaskStorage)) |storage| {
                task_engine.addStorage(info.entity, .{
                    .accepts = storage.accepts,
                });
            }
        }
    };
};
```

### Phase 3: Task Engine Refactor

The current `labelle-tasks` Engine uses game IDs (`GameId`) for entities. We need to either:

**Option A: Use Entity directly**
```zig
// Change Engine signature
pub fn Engine(comptime Item: type, comptime Dispatcher: type) type {
    // Use Entity from labelle-engine instead of generic GameId
}
```

**Option B: Entity ID adapter**
```zig
// Keep Engine generic, provide adapter for labelle-engine Entity
pub fn entityToGameId(entity: Entity) u64 {
    return @bitCast(entity);
}
```

### Phase 4: Storage Resolution

When `TaskWorkstation` is loaded, the engine's loader creates child entities for each storage in the entity lists. The task engine observer receives these entities and registers them.

**Flow:**
```
Scene loads workstation prefab
  ↓
Engine creates TaskWorkstation entity
  ↓
Engine creates child entities for eis[], iis[], ios[], eos[]
  ↓
entity_created hook fires for workstation
  ↓
Observer reads TaskWorkstation.eis, .iis, .ios, .eos
  (these now contain actual Entity references)
  ↓
Observer registers with task engine
```

## Storage Binding Strategies

A key design question: how do we bind N storages to a workstation component? There are several approaches:

### Option A: Runtime Slices (Current Proposal)

```zig
pub const TaskWorkstation = struct {
    eis: []const Entity = &.{},
    iis: []const Entity = &.{},
    ios: []const Entity = &.{},
    eos: []const Entity = &.{},
    process_duration: u32 = 0,
    priority: Priority = .Normal,
};
```

**Pros:**
- Flexible - any number of storages
- Single component type for all workstations
- Works with existing ECS queries

**Cons:**
- Slice memory must be managed (who owns it?)
- Runtime indirection
- labelle-engine's loader allocates these from the prefab arena (stable lifetime)

### Option B: Comptime Generic Struct

```zig
pub fn TaskWorkstation(
    comptime eis_count: usize,
    comptime iis_count: usize,
    comptime ios_count: usize,
    comptime eos_count: usize,
) type {
    return struct {
        eis: [eis_count]Entity,
        iis: [iis_count]Entity,
        ios: [ios_count]Entity,
        eos: [eos_count]Entity,
        process_duration: u32 = 0,
        priority: Priority = .Normal,
    };
}

// Usage
const KitchenWorkstation = TaskWorkstation(2, 2, 1, 1);
const WellWorkstation = TaskWorkstation(0, 0, 1, 1);
```

**Pros:**
- Fixed-size arrays - no slice memory management
- Comptime known sizes - better optimization
- No runtime allocation

**Cons:**
- Each workstation type is a **different type**
- Cannot query all workstations with a single ECS query
- labelle-engine component registry expects uniform types
- Prefab loader would need significant changes

### Option C: Fixed Maximum Capacity

```zig
pub const MAX_STORAGES = 8;

pub const TaskWorkstation = struct {
    eis: [MAX_STORAGES]Entity = [_]Entity{Entity.invalid} ** MAX_STORAGES,
    iis: [MAX_STORAGES]Entity = [_]Entity{Entity.invalid} ** MAX_STORAGES,
    ios: [MAX_STORAGES]Entity = [_]Entity{Entity.invalid} ** MAX_STORAGES,
    eos: [MAX_STORAGES]Entity = [_]Entity{Entity.invalid} ** MAX_STORAGES,
    eis_count: u8 = 0,
    iis_count: u8 = 0,
    ios_count: u8 = 0,
    eos_count: u8 = 0,
    process_duration: u32 = 0,
    priority: Priority = .Normal,
};
```

**Pros:**
- Single component type
- No slice memory management
- Fixed size - predictable memory layout

**Cons:**
- Wastes memory if most workstations use few storages
- Hard limit on storage count
- Larger component size (8 * 4 * sizeof(Entity) + 4 bytes + other fields)

### Option D: Separate Storage Binding Component

```zig
// Core workstation - just the processing logic
pub const TaskWorkstation = struct {
    process_duration: u32 = 0,
    priority: Priority = .Normal,
};

// Storage binding - added by loader, references parent workstation
pub const TaskStorageBinding = struct {
    workstation: Entity,
    role: enum { eis, iis, ios, eos },
};

// Query: find all storages for a workstation
fn getStoragesForWorkstation(registry: *Registry, ws: Entity) []Entity {
    // Query all TaskStorageBinding where workstation == ws
}
```

**Pros:**
- Workstation component is tiny and uniform
- No limits on storage count
- Follows ECS relationship patterns
- Each storage knows its role

**Cons:**
- More complex queries
- Storage-to-workstation lookup requires iteration
- Two-way binding needed for efficient access

### Recommendation

**Option A (runtime slices)** is recommended because:

1. **labelle-engine already handles this** - The loader allocates entity slices from a stable arena when processing `[]const Entity` fields
2. **Uniform type** - All workstations are the same component type, enabling simple ECS queries
3. **Proven pattern** - `Room.movement_nodes` in flying platform uses the same approach
4. **No artificial limits** - Unlike Option C, no MAX_STORAGES constant

The slice memory concern is addressed by labelle-engine's prefab/scene loading:

```zig
// In labelle-engine loader (simplified)
fn loadEntitySlice(arena: *Arena, zon_data: anytype) []const Entity {
    var entities = arena.alloc(Entity, zon_data.len);
    for (zon_data, 0..) |item, i| {
        entities[i] = createChildEntity(item);
    }
    return entities;  // Lives as long as the scene/prefab
}
```

The arena allocator ensures slice memory lives for the duration of the scene.

## Open Questions

### 1. Transport References

How do transports reference workstations/storages by name in scenes?

**Option A: Direct entity reference (requires knowing entity at comptime)**
```zig
.TaskTransport = .{
    .from = some_entity,  // How to get this?
    .to = other_entity,
},
```

**Option B: Named entity lookup (runtime)**
```zig
// Scene entities could have optional names
.{ .name = "flour_mill", .prefab = "flour_mill", ... },

// Transport references by name
.TaskTransport = .{
    .from_name = "flour_mill.eos",
    .to_name = "oven.eis",
},
```

**Option C: Transport as relationship (new pattern)**
```zig
// Transport defined at scene level, not as entity
.transports = .{
    .{ .from = 0, .to = 1, .item = .Flour },  // Entity indices
},
```

### 2. Internal Storages (IIS/IOS)

Internal storages typically don't need visuals or positions. Should they:

**Option A: Be invisible entities (Recommended)**
```zig
.iis = .{
    .{ .components = .{ .TaskStorage = .{ .accepts = .{ .Flour = true } } } },
},
```

Based on the `movement_nodes` pattern in flying platform, invisible entities are the natural fit. Movement nodes have no sprites - only Shape for debug visualization. Internal storages follow the same pattern: entities that exist for logic but may optionally have debug visuals.

**Option B: Be data-only (not entities)**
```zig
// New component field type
.recipe_inputs = .{ .Flour, .Flour, .Meat },  // 2 flour + 1 meat
.recipe_outputs = .{ .Bread },
```

**Option C: Hybrid - Recipe shorthand with auto-generated entities**
```zig
.TaskWorkstation = .{
    .recipe = .{ .inputs = .{ .Flour, .Meat }, .outputs = .{ .Meal } },
    // Engine auto-generates IIS/IOS entities from recipe
    .eis = .{ ... },  // Only external storages need explicit definition
    .eos = .{ ... },
},
```

This hybrid approach keeps prefabs readable while still using entities under the hood. The engine would auto-generate IIS/IOS entities based on the recipe definition.

### 3. Task Engine Ownership

Should labelle-tasks own the task engine instance, or should it be managed by labelle-engine?

**Option A: Plugin owns engine**
```zig
const TasksPlugin = struct {
    var task_engine: TaskEngine = undefined;

    pub fn init(allocator: Allocator) void {
        task_engine = TaskEngine.init(allocator);
    }
};
```

**Option B: Component on Game/World**
```zig
// Task engine as a resource in the ECS world
game.addResource(TaskEngine, task_engine);
```

## Migration Path

### From Current API

```zig
// Current labelle-tasks usage
_ = engine.addStorage(10, .{ .item = .Vegetable });
_ = engine.addWorkstation(100, .{
    .eis = &.{10},
    .iis = &.{11},
    // ...
});
```

### To Prefab-based

```zig
// New usage with labelle-engine
const Loader = engine.SceneLoader(Prefabs, Components, Scripts);
var scene = try Loader.load(@import("scenes/kitchen.zon"), ctx);

// Workstations and storages automatically registered via hooks
```

## Benefits

1. **Leverages existing patterns** - Uses labelle-engine's proven entity reference system
2. **Visual consistency** - Storages can have sprites and positions like any entity
3. **Tooling ready** - Level editors understand prefabs and entities
4. **Type safety** - Comptime validation of prefab references
5. **Familiar API** - Same patterns as other labelle-engine features

## References

- [labelle-engine loader.zig](https://github.com/labelle-toolkit/labelle-engine/blob/main/src/loader.zig) - Entity reference handling
- [labelle-engine nested_prefab_test.zig](https://github.com/labelle-toolkit/labelle-engine/blob/main/test/nested_prefab_test.zig) - Entity list patterns
- [labelle-engine zon_coercion.zig](https://github.com/labelle-toolkit/labelle-engine/blob/main/src/zon_coercion.zig) - Entity detection
- [labelle_flying_platform simple_kitchen.zon](https://github.com/labelle-toolkit/labelle_flying_platform) - Real-world example with Room.movement_nodes pattern
