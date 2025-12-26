# RFC 026: Prefab-based Workstation Setup

**Status**: Draft
**Issue**: [#26](https://github.com/labelle-toolkit/labelle-tasks/issues/26)
**Author**: @alexandrecalvao
**Created**: 2025-12-26

## Summary

Explore a deeper integration between labelle-tasks and labelle-engine that allows defining complete workstations (with all storages) using prefabs alone.

## Motivation

Setting up a workstation currently requires multiple steps across different systems. This is error-prone, verbose, and doesn't leverage the compositional power of ECS prefabs.

### Current State

```zig
// 1. Create each storage entity separately
const eis = world.spawn(.{ TaskStorage{ .accepts = .Vegetable }, Position{...} });
const iis = world.spawn(.{ TaskStorage{ .accepts = .Vegetable }, Position{...} });
const ios = world.spawn(.{ TaskStorage{ .accepts = .Meal }, Position{...} });
const eos = world.spawn(.{ TaskStorage{ .accepts = .Meal }, Position{...} });

// 2. Create workstation entity
const kitchen = world.spawn(.{ TaskWorkstation{...}, Position{...} });

// 3. Register everything with task engine (manual wiring)
_ = engine.addStorage(eis, .{ .item = .Vegetable });
_ = engine.addStorage(iis, .{ .item = .Vegetable });
_ = engine.addStorage(ios, .{ .item = .Meal });
_ = engine.addStorage(eos, .{ .item = .Meal });
_ = engine.addWorkstation(kitchen, .{
    .eis = &.{eis},
    .iis = &.{iis},
    .ios = &.{ios},
    .eos = &.{eos},
    .process_duration = 40,
});
```

**Problems:**
- 5+ entities to create manually
- Manual wiring between entities and engine
- Easy to forget a step or misconfigure
- No single source of truth for "what is a kitchen"

## Proposed Design

### Vision

Define a complete workstation as a single prefab:

```zig
const KitchenPrefab = Prefab.define(.{
    // Main workstation entity
    .root = .{
        TaskWorkstation{ .process_duration = 40, .priority = .High },
        Position{ .x = 100, .y = 50 },
        Sprite{ .id = .kitchen },
    },
    // Child storage entities (automatically wired)
    .children = .{
        .eis = .{
            TaskStorage{ .accepts = ItemSet.initOne(.Vegetable) },
            Position{ .x = -20, .y = 0 },  // Relative to parent
            Sprite{ .id = .ingredient_shelf },
        },
        .iis = .{
            TaskStorage{ .accepts = ItemSet.initOne(.Vegetable) },
            // Internal storage, no visual
        },
        .ios = .{
            TaskStorage{ .accepts = ItemSet.initOne(.Meal) },
        },
        .eos = .{
            TaskStorage{ .accepts = ItemSet.initOne(.Meal) },
            Position{ .x = 20, .y = 0 },
            Sprite{ .id = .serving_counter },
        },
    },
});

// Spawn complete workstation with one call
const kitchen = world.spawnPrefab(KitchenPrefab, .{ .position = .{ .x = 100, .y = 50 } });
// All storages created and wired automatically
```

### Alternative: Recipe-based Definition

```zig
const KitchenPrefab = Prefab.define(.{
    .root = .{
        TaskWorkstation{ .process_duration = 40 },
        // Recipe defined inline
        TaskRecipe{
            .inputs = &.{ .Vegetable, .Meat },
            .outputs = &.{ .Meal },
        },
        Position{},
        Sprite{ .id = .kitchen },
    },
    // Storages auto-generated from recipe
});
```

### Alternative: Component-only (No Prefab Changes)

```zig
// New component that defines workstation structure
const WorkstationBlueprint = struct {
    eis_items: []const Item,
    iis_items: []const Item,  // Recipe inputs
    ios_items: []const Item,  // Recipe outputs
    eos_items: []const Item,
    process_duration: u32,
};

// System observes WorkstationBlueprint and creates storages
const kitchen = world.spawn(.{
    WorkstationBlueprint{
        .iis_items = &.{ .Vegetable, .Meat },
        .ios_items = &.{ .Meal },
        .process_duration = 40,
    },
    Position{},
});
// System auto-creates EIS/IIS/IOS/EOS entities and registers with engine
```

## Design Questions

### 1. Prefab Structure

How should child entities (storages) be defined in prefabs?

| Option | Pros | Cons |
|--------|------|------|
| Named children (`.eis`, `.iis`) | Clear semantics | Requires prefab system changes |
| Role marker components | Works with existing prefabs | More components to manage |
| Separate config component | Simple | Less compositional |

### 2. Automatic Registration

Should spawning a workstation prefab automatically register with the task engine?

| Option | Pros | Cons |
|--------|------|------|
| Observer system | Decoupled, reactive | Delayed registration |
| Spawn hook | Immediate | Couples prefab to engine |
| Explicit call | Clear control | More boilerplate |

**Recommendation**: Observer system that runs at end of frame, registers any new `TaskWorkstation` entities.

### 3. Entity Relationships

How to link storage entities to their workstation?

| Option | Pros | Cons |
|--------|------|------|
| Parent-child hierarchy | Natural for transforms | May not fit all games |
| Relationship component | Flexible | Extra component |
| Workstation stores entity IDs | Simple | Workstation knows children |

### 4. Multi-item Recipes

How to express recipes needing 2+ of same ingredient?

```zig
// Recipe: 2 Flour + 1 Meat = 1 Bread

// Option A: Repeated entries
.iis_items = &.{ .Flour, .Flour, .Meat },

// Option B: Count tuples
.iis_items = &.{ .{ .Flour, 2 }, .{ .Meat, 1 } },

// Option C: Separate IIS per unit (current model)
.iis = .{
    .{ TaskStorage{ .accepts = .Flour } },
    .{ TaskStorage{ .accepts = .Flour } },
    .{ TaskStorage{ .accepts = .Meat } },
},
```

### 5. Runtime Flexibility

Can storages be added/removed from workstations at runtime?

**Use cases:**
- Upgrade system adds output slot
- Damaged workstation loses input
- Modular workstations

**Recommendation**: Support runtime modification via engine API, but prefabs define initial state.

## Implementation Plan

### Phase 1: Component Design
- [ ] Define `WorkstationBlueprint` component
- [ ] Define storage role markers (`EisMarker`, `IisMarker`, etc.)
- [ ] Update `EcsComponents` with new types

### Phase 2: Observer System
- [ ] Create `WorkstationSpawnSystem` that observes new blueprints
- [ ] Auto-create storage entities from blueprint
- [ ] Auto-register with task engine

### Phase 3: Prefab Integration
- [ ] Work with labelle-engine on prefab child support
- [ ] Define workstation prefab schema
- [ ] Create prefab examples

### Phase 4: Documentation
- [ ] Update README with prefab usage
- [ ] Add prefab example to `usage/`
- [ ] Document migration from manual setup

## Benefits

- **Single source of truth**: Workstation definition in one place
- **Less boilerplate**: No manual wiring between entities and engine
- **Type safety**: Prefab structure validated at comptime
- **Easier tooling**: Level editors can work with prefabs directly
- **Consistent patterns**: Same prefab system used for all game objects

## Open Questions

1. Should this live in labelle-tasks or a separate labelle-tasks-engine bridge package?
2. How does this interact with save/load? Do we serialize the blueprint or the expanded entities?
3. Should prefabs support variants (e.g., `KitchenPrefab.withPriority(.High)`)?

## References

- [labelle-tasks EcsComponents](../src/root.zig)
- [labelle-engine prefab system](https://github.com/labelle-toolkit/labelle-engine) (TBD)
- [Bevy Bundles](https://bevyengine.org/learn/book/getting-started/ecs/#bundles) - Similar concept in Rust
