# RFC: Standalone Storages

**Status**: Draft
**Issue**: [#78](https://github.com/labelle-toolkit/labelle-tasks/issues/78)
**Date**: 2026-02-21

## Problem

Every storage in labelle-tasks must belong to a workstation. Storages are registered with `addStorage()` but only participate in the workflow when linked to a workstation via `addWorkstation()` or `attachStorageToWorkstation()`. This forces the game to create dummy workstations for common game patterns where items need a place to rest without being processed.

Real examples from the bakery game:

1. **Shelf / display case** — Bread sits on a shelf for customers to buy. There's no workstation involved; the shelf is just a place to hold items. Today we use EOS attached to a workstation, but the shelf has nothing to do with the oven workflow.

2. **Dangling item delivery** — When a dangling Flour appears in the world, the engine looks for an empty EIS to deliver it to (`findEmptyEisForItem`). But what if we want workers to deliver items to a shelf that isn't part of any workstation? Currently impossible — `findEmptyEisForItem` only searches storages with `role == .eis`.

3. **Supply depot** — A pantry or warehouse that feeds multiple workstations. Today you'd register separate EIS per workstation. But a shared pantry that any workstation can pull from doesn't exist as a concept.

## Goal

Introduce **standalone storages** — storages that are not attached to any workstation but still participate in the task engine's item tracking, dangling item delivery, and optionally feed workstations as supply sources.

## Current Architecture

```
Storage ──(role: eis/iis/ios/eos)──> Workstation
                                      │
                                      ├── eis[] (input sources)
                                      ├── iis[] (input buffers)
                                      ├── ios[] (output buffers)
                                      └── eos[] (output destinations)

Dangling items ──findEmptyEisForItem──> only EIS storages
```

All storages have a `StorageRole` (eis/iis/ios/eos). The reverse index `storage_to_workstations` maps each storage to its parent workstation(s). A storage with no entry in the reverse index is effectively inert — it holds state but nothing in the engine reads or writes it beyond `item_added`/`item_removed` events.

## Proposed Design

### New storage role: `.standalone`

Add a new variant to `StorageRole`:

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

No workstation attachment needed. The storage appears in `engine.storages` and responds to `item_added`/`item_removed` events like any other storage.

### Behavior 1: Passive shelf

A standalone storage holds one item. The game manages all transfers via `handle(.item_added)` and `handle(.item_removed)`. The engine tracks `has_item` and `item_type` as usual.

This is the base behavior — it works today with a minor change (allowing `addStorage` without linking to a workstation and using the `.standalone` role).

### Behavior 2: Dangling item sink

When a dangling item appears, the engine currently calls `findEmptyEisForItem()` which only looks at `.eis` storages. Standalone storages should also be valid delivery targets for dangling items.

Change `findEmptyEisForItem` (and `findEmptyEisForItemExcluding`) to also consider `.standalone` storages that accept the item type — but only as a fallback when no EIS is available.

**Delivery priority rule**: Workstation storages (EIS) always take precedence over standalone storages. The engine first looks for an empty EIS that accepts the item. Only when no EIS is available does it fall back to standalone storages.

```zig
// Two-pass search:
// Pass 1: EIS only (current behavior)
if (storage.role == .eis and !storage.has_item) { ... }

// Pass 2: standalone fallback (only if pass 1 found nothing)
if (storage.role == .standalone and !storage.has_item) { ... }
```

This means a standalone shelf accepting `.Bread` could receive a dangling Bread item via worker delivery, but only when no workstation EIS wants that Bread. The existing `pickup_dangling_started` / `store_started` / `item_delivered` hook flow is reused.

**Within the same tier** (EIS-to-EIS or standalone-to-standalone), the `priority` field breaks ties as usual — highest priority wins.

### Behavior 3: Supply source

Workstations can reference standalone storages as external input sources. A standalone storage acts like a shared pantry — multiple workstations can list the same standalone storage in their `.eis` list.

This already works mechanically: `addWorkstation` accepts any storage ID in its `.eis` list regardless of role. The reverse index maps the standalone storage to all workstations that reference it. When the standalone storage receives an item (`item_added`), `reevaluateAffectedWorkstations` fires and those workstations may transition to Queued.

The only gap: `selectEis` currently picks the highest-priority EIS with an item. It already works on arbitrary storage IDs (it reads from `ws.eis.items`), so a standalone storage listed in a workstation's EIS list will be selected if it has the highest priority and contains an item. No change needed.

**Cycle**: Worker picks up from standalone storage (clearing it) → item flows through IIS → processing → IOS → EOS. The standalone storage is now empty and can receive new items (from dangling delivery, game events, or another worker).

### Delivery priority rule (summary)

The same principle applies everywhere items are routed:

| Scenario | Priority order |
|----------|---------------|
| Dangling item needs a destination | EIS first, then standalone |
| EOS item needs onward transport | EIS first, then standalone |

Workstation storages always win. Standalone storages are the fallback — they absorb overflow when all workstation inputs are full.

### Hook changes

**New hook**: `standalone_item_added`

```zig
standalone_item_added: struct {
    storage_id: GameId,
    item: Item,
},
```

Emitted when an item is placed in a standalone storage via `item_added` (after updating state). This lets the game react specifically to standalone storage fills — e.g., showing a visual indicator on the shelf.

**New hook**: `standalone_item_removed`

```zig
standalone_item_removed: struct {
    storage_id: GameId,
},
```

Emitted when an item is removed from a standalone storage. Lets the game clear visuals or trigger restock logic.

These hooks only fire for `.standalone` role storages. Existing EIS/IIS/IOS/EOS storages are unaffected.

### Query API additions

```zig
/// Get all standalone storages that accept a given item type
pub fn getStandaloneStoragesForItem(self: *const Self, item_type: Item) []GameId

/// Get all standalone storages (allocated, caller frees)
pub fn getStandaloneStorages(self: *const Self) []GameId

/// Check if a storage is standalone
pub fn isStandalone(self: *const Self, storage_id: GameId) bool
```

## .zon format

In scenario files:

```zig
.storages = .{
    .{ .id = 10, .role = .standalone, .accepts = .Bread, .priority = .Normal },
    .{ .id = 11, .role = .standalone },  // accepts anything
},
```

In workstation configs, standalone storages can be referenced as EIS:

```zig
.workstations = .{
    .{ .id = 100, .eis = .{ 10 }, .iis = .{ 20 }, .ios = .{ 30 }, .eos = .{ 40 } },
    .{ .id = 101, .eis = .{ 10 }, .iis = .{ 21 }, .ios = .{ 31 }, .eos = .{ 41 } },
    // Both workstations share standalone storage 10 as input source
},
```

## labelle-engine integration

In the bakery game, a standalone storage is represented by a prefab with a `Storage` component:

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

The `Storage` component's `onAdd` callback already calls `engine.addStorage()`. The new `.standalone` role flows through the same path.

## State ownership (unchanged principle)

| State | Owner |
|-------|-------|
| `has_item`, `item_type`, `role`, `accepts`, `priority` | Task Engine |
| Entity references, positions, sprites | Game |
| When to add/remove items from standalone storage | Game (via `handle()`) |
| Dangling delivery to standalone | Task Engine (automatic) |

## Files to modify

| File | Change |
|------|--------|
| `src/state.zig` | Add `.standalone` to `StorageRole` enum |
| `src/dangling.zig` | Include `.standalone` in `findEmptyEisForItem` and `findEmptyEisForItemExcluding` |
| `src/handlers.zig` | Emit `standalone_item_added` / `standalone_item_removed` hooks in `handleItemAdded` / `handleItemRemoved` |
| `src/hooks.zig` | Add `standalone_item_added` and `standalone_item_removed` to `TaskHookPayload` and `HookDispatcher` and `RecordingHooks` |
| `src/engine.zig` | Add query methods (`getStandaloneStorages`, `isStandalone`, etc.) |
| `test/` | Add standalone storage specs |

## Out of scope

- **Multi-item standalone storage** (capacity > 1) — keep the one-item-per-storage invariant for now. Use multiple standalone storages for higher capacity.
- **Automatic restocking** (engine pulls from external source into standalone) — the game controls when items enter standalone storages.
- **Standalone-to-standalone transfers** — workers only transport between storages when the engine assigns the task (dangling delivery or workstation workflow). Direct standalone-to-standalone is game logic.
