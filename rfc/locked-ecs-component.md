# RFC: ECS-Based State Management with Locked Component

**Status**: Draft
**Issue**: [#88](https://github.com/labelle-toolkit/labelle-tasks/issues/88)
**Date**: 2026-02-27

## Problem

### 1. Fragile imperative coordination

labelle-tasks operates as a pure state machine with no ECS awareness. When other systems (e.g. labelle-needs) need to reserve items or workers, coordination relies on imperative API calls (`workerUnavailable`, `itemRemoved`) that the game-side hooks must call at the right moment and in the right order.

This has caused multiple bugs in the bakery game:

1. **Ordering sensitivity**: `workerUnavailable` must be called before `MovementTarget` is set, because it may trigger `transport_cancelled` which removes `MovementTarget`
2. **Manual cleanup**: game must call `itemRemoved` after consuming a drink, or the task engine assigns transports from empty storages
3. **Race conditions**: task engine reassigns workers synchronously in `worker_released` before other systems (EOS transport) get a chance to claim them

### 2. Save/load requires ECS as source of truth

The game needs save/load support. ECS serialization is the natural approach — dump all entities and their components, then restore them. But currently, critical state lives outside the ECS:

- **`pending_transports`** (HashMap in eos_transport.zig) — which EOS→EIS transports are in flight
- **`worker_transport_from/to`** (HashMaps in eos_transport.zig) — which worker is carrying what where
- **`worker_carried_items`** (HashMap in task_hooks.zig) — which worker holds which item
- **`storage_items`** (HashMap in task_hooks.zig) — which storage contains which item entity
- **`worker_workstation`** (HashMap in task_hooks.zig) — which worker is assigned to which workstation
- **Reservation state** — which items/storages are claimed by the needs system

None of this serializes with the ECS. A save/load cycle would lose all in-flight state, causing workers to freeze, items to duplicate, or tasks to restart from scratch.

By moving coordination state into ECS components, serialization captures everything. `Locked` on a storage entity means "this item is reserved" — that fact survives save/load automatically. Over time, the other HashMaps should migrate to ECS components too, making the ECS world the complete, serializable game state.

## Goal

Replace all HashMap-based state tracking with ECS components. The ECS world becomes the single source of truth for all game state — coordination, assignments, reservations, inventory. This makes save/load a straightforward ECS serialization, eliminates manual synchronization bugs, and lets any system query state by simply reading components.

`Locked` is the first component to migrate, followed by the rest of the HashMap state.

## Current Architecture

```
Game-side HashMaps (task_hooks.zig, eos_transport.zig):
  worker_carried_items:  worker_id → item_entity_id
  storage_items:         storage_id → item_entity_id
  worker_workstation:    worker_id → workstation_id
  pending_transports:    eos_id → eis_id
  worker_transport_from: worker_id → eos_id
  worker_transport_to:   worker_id → eis_id

Task engine internal state (labelle-tasks):
  StorageState:    has_item, item_type, assigned_worker
  WorkerData:      state (Idle/Working/Unavailable), assigned_workstation
  WorkstationData: status, current_step, eis/iis/ios/eos lists

Needs engine state (labelle-needs):
  NeedState per worker per need type

Coordination: imperative calls between them
  labelle-tasks: workerUnavailable(id), itemRemoved(id)
  labelle-needs: seek_item → game removes from storage_items + calls workerUnavailable
```

State is scattered across three layers. The game must manually synchronize between systems. None of the HashMap state serializes with the ECS.

## Target Architecture

```
ECS World (single source of truth):
  Storage entity:  Storage, Position, [Locked], [StoredItem]
  Worker entity:   Worker, Position, [Locked], [CarriedItem], [AssignedWorkstation], [TransportTask]
  Item entity:     Position, Sprite, [ItemType]

All systems query the ECS directly. Save/load = serialize/deserialize ECS world.
```

No HashMaps. No imperative synchronization calls. Every system reads the same ECS state.

## Proposed Design

### Locked component defined by the game

```zig
// bakery-game/components/locked.zig
pub const Locked = struct {
    locked_by: u64,  // entity that holds the lock (worker, system, etc.)
};
```

### Passed to both engines via bind

```zig
// project.labelle
.plugins = .{
    .{
        .name = "labelle-tasks",
        .bind = .{
            .{ .func = "bind", .arg = "Items", .components = "Storage,Worker,Locked" },
        },
    },
    .{
        .name = "labelle-needs",
        .bind = .{
            .{ .func = "bind", .arg = "Needs", .components = "Locked" },
        },
    },
},
```

### labelle-tasks checks Locked via bound type

Since labelle-tasks already receives bound component types (Storage, Worker), it can receive Locked the same way. The engine hooks layer has registry access and can query `Locked` on entities.

#### Where Locked is checked

| Decision point | Current approach | With Locked |
|---------------|-----------------|-------------|
| Assign worker to workstation | Game calls `workerUnavailable` | Engine checks `Locked` on worker entity |
| Assign transport from storage | Game calls `itemRemoved` | Engine checks `Locked` on storage entity |
| Select EIS for delivery | Game removes from `storage_items` | Engine checks `Locked` on storage entity |
| Dangling item pickup | N/A | Engine checks `Locked` on item entity |

#### Who sets Locked

| System | Sets Locked on | When | Removes when |
|--------|---------------|------|-------------|
| labelle-needs (drink) | Storage entity | `seek_item` — worker claims water | `item_consumed` — worker finishes drinking |
| labelle-needs (sleep) | Facility entity | `seek_facility` — worker claims bed | `fulfillment_completed` |
| Game (future) | Worker entity | Custom game logic | Custom game logic |

### Implementation in labelle-tasks

The key change: labelle-tasks needs **registry access** to query `Locked`. It already has this through the ECS bridge (`EcsInterface` / vtable pattern in `src/ecs_bridge.zig`).

#### Option: Query through EcsInterface

The `EcsInterface` vtable already provides type-erased ECS access. Add a `hasComponent` method:

```zig
// In EcsInterface vtable
has_component: *const fn (self: *anyopaque, entity_id: GameId) bool,
```

The game's bridge implementation would check `registry.tryGet(Locked, entity) != null`.

#### Where checks are inserted

In `src/helpers.zig`:
- `tryAssignWorkers`: before assigning a worker, check `!isLocked(worker_id)`
- `selectEis`: before selecting an EIS, check `!isLocked(storage_id)`
- `selectEos`: before selecting an EOS, check `!isLocked(storage_id)`

In `src/dangling.zig`:
- `evaluateDanglingItems`: before assigning dangling delivery destination, check `!isLocked(storage_id)`

## Save/Load

The entire motivation for this migration is save/load. When all state lives in ECS components:

- **Save** = serialize every entity and its components
- **Load** = deserialize entities, engines read components on first query — no replay of imperative calls needed

### What breaks without this

If we save/load with the current HashMap architecture:
- Workers freeze — `worker_workstation` HashMap is gone, task engine doesn't know who's assigned where
- Items duplicate — `storage_items` HashMap is gone, task engine thinks storages are empty and creates new items
- Transports ghost — `pending_transports` HashMap is gone, workers walk to destinations that no longer expect them
- Reservations lost — needs system's claims vanish, two workers grab the same water

### What works with full ECS state

After migration, a loaded game resumes exactly where it was:
- Worker has `AssignedWorkstation { ws_id = 29 }` → task engine knows it's busy
- Storage has `StoredItem { item_entity = 55 }` → task engine knows it's full
- Storage has `Locked { locked_by = worker_0 }` → both engines know it's reserved
- Worker has `TransportTask { from = 34, to = 12 }` → transport resumes
- Worker has `CarriedItem { item_entity = 58 }` → item follows worker

No reconstruction logic. No "replay events since last save". The ECS world is the save file.

## ECS Components — Full List

All components defined by the game, passed to engines via `bind()`:

### Locked (reservation)

```zig
pub const Locked = struct {
    locked_by: u64,  // worker or system that holds the lock
};
```

Replaces: imperative `workerUnavailable`/`itemRemoved` calls, needs system reservation arrays.
Set on: storage entities (item reserved), facility entities (bed reserved), worker entities (worker busy with non-task work).

### StoredItem (storage inventory)

```zig
pub const StoredItem = struct {
    item_entity: u64,  // the item entity stored here
};
```

Replaces: `storage_items` HashMap in task_hooks.zig.
Set on: storage entities when an item is placed. Removed when item is picked up or consumed.

### CarriedItem (worker inventory)

```zig
pub const CarriedItem = struct {
    item_entity: u64,  // the item entity being carried
};
```

Replaces: `worker_carried_items` HashMap in task_hooks.zig.
Set on: worker entities when picking up an item. Removed on delivery or consumption.

### AssignedWorkstation (worker assignment)

```zig
pub const AssignedWorkstation = struct {
    workstation_id: u64,
};
```

Replaces: `worker_workstation` HashMap in task_hooks.zig.
Set on: worker entities when assigned by task engine. Removed on `worker_released`.

### TransportTask (in-flight transport)

```zig
pub const TransportTask = struct {
    from_storage: u64,  // EOS being picked from
    to_storage: u64,    // EIS being delivered to
};
```

Replaces: `pending_transports`, `worker_transport_from`, `worker_transport_to` HashMaps in eos_transport.zig.
Set on: worker entities when transport is assigned. Removed on delivery completion.

## Implementation

This is a breaking change. No backward compatibility with the HashMap-based approach. All components ship together, all HashMaps are removed, imperative API calls are deleted.

### What changes in labelle-tasks

1. `bind()` accepts all new component types: `Locked`, `StoredItem`, `CarriedItem`, `AssignedWorkstation`, `TransportTask`
2. Engine queries ECS for state instead of maintaining internal HashMaps:
   - `StorageState.has_item` → query `StoredItem` on storage entity
   - `WorkerData.state` → derived from presence of `Locked`, `AssignedWorkstation`, `TransportTask`, `CarriedItem`
   - `assigned_worker` → query workers with `AssignedWorkstation` matching this workstation
3. Decision points check `Locked`:
   - `tryAssignWorkers`: skip workers with `Locked`
   - `selectEis` / `selectEos`: skip storages with `Locked`
   - `evaluateDanglingItems`: skip locked storages
4. Imperative API calls removed: `workerUnavailable`, `workerAvailable`, `itemRemoved`
5. Internal HashMaps in engine removed — ECS is the only state store

### What changes in labelle-needs

1. `bind()` accepts `Locked` (already does)
2. Sets `Locked` on storage/facility entities when claiming for drink/sleep (already does)
3. No more imperative calls to labelle-tasks — just set/remove `Locked` and the task engine sees it

### What changes in bakery-game

1. Define all 5 components in `components/`
2. Pass via bind to both plugins
3. Delete all game-side HashMaps: `storage_items`, `worker_carried_items`, `worker_workstation`, `pending_transports`, `worker_transport_from`, `worker_transport_to`
4. Hooks set/remove ECS components instead of updating HashMaps
5. Delete `eos_transport.zig` script — transport logic moves into labelle-tasks (see standalone-storages RFC)

### What is deleted

| Removed | Replaced by |
|---------|------------|
| `workerUnavailable()` / `workerAvailable()` | `Locked` component on worker entity |
| `itemRemoved()` | Remove `StoredItem` component from storage entity |
| `storage_items` HashMap | `StoredItem` component on storage entities |
| `worker_carried_items` HashMap | `CarriedItem` component on worker entities |
| `worker_workstation` HashMap | `AssignedWorkstation` component on worker entities |
| `pending_transports` HashMap | `TransportTask` component on worker entities |
| `worker_transport_from/to` HashMaps | `TransportTask` component on worker entities |
| `StorageState.has_item` internal field | `StoredItem` presence query |
| `WorkerData.state` internal field | Derived from component presence |

## Out of Scope

- ECS serialization format (separate concern — this RFC makes it possible, doesn't define the format)
- Multi-lock support (multiple systems locking same entity)
- Lock priorities or lock queuing
