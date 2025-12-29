# RFC 029: Engine Actions API

**Status**: Draft
**Issue**: TBD
**Author**: @alexandrecalvao
**Created**: 2025-12-28
**Related**: [RFC 027: Engine-to-Tasks Communication](./027-engine-to-tasks-communication.md)

## Problem

Task engine needs to request actions from the game/engine, not just notify.

### Current Architecture

```
Hooks (notifications - one way):
  TaskHooks: tasks → game  "this happened"
  GameHooks: game → tasks  "this happened"

Callback (request - exists):
  findBestWorker: tasks → game  "which worker should I use?"
```

### Missing Piece

```
Actions (requests - needed):
  tasks → game  "please create item X at storage Y"
  tasks → game  "please remove item from storage Z"
```

## Why This Matters

**Items are prefabs, not just enum values.**

When IIS → IOS transformation happens:
1. Remove item entity from IIS (destroy prefab instance)
2. Create item entity at IOS (instantiate new prefab)

Task engine can't do this directly - it doesn't know about:
- Entity creation
- Prefab instantiation
- ECS components

Only the game/engine knows how to create entities from prefabs.

## Current Workaround (Not Ideal)

Could use hooks and expect game to react:

```zig
// Task engine emits
self.dispatchHook(.{ .transform_requested = .{
    .workstation_id = ws_id,
    .input_items = &.{ .Flour, .Water },
    .output_items = &.{ .Bread },
}});

// Game receives and acts
pub fn transform_requested(payload: TaskHookPayload) void {
    // Remove inputs from IIS
    for (payload.input_storages) |storage| {
        game.removeItemFrom(storage);
    }
    // Create outputs at IOS
    for (payload.output_items) |item| {
        game.createItemAt(payload.ios, item);
    }
    // Notify task engine it's done
    engine.handle(.{ .transformation_done = ... });
}
```

**Problems:**
- Async pattern for something that should be sync
- Extra hook round-trip
- Game must remember to call back
- Error handling is complex

## Proposed Solution: Actions API

Task engine receives an **Actions** interface at creation time:

```zig
pub fn Engine(
    comptime GameId: type,
    comptime Item: type,
    comptime TaskHooks: type,
    comptime Actions: type,  // NEW
) type {
    return struct {
        actions: Actions,

        pub fn init(allocator: Allocator, actions: Actions) Self {
            return .{
                .allocator = allocator,
                .actions = actions,
                // ...
            };
        }

        fn doTransformation(self: *Self, workstation_id: GameId) void {
            // Use actions interface to manipulate items
            for (self.getIisStorages(workstation_id)) |iis| {
                self.actions.removeItem(iis);
            }
            for (self.getIosStorages(workstation_id)) |ios, item| {
                self.actions.createItem(ios, item);
            }
        }
    };
}
```

### Actions Interface

```zig
// Game provides this
const GameActions = struct {
    registry: *Registry,

    /// Create item prefab at storage location
    pub fn createItem(self: @This(), storage_id: Entity, item: Item) void {
        const storage = self.registry.get(storage_id, TaskStorage);
        const position = self.registry.get(storage_id, Position);

        // Instantiate item prefab at storage position
        const item_entity = prefab_loader.instantiate(item.prefabName(), position);

        // Link to storage
        self.registry.getPtr(storage_id, TaskStorage).?.item_entity = item_entity;
    }

    /// Remove item from storage (destroy entity)
    pub fn removeItem(self: @This(), storage_id: Entity) void {
        const storage = self.registry.getPtr(storage_id, TaskStorage);
        if (storage.item_entity) |entity| {
            self.registry.destroy(entity);
            storage.item_entity = null;
        }
    }

    /// Move item between storages
    pub fn moveItem(self: @This(), from: Entity, to: Entity) void {
        const from_storage = self.registry.getPtr(from, TaskStorage);
        const to_storage = self.registry.getPtr(to, TaskStorage);

        to_storage.item_entity = from_storage.item_entity;
        from_storage.item_entity = null;

        // Update position
        if (to_storage.item_entity) |entity| {
            const pos = self.registry.get(to, Position);
            self.registry.getPtr(entity, Position).* = pos;
        }
    }
};
```

### Usage

```zig
// Game creates actions
const actions = GameActions{ .registry = &registry };

// Create engine with actions
var engine = tasks.Engine(Entity, Item, MyTaskHooks, GameActions).init(allocator, actions);

// Task engine uses actions internally for transformation
// No extra hooks needed
```

## Actions vs Hooks vs Callbacks

| Mechanism | Direction | Purpose | Return |
|-----------|-----------|---------|--------|
| **TaskHooks** | tasks → game | Notify game of events | void |
| **GameHooks** | game → tasks | Notify tasks of events | bool |
| **Callbacks** | tasks → game | Query/request info | value |
| **Actions** | tasks → game | Mutate game state | void/bool |

### Existing Callback

```zig
// Already exists
engine.setFindBestWorker(fn(workstation_id: ?GameId, available: []const GameId) ?GameId);
```

This is a **query** - task engine asks, game answers.

### New Actions

```zig
// New - mutations
Actions.createItem(storage_id, item);
Actions.removeItem(storage_id);
Actions.moveItem(from, to);
```

These are **commands** - task engine tells game to do something.

## Boundary: Abstract vs Concrete State

The key insight is separating **abstract item presence** (task engine) from **concrete entities** (game).

### Task Engine Tracks Abstract State

```zig
// Task engine internal storage state
const StorageState = struct {
    has_item: bool,
    item_type: ?Item,
    // NO entity reference - task engine doesn't know about entities
};
```

Task engine makes all routing/blocking decisions based on this abstract state:
- Can this storage accept an item? (`!has_item`)
- Is this storage ready for pickup? (`has_item`)
- What item type is here? (`item_type`)

### Game Tracks Concrete Entities

```zig
// Game's TaskStorage component
const TaskStorage = struct {
    item_entity: ?Entity,  // Actual entity reference
    // Position, sprite, etc. managed by game
};
```

### Synchronization via Hooks

Game keeps task engine's abstract state in sync:

```zig
// When game adds item entity to storage
fn onItemAddedToStorage(storage_id: Entity, item: Item) void {
    // Create entity
    const entity = prefab_loader.instantiate(item.prefabName());
    storage.item_entity = entity;

    // Sync task engine's abstract state
    _ = engine.handle(.{ .item_added = .{
        .storage_id = storage_id,
        .item = item,
    }});
}

// When game removes item entity from storage
fn onItemRemovedFromStorage(storage_id: Entity) void {
    // Destroy entity
    registry.destroy(storage.item_entity.?);
    storage.item_entity = null;

    // Sync task engine's abstract state
    _ = engine.handle(.{ .item_removed = .{
        .storage_id = storage_id,
    }});
}
```

### Why This Separation?

1. **Task engine remains valuable** - Makes all workflow decisions
2. **No entity coupling** - Task engine works without ECS knowledge
3. **Game flexibility** - Game controls entity lifecycle completely
4. **Clear responsibilities** - Task engine: workflow, Game: entities

## Required Actions

### Single Transformation Action

Rather than low-level item operations, use a single high-level action:

```zig
pub const Actions = struct {
    /// Perform IIS → IOS transformation
    /// Game handles: destroy input entities, create output entities
    /// Task engine handles: update abstract state, advance workflow
    performTransformation: fn (workstation_id: GameId) bool,
};
```

### Why One Action?

The previous design with `createItem`, `removeItem`, `moveItem` was too granular:
- Tightly coupled task engine to item operations
- Game still needed to know which items to create/remove
- Task engine already tracks what's in IIS/IOS

With single `performTransformation`:
1. Task engine calls `actions.performTransformation(workstation_id)`
2. Game looks up workstation's IIS and IOS
3. Game destroys input entities, creates output entities
4. Task engine updates its abstract state (clear IIS, populate IOS)
5. Workflow advances to Store step

```zig
// Game implementation
const GameActions = struct {
    registry: *Registry,

    pub fn performTransformation(self: @This(), workstation_id: Entity) bool {
        const ws = self.registry.get(workstation_id, KitchenWorkstation);

        // Destroy input entities
        for (ws.iis) |iis_id| {
            const storage = self.registry.getPtr(iis_id, TaskStorage);
            if (storage.item_entity) |entity| {
                self.registry.destroy(entity);
                storage.item_entity = null;
            }
        }

        // Create output entities (game knows the recipe outputs)
        for (ws.ios) |ios_id| {
            const output_item = getRecipeOutput(workstation_id);
            const pos = self.registry.get(ios_id, Position);
            const entity = prefab_loader.instantiate(output_item.prefabName(), pos);
            self.registry.getPtr(ios_id, TaskStorage).item_entity = entity;
        }

        return true;
    }
};
```

### Task Engine After Transformation

```zig
fn handleTransformationComplete(self: *Self, workstation_id: GameId) void {
    // Update abstract state
    for (self.getIisStorages(workstation_id)) |iis| {
        self.storages.getPtr(iis).has_item = false;
        self.storages.getPtr(iis).item_type = null;
    }
    for (self.getIosStorages(workstation_id)) |ios| {
        self.storages.getPtr(ios).has_item = true;
        self.storages.getPtr(ios).item_type = self.getOutputItem(workstation_id);
    }

    // Advance workflow
    self.advanceToStore(workstation_id);
}
```

## Comptime Interface Pattern

Following Zig conventions, use comptime duck typing:

```zig
pub fn Engine(
    comptime GameId: type,
    comptime Item: type,
    comptime TaskHooks: type,
    comptime Actions: type,
) type {
    // Validate Actions has required methods at comptime
    comptime {
        if (!@hasDecl(Actions, "performTransformation")) {
            @compileError("Actions must have performTransformation method");
        }
    }

    return struct {
        actions: Actions,
        // ...
    };
}
```

## Alternative: Combine with Callbacks

Could extend the existing callback pattern:

```zig
engine.setFindBestWorker(...);        // existing
engine.setPerformTransformation(...); // new
```

**Pros:**
- Consistent with existing pattern
- No new concepts

**Cons:**
- Actions and queries are conceptually different
- Callbacks suggest "ask" semantics, Actions are "do" semantics

## Recommendation

**Use Actions interface** (comptime generic parameter):

1. **Clear semantics** - Actions mutate, Callbacks query
2. **Validated** - Comptime checks for required methods
3. **Extensible** - Game can add extra action methods if needed
4. **Minimal** - Single `performTransformation` action keeps it simple

## Summary

### Communication Mechanisms

```
┌─────────────────────────────────────────────────────────────┐
│                     Communication                            │
├──────────────┬──────────────┬───────────────┬───────────────┤
│  TaskHooks   │  GameHooks   │  Callbacks    │  Actions      │
│  tasks→game  │  game→tasks  │  tasks→game   │  tasks→game   │
│  notify      │  notify      │  query        │  mutate       │
│  void        │  bool        │  value        │  bool         │
└──────────────┴──────────────┴───────────────┴───────────────┘
```

### State Ownership

```
┌────────────────────────────────────────────────────────────────┐
│                    Task Engine                                  │
│  - Abstract item presence (has_item, item_type)                │
│  - Workflow state (current_step, assigned_worker)              │
│  - Routing decisions                                           │
│  - Blocking decisions                                          │
├────────────────────────────────────────────────────────────────┤
│                       Game                                      │
│  - Concrete entities (item_entity: ?Entity)                    │
│  - Prefab instantiation                                        │
│  - Position, sprites, physics                                  │
│  - Work timing (required_work, accumulated_work)               │
│  - Entity lifecycle                                            │
└────────────────────────────────────────────────────────────────┘
```

### Synchronization Flow

```
Game creates item entity
         │
         ▼
Game calls engine.handle(.{ .item_added = ... })
         │
         ▼
Task engine updates abstract state (has_item = true)
         │
         ▼
Task engine makes workflow decisions
         │
         ▼
Task engine calls actions.performTransformation(ws)
         │
         ▼
Game destroys input entities, creates output entities
```

## References

- [RFC 027: Engine-to-Tasks Communication](./027-engine-to-tasks-communication.md)
- [RFC 028: Work Completion Model](./028-work-accumulation.md)
