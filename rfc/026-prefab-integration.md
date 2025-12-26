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

### 1. ECS Components (Parent-Child Model)

The key insight: **workstation doesn't store entity references**. Instead, storages are child entities with a role marker.

```zig
// In labelle-tasks EcsComponents
pub fn EcsComponents(comptime ItemType: type) type {
    return struct {
        pub const ItemSet = std.EnumSet(ItemType);

        /// Workstation that processes items through a recipe
        /// NOTE: No storage references! Storages are child entities.
        pub const TaskWorkstation = struct {
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

        /// Role marker for storage entities (child of workstation)
        pub const TaskStorageRole = struct {
            role: enum { eis, iis, ios, eos },
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

**Why this design?**
- No slices to manage/free when entity is removed
- Storages as children is natural (workstation "owns" its storages)
- Task engine builds internal mapping from role markers
- Clean separation: ECS = declarative, Task engine = runtime state

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

### 3. Workstation Prefabs with Child Storages

```zig
// prefabs/kitchen.zon
.{
    .components = .{
        .Position = .{ .x = 0, .y = 0 },
        .Sprite = .{ .name = "kitchen.png", .z_index = 10 },
        .TaskWorkstation = .{
            .process_duration = 40,
            .priority = .High,
        },
    },
    // Storages are CHILDREN of the workstation entity
    .children = .{
        // EIS - where ingredients come from (visible, with sprites)
        .{
            .prefab = "vegetable_storage",
            .components = .{
                .Position = .{ .x = -30, .y = 0 },
                .TaskStorageRole = .{ .role = .eis },
            },
        },
        .{
            .prefab = "meat_storage",
            .components = .{
                .Position = .{ .x = -30, .y = 20 },
                .TaskStorageRole = .{ .role = .eis },
            },
        },
        // IIS - recipe inputs (invisible, logic only)
        .{
            .components = .{
                .TaskStorage = .{ .accepts = .{ .Vegetable = true } },
                .TaskStorageRole = .{ .role = .iis },
            },
        },
        .{
            .components = .{
                .TaskStorage = .{ .accepts = .{ .Meat = true } },
                .TaskStorageRole = .{ .role = .iis },
            },
        },
        // IOS - recipe output (invisible, logic only)
        .{
            .components = .{
                .TaskStorage = .{ .accepts = .{ .Meal = true } },
                .TaskStorageRole = .{ .role = .ios },
            },
        },
        // EOS - where meals go (visible, with sprite)
        .{
            .prefab = "meal_storage",
            .components = .{
                .Position = .{ .x = 30, .y = 0 },
                .TaskStorageRole = .{ .role = .eos },
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
        },
    },
    // Producer: no EIS/IIS children, only IOS/EOS
    .children = .{
        .{
            .components = .{
                .TaskStorage = .{ .accepts = .{ .Water = true } },
                .TaskStorageRole = .{ .role = .ios },
            },
        },
        .{
            .prefab = "water_storage",
            .components = .{
                .Position = .{ .x = 15, .y = 0 },
                .TaskStorageRole = .{ .role = .eos },
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

Add the new components (no slices!):

```zig
pub const TaskWorkstation = struct {
    process_duration: u32 = 0,
    priority: Priority = .Normal,
};

pub const TaskStorage = struct {
    accepts: ItemSet = ItemSet.initFull(),
};

pub const TaskStorageRole = struct {
    role: enum { eis, iis, ios, eos },
};
```

### Phase 2: Task Engine Storage Mapping

Add internal storage tracking to the task engine:

```zig
// In Engine
const WorkstationStorages = struct {
    eis: std.ArrayList(Entity),
    iis: std.ArrayList(Entity),
    ios: std.ArrayList(Entity),
    eos: std.ArrayList(Entity),

    pub fn deinit(self: *@This(), allocator: Allocator) void {
        self.eis.deinit();
        self.iis.deinit();
        self.ios.deinit();
        self.eos.deinit();
    }
};

workstation_storages: std.AutoHashMap(Entity, WorkstationStorages),

pub fn bindStorage(self: *Self, workstation: Entity, storage: Entity, role: StorageRole) void {
    const entry = self.workstation_storages.getOrPut(workstation) catch return;
    if (!entry.found_existing) {
        entry.value_ptr.* = .{
            .eis = std.ArrayList(Entity).init(self.allocator),
            .iis = std.ArrayList(Entity).init(self.allocator),
            .ios = std.ArrayList(Entity).init(self.allocator),
            .eos = std.ArrayList(Entity).init(self.allocator),
        };
    }
    switch (role) {
        .eis => entry.value_ptr.eis.append(storage) catch {},
        .iis => entry.value_ptr.iis.append(storage) catch {},
        .ios => entry.value_ptr.ios.append(storage) catch {},
        .eos => entry.value_ptr.eos.append(storage) catch {},
    }
}
```

### Phase 3: Observer System

Create hooks that build the mapping from parent-child relationships:

```zig
pub const TasksPlugin = struct {
    pub const EngineHooks = struct {
        pub fn entity_created(payload: engine.HookPayload) void {
            const entity = payload.entity_created.entity;
            const registry = getRegistry();

            // Register workstation
            if (registry.tryGet(entity, TaskWorkstation)) |ws| {
                task_engine.addWorkstation(entity, .{
                    .process_duration = ws.process_duration,
                    .priority = ws.priority,
                });
            }

            // Register storage and bind to parent workstation
            if (registry.tryGet(entity, TaskStorageRole)) |role| {
                if (registry.tryGet(entity, TaskStorage)) |storage| {
                    task_engine.addStorage(entity, .{ .accepts = storage.accepts });

                    // Bind to parent workstation
                    const parent = registry.getParent(entity);
                    if (parent != Entity.invalid) {
                        task_engine.bindStorage(parent, entity, role.role);
                    }
                }
            }
        }

        pub fn entity_destroyed(payload: engine.HookPayload) void {
            const entity = payload.entity_destroyed.entity;
            task_engine.removeEntity(entity);  // Handles both workstation and storage cleanup
        }
    };
};
```

### Phase 4: Task Engine Refactor

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

### Phase 5: Entity Creation Flow

When a workstation prefab is loaded, labelle-engine creates entities in parent-first order:

**Flow:**
```
Scene loads workstation prefab
  ↓
Engine creates workstation entity (parent)
  ↓
entity_created hook fires → task_engine.addWorkstation()
  ↓
Engine creates child storage entities
  ↓
For each child: entity_created hook fires
  ↓
Observer checks for TaskStorageRole component
  ↓
Observer calls registry.getParent() to find workstation
  ↓
Observer calls task_engine.bindStorage(parent, child, role)
```

**Key insight:** Children are created after parent, so the workstation is already registered when storage bindings happen.

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

### Option E: Parent-Child with Role Component (No References in Workstation)

```zig
// Workstation has NO storage references - just processing config
pub const TaskWorkstation = struct {
    process_duration: u32 = 0,
    priority: Priority = .Normal,
};

// Each storage knows its parent workstation and role
pub const TaskStorageRole = struct {
    role: enum { eis, iis, ios, eos },
};

// Storage is a CHILD entity of the workstation (parent-child hierarchy)
// The parent relationship is implicit via labelle-engine's entity hierarchy
```

**Prefab structure:**
```zig
// prefabs/kitchen.zon
.{
    .components = .{
        .TaskWorkstation = .{ .process_duration = 40 },
        .Position = .{ .x = 0, .y = 0 },
    },
    .children = .{
        .{ .components = .{ .TaskStorage = .{ .accepts = .{ .Vegetable = true } }, .TaskStorageRole = .{ .role = .eis } } },
        .{ .components = .{ .TaskStorage = .{ .accepts = .{ .Meat = true } }, .TaskStorageRole = .{ .role = .eis } } },
        .{ .components = .{ .TaskStorage = .{ .accepts = .{ .Vegetable = true } }, .TaskStorageRole = .{ .role = .iis } } },
        .{ .components = .{ .TaskStorage = .{ .accepts = .{ .Meat = true } }, .TaskStorageRole = .{ .role = .iis } } },
        .{ .components = .{ .TaskStorage = .{ .accepts = .{ .Meal = true } }, .TaskStorageRole = .{ .role = .ios } } },
        .{ .components = .{ .TaskStorage = .{ .accepts = .{ .Meal = true } }, .TaskStorageRole = .{ .role = .eos } } },
    },
}
```

**Observer builds mapping:**
```zig
pub fn entity_created(payload: engine.HookPayload) void {
    const entity = payload.entity_created.entity;
    const registry = getRegistry();

    // If storage with role, register with parent workstation
    if (registry.tryGet(entity, TaskStorageRole)) |role| {
        if (registry.tryGet(entity, TaskStorage)) |storage| {
            const parent = registry.getParent(entity);  // labelle-engine parent lookup
            if (parent != Entity.invalid) {
                task_engine.bindStorage(parent, entity, role.role, storage.accepts);
            }
        }
    }
}
```

**Pros:**
- **No slices to free** - no Entity references in components
- Workstation component is tiny and uniform
- Storage removal is automatic (ECS handles component cleanup)
- Parent-child relationship is natural for "workstation owns storages"
- Task engine owns the mapping (can use whatever data structure fits)

**Cons:**
- Requires parent-child support in labelle-engine (already exists)
- Two queries needed: find workstation, then find its children
- Less explicit in the component (mapping lives in task engine)

### Option F: BoundedArray (Fixed Capacity, Clean API)

```zig
const std = @import("std");

pub const TaskWorkstation = struct {
    eis: std.BoundedArray(Entity, 8) = .{},
    iis: std.BoundedArray(Entity, 8) = .{},
    ios: std.BoundedArray(Entity, 8) = .{},
    eos: std.BoundedArray(Entity, 8) = .{},
    process_duration: u32 = 0,
    priority: Priority = .Normal,
};
```

**Pros:**
- No slice memory management
- Clean API (`.append()`, `.slice()`, `.len`)
- Single uniform type
- Fixed memory layout

**Cons:**
- 8 * 4 * sizeof(Entity) overhead per workstation
- Hard limit (8 per category)
- BoundedArray may not serialize well to .zon

### Recommendation

**Option E (Parent-Child with Role Component)** is recommended because:

1. **No memory management** - No slices, no arrays to size, no freeing
2. **Natural hierarchy** - Storages as children of workstation matches the conceptual model
3. **Task engine owns the mapping** - Can optimize data structure for actual access patterns
4. **Clean component design** - TaskWorkstation is just config, TaskStorageRole is just a tag
5. **Automatic cleanup** - When workstation entity is deleted, children are deleted too

The task engine maintains an internal mapping:
```zig
// In task engine (not ECS component)
const WorkstationStorages = struct {
    eis: std.ArrayList(Entity),
    iis: std.ArrayList(Entity),
    ios: std.ArrayList(Entity),
    eos: std.ArrayList(Entity),
};

storages: std.AutoHashMap(Entity, WorkstationStorages),
```

This separates concerns:
- **ECS components** = declarative data (what kind of workstation, what role)
- **Task engine** = runtime state (which entities are bound where)

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
