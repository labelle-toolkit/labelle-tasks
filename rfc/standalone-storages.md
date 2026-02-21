# RFC: Standalone Storages & Engine-Driven Transport

**Status**: Draft
**Issue**: [#78](https://github.com/labelle-toolkit/labelle-tasks/issues/78)
**Date**: 2026-02-21

## Problem

Two problems that are closely related:

### 1. Storages must belong to a workstation

Every storage in labelle-tasks must be linked to a workstation. This forces the game to create dummy workstations for common patterns where items just need a place to rest.

Examples from the bakery game:

- **Shelf / display case** — Bread sits on a shelf for customers. No workstation involved.
- **Dangling item delivery** — `findEmptyEisForItem` only searches EIS storages. A standalone shelf can't receive dangling items.
- **Supply depot** — A shared pantry feeding multiple workstations doesn't exist as a concept.

### 2. EOS transport is game-side logic

When an item lands on an EOS, the engine doesn't know what to do with it. The bakery game's `eos_transport.zig` script polls every frame for idle workers and EOS items, then manually pairs them with matching EIS storages. This means:

- The engine decides **everything** about the workstation workflow (Pickup → Process → Store) but then drops the item on the EOS and walks away.
- The game must reimplement worker assignment, distance-based selection, and storage matching — logic the engine already has.
- The engine can't enforce routing priorities (e.g., EIS over standalone) because it doesn't drive the transport.

## Goal

1. Introduce **standalone storages** — storages not attached to any workstation.
2. Move **EOS transport into the engine** — the engine decides where items go after landing on an EOS, assigns workers, and tells the game where to send them.

## Current Architecture

```
Workstation workflow (engine-driven):
  EIS ──Pickup──> IIS ──Process──> IOS ──Store──> EOS
                                                    │
                                                    ▼
                                              Game takes over
                                              (eos_transport.zig)
                                                    │
                                                    ▼
                                                   EIS

Dangling items (engine-driven):
  World item ──pickup_dangling_started──> EIS
```

## Proposed Design

### New storage role: `.standalone`

```zig
pub const StorageRole = enum {
    eis,
    iis,
    ios,
    eos,
    standalone,  // not part of any workstation
};
```

### Registration

```zig
try engine.addStorage(shelf_id, .{
    .role = .standalone,
    .accepts = .Bread,       // null = accepts any item
    .priority = .Normal,
});
```

No workstation attachment needed.

---

### Behavior 1: Passive shelf

A standalone storage holds one item. The game manages transfers via `handle(.item_added)` / `handle(.item_removed)`. The engine tracks `has_item` and `item_type` as usual.

This is the base behavior — works today with the new `.standalone` role.

### Behavior 2: Dangling item sink

`findEmptyEisForItem` (and `findEmptyEisForItemExcluding`) expanded to consider `.standalone` storages — but only as a fallback when no EIS is available.

```zig
// Two-pass search:
// Pass 1: EIS only (current behavior)
if (storage.role == .eis and !storage.has_item) { ... }

// Pass 2: standalone fallback (only if pass 1 found nothing)
if (storage.role == .standalone and !storage.has_item) { ... }
```

Reuses the existing `pickup_dangling_started` / `store_started` / `item_delivered` hook flow. The destination is reserved (see Storage Reservations) to prevent double-assignment.

### Behavior 3: Supply source

Workstations can reference standalone storages in their `.eis` list. Already works mechanically — `addWorkstation` accepts any storage ID, the reverse index maps it, and `reevaluateAffectedWorkstations` fires when the standalone storage gets an item.

### Behavior 4: Engine-driven EOS transport

**This is the new major behavior.** When an item lands on an EOS, the engine takes responsibility for routing it to a destination and assigning a worker.

#### Flow

```
Store completed → EOS has item
                    │
                    ▼
            Engine finds destination:
              1. Empty EIS that accepts item type (highest priority)
              2. Empty standalone that accepts item type (fallback)
              3. No destination → item stays on EOS (no transport)
                    │
                    ▼
            Engine finds idle worker (nearest to EOS)
                    │
                    ▼
            Dispatch: transport_started
            (worker_id, from=EOS, to=destination, item)
                    │
                    ▼
            Game moves worker to EOS
            Game calls: handle(.transport_pickup_completed)
                    │
                    ▼
            Engine updates: EOS cleared
            Game moves worker to destination (already known from transport_started)
            Game calls: handle(.transport_delivery_completed)
                    │
                    ▼
            Engine updates: destination has item, worker idle
            Dispatch: transport_completed
            Re-evaluate workstations (destination may now enable a workstation)
            Re-evaluate EOS (more items may need transport)
```

#### Worker state

New field on `WorkerData`, similar to `dangling_task`:

```zig
transport_task: ?struct {
    from_storage_id: GameId,   // EOS being picked from
    to_storage_id: GameId,     // destination (EIS or standalone)
    item_type: Item,
} = null,
```

A worker with a `transport_task` is in `.Working` state and won't be assigned to workstations or dangling pickups.

#### Storage reservations

When the engine assigns a transport (or dangling delivery) to a destination storage, that storage is **reserved** — no other worker will target it. This prevents two workers from delivering to the same slot.

New engine state:

```zig
/// Storages reserved as delivery destinations.
/// Key: storage_id, Value: worker_id that holds the reservation.
reserved_storages: std.AutoHashMap(GameId, GameId),
```

**Reserve** when:
- Transport assigned: destination storage reserved for the transport worker
- Dangling delivery assigned: target EIS/standalone reserved for the dangling worker (replaces the ephemeral `reserved_eis` set in `evaluateDanglingItems`)

**Release** when:
- `transport_delivery_completed` — delivery succeeded, storage now has item
- `transport_pickup_completed` with re-route — if original destination is full, old reservation released, new one created
- Worker released/removed — reservation cleared (worker died, became unavailable, etc.)
- `transport_cancelled` — explicit cancellation (see below)

**Effect on routing**: `findDestinationForItem` skips reserved storages, same as it skips full ones. A reserved storage is "spoken for" even though `has_item` is still false.

#### Transport cancellation

A transport can fail if:
- The worker becomes unavailable (`worker_unavailable` / `worker_removed`)
- The source EOS is emptied by the game before pickup (`item_removed` on the EOS)

On cancellation:
1. Reservation on destination released
2. Worker's `transport_task` cleared
3. If worker is still alive, set to Idle and re-evaluate
4. If EOS still has item, re-evaluate for new transport assignment

New hook (engine → game):

```zig
transport_cancelled: struct {
    worker_id: GameId,
    from_storage_id: GameId,
    to_storage_id: GameId,
    item: Item,
},
```

Game uses this to stop the worker's movement and clean up any visual state (carried item sprite, etc.).

#### Delivery to full destination (re-route)

If a destination is full when `transport_delivery_completed` arrives (race condition — e.g., game manually placed an item via `item_added`):

1. Release reservation on full destination
2. Call `findDestinationForItem` for a new destination
3. If found: update `transport_task`, reserve new destination, dispatch `transport_started` with new destination
4. If not found: release worker to idle, item is "dangling" in the worker's hands — dispatch `transport_cancelled` so game can handle it (drop item, return to EOS, etc.)

#### New game → engine events

```zig
// Game notifies engine when worker arrives at EOS and picks up item
transport_pickup_completed: struct {
    worker_id: GameId,
},

// Game notifies engine when worker arrives at destination and drops off item
transport_delivery_completed: struct {
    worker_id: GameId,
},
```

#### New engine → game hooks

The existing `transport_started` and `transport_completed` hooks are already defined but never dispatched. Now they will be:

```zig
// Already exists — now dispatched by engine
transport_started: struct {
    worker_id: GameId,
    from_storage_id: GameId,
    to_storage_id: GameId,
    item: Item,
},

// Already exists — now dispatched by engine
transport_completed: struct {
    worker_id: GameId,
    to_storage_id: GameId,
    item: Item,
},
```

No mid-point hook needed — `transport_started` gives the game both source and destination upfront. After `transport_pickup_completed`, the game already knows where to send the worker.

#### Trigger: when does transport evaluation happen?

The engine evaluates EOS transport when:

1. **`store_completed`** — workstation cycle ends, item just landed on EOS
2. **`item_added` on an EOS** — game manually places item on EOS
3. **`worker_available`** — idle worker appears, check if any EOS items need transport
4. **`transport_delivery_completed`** — worker just finished a transport, check for more

#### Destination selection: `findDestinationForItem`

New internal function, shared by dangling delivery and EOS transport:

```zig
fn findDestinationForItem(engine: *EngineType, item_type: Item, excluded: ...) ?GameId {
    // Pass 1: empty EIS that accepts item_type (highest priority wins)
    // Pass 2: empty standalone that accepts item_type (highest priority wins)
    // Returns null if nothing found
}
```

This replaces `findEmptyEisForItem` and becomes the single routing function for all item delivery.

#### What happens when no destination is found?

The item stays on the EOS. The engine re-evaluates when:
- A new storage is registered (`addStorage`)
- A storage becomes empty (`item_removed`)
- A worker becomes available (`worker_available`)

No polling needed — the engine is event-driven.

---

### Delivery priority rule

The same rule applies everywhere the engine routes items:

| Scenario | Priority order |
|----------|---------------|
| Dangling item needs a destination | EIS first, then standalone |
| EOS item needs onward transport | EIS first, then standalone |
| Worker available, items waiting | EIS first, then standalone |

**Within the same tier** (EIS-to-EIS or standalone-to-standalone), the `priority` field breaks ties — highest priority wins. If tied, nearest to worker wins (via `findNearest`).

---

### Hook changes (standalone-specific)

**New hook**: `standalone_item_added`

```zig
standalone_item_added: struct {
    storage_id: GameId,
    item: Item,
},
```

**New hook**: `standalone_item_removed`

```zig
standalone_item_removed: struct {
    storage_id: GameId,
},
```

Only fire for `.standalone` role storages.

### Query API additions

```zig
pub fn getStandaloneStoragesForItem(self: *const Self, item_type: Item) []GameId
pub fn getStandaloneStorages(self: *const Self) []GameId
pub fn isStandalone(self: *const Self, storage_id: GameId) bool
```

## .zon format

```zig
.storages = .{
    .{ .id = 10, .role = .standalone, .accepts = .Bread, .priority = .Normal },
    .{ .id = 11, .role = .standalone },  // accepts anything
},
```

Standalone storages can also be referenced in workstation `.eis` lists:

```zig
.workstations = .{
    .{ .id = 100, .eis = .{ 10 }, .iis = .{ 20 }, .ios = .{ 30 }, .eos = .{ 40 } },
    .{ .id = 101, .eis = .{ 10 }, .iis = .{ 21 }, .ios = .{ 31 }, .eos = .{ 41 } },
    // Both share standalone storage 10 as input source
},
```

## labelle-engine integration

Standalone storage prefab:

```zig
// prefabs/shelf.zon
.{
    .components = .{
        .Position = .{ .x = 600, .y = 450 },
        .Sprite = .{ .name = "shelf.png" },
        .Storage = .{ .role = .standalone, .accepts = .Bread },
    },
}
```

The `Storage` component's `onAdd` callback already calls `engine.addStorage()`. The `.standalone` role flows through the same path.

**Bakery game migration**: The `eos_transport.zig` script can be deleted. The engine handles EOS→EIS/standalone routing natively. The game just needs to handle the transport hooks (move worker to source, then to destination).

## State ownership

| State | Owner |
|-------|-------|
| `has_item`, `item_type`, `role`, `accepts`, `priority` | Task Engine |
| Transport routing (which EOS → which destination) | Task Engine |
| Worker assignment for transport | Task Engine |
| Storage reservations (which storage is spoken for) | Task Engine |
| Entity references, positions, sprites | Game |
| Moving worker to source/destination | Game (via transport hooks) |
| When to manually add/remove items from standalone | Game (via `handle()`) |

## Files to modify

| File | Change |
|------|--------|
| `src/state.zig` | Add `.standalone` to `StorageRole`, add `transport_task` to `WorkerData` |
| `src/engine.zig` | Add `reserved_storages` map, `findDestinationForItem`, transport evaluation trigger points, reservation helpers, query methods |
| `src/dangling.zig` | Use `findDestinationForItem` instead of `findEmptyEisForItem`, use persistent reservations instead of ephemeral `reserved_eis` set |
| `src/handlers.zig` | Add `handleTransportPickupCompleted` / `handleTransportDeliveryCompleted`, transport cancellation on `worker_unavailable`/`worker_removed`/`item_removed`, emit standalone hooks, trigger transport eval in `handleStoreCompleted` / `handleItemAdded` / `handleWorkerAvailable` |
| `src/hooks.zig` | Add `standalone_item_added`, `standalone_item_removed`, `transport_pickup_completed`, `transport_delivery_completed`, `transport_cancelled` to payloads + dispatcher + recording hooks |
| `test/` | Add standalone storage specs, EOS transport specs |

## Out of scope

- **Multi-item standalone storage** (capacity > 1) — keep the one-item-per-storage invariant. Use multiple standalone storages for higher capacity.
- **Standalone-to-standalone transfers** — engine only routes from EOS or dangling items. Direct standalone-to-standalone is game logic.
- **Chained transport** (EOS → standalone → EIS) — items delivered to standalone stay there until the game or a workstation EIS reference pulls them. No automatic forwarding.
