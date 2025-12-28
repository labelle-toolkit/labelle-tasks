# RFC 027: Engine-to-Tasks Communication

**Status**: Draft
**Issue**: TBD
**Author**: @alexandrecalvao
**Created**: 2025-12-28

## Summary

Define how labelle-engine communicates state changes to labelle-tasks (e.g., storage item changes, worker availability).

## Context

**Current communication flow:**
- **Tasks → Engine**: labelle-tasks emits hooks (`cycle_completed`, `worker_assigned`, etc.) that labelle-engine observes
- **Engine → Tasks**: Not yet defined

**Key insight: labelle-tasks is purely event-driven.**
- No internal timers or update loop
- No transportation logic
- Game controls all timing and movement
- Tasks engine is a state machine / orchestrator

**Problem**: When game logic modifies state that affects tasks, how does labelle-tasks learn about it?

Examples:
- Player drops item into storage → task engine needs to know storage has item
- Worker finishes walking/animation → task engine needs to know step is complete
- Worker finishes processing → task engine needs to know (no internal timer!)
- External system fills EIS → workstation may become unblocked

## Design Goals

1. **Decoupled** - labelle-tasks maintains its own internal state (workers, workstations, storages, items)
2. **Explicit** - Clear contract of what notifications are expected
3. **Efficient** - No polling, immediate notification
4. **Symmetric** - Mirror the existing hooks pattern (tasks→engine) for engine→tasks

## Architecture

```
┌─────────────────┐                    ┌─────────────────┐
│  labelle-engine │                    │  labelle-tasks  │
│      (ECS)      │                    │ (internal state)│
├─────────────────┤                    ├─────────────────┤
│ TaskStorage     │───notifications───>│ storages map    │
│ TaskWorker      │    (this RFC)      │ workers map     │
│ KitchenWS       │                    │ workstations    │
│ WellWS          │                    │                 │
│ ...             │<──────hooks────────│ hooks system    │
└─────────────────┘   (already exists) └─────────────────┘
```

labelle-tasks owns its internal state. labelle-engine (or game code) must notify labelle-tasks when external changes occur that affect task state.

## Options

### Option A: Direct Method Calls

The game/engine calls task engine methods directly when state changes:

```zig
// In game code when player drops item
fn onPlayerDropItem(storage_entity: Entity, item: Item) void {
    // Update ECS component
    registry.getPtr(storage_entity, TaskStorage).?.item = item;

    // Notify task engine
    task_engine.notifyStorageChanged(storage_entity, .{ .item = item });
}

// In labelle-tasks
pub fn notifyStorageChanged(self: *Self, storage: GameId, change: StorageChange) void {
    // Update internal state, check if workstations become unblocked
}
```

**Pros:**
- Simple, explicit
- Type-safe
- Easy to understand

**Cons:**
- Requires manual notification at every change point
- Easy to forget a notification
- Tight coupling between game code and task engine calls

### Option B: Event Queue

Engine pushes events to a queue, task engine processes them:

```zig
// In game code
task_events.push(.{ .storage_changed = .{ .storage = entity, .item = .Flour } });

// In task engine update
pub fn update(self: *Self) void {
    while (task_events.pop()) |event| {
        switch (event) {
            .storage_changed => |e| self.handleStorageChanged(e),
            .worker_available => |e| self.handleWorkerAvailable(e),
        }
    }
}
```

**Pros:**
- Decoupled timing (batch processing possible)
- Clear event types
- Easy to debug (can log queue)

**Cons:**
- Delayed processing (not immediate)
- Extra memory for queue
- Need to define event types

### Option C: Reverse Hooks (Notification Dispatcher)

Mirror the existing hooks pattern. Game provides a dispatcher that task engine calls:

```zig
// Game defines a notification handler
const GameNotifications = struct {
    pub fn itemAddedToStorage(storage_id: u32, item: Item) void {
        // Game receives notification, can update ECS, play sounds, etc.
    }

    pub fn workerAssigned(worker_id: u32, workstation_id: u32) void {
        // Update worker sprite, start walk animation, etc.
    }
};

// Task engine is generic over notification dispatcher (like current hooks)
var engine = tasks.Engine(u32, Item, GameNotifications).init(allocator);
```

Wait - this is what we already have for tasks→engine. For engine→tasks, we need the reverse:

```zig
// Task engine exposes notification methods
pub fn Engine(...) type {
    return struct {
        // Called by game/engine when external state changes
        pub fn notifyItemAdded(self: *Self, storage_id: GameId, item: Item) void {
            // Update internal state
            const storage = self.storages.getPtr(storage_id) orelse return;
            storage.item = item;
            storage.quantity += 1;

            // Check if any workstation becomes unblocked
            self.reevaluateWorkstations();
        }

        pub fn notifyWorkerIdle(self: *Self, worker_id: GameId) void {
            // Already exists! This is the pattern.
        }
    };
}
```

**This is essentially Option A** - direct method calls. The question is: what's the API?

## Current API (Already Exists)

Looking at the current labelle-tasks API, we already have notification methods:

```zig
// These already exist in engine.zig
engine.notifyWorkerIdle(worker_id);      // Worker available for assignment
engine.notifyPickupComplete(worker_id);  // Worker finished picking up item
engine.notifyStoreComplete(worker_id);   // Worker finished storing item
engine.notifyResourcesAvailable();       // Resources changed, re-evaluate
```

The pattern is already established. The question is: **what additional notifications are needed?**

## Proposed Notifications

### Storage State Changes

```zig
/// Called when an item is added to a storage externally (e.g., player drop, delivery)
pub fn notifyItemAdded(self: *Self, storage_id: GameId, item: Item, quantity: u32) void;

/// Called when an item is removed from a storage externally (e.g., player pickup, decay)
pub fn notifyItemRemoved(self: *Self, storage_id: GameId, item: Item, quantity: u32) void;

/// Called when storage is cleared (e.g., destroyed, reset)
pub fn notifyStorageCleared(self: *Self, storage_id: GameId) void;
```

### Worker State Changes

```zig
/// Already exists: notifyWorkerIdle

/// Called when worker becomes unavailable (e.g., sleeping, busy with non-task work)
pub fn notifyWorkerUnavailable(self: *Self, worker_id: GameId) void;

/// Called when worker is removed from the game
pub fn notifyWorkerRemoved(self: *Self, worker_id: GameId) void;
```

### Workstation State Changes

```zig
/// Called when workstation is disabled (e.g., broken, unpowered)
pub fn notifyWorkstationDisabled(self: *Self, workstation_id: GameId) void;

/// Called when workstation is enabled
pub fn notifyWorkstationEnabled(self: *Self, workstation_id: GameId) void;

/// Called when workstation is removed
pub fn notifyWorkstationRemoved(self: *Self, workstation_id: GameId) void;
```

## Integration with labelle-engine

The `TasksPlugin` would wire ECS changes to these notifications:

```zig
pub const TasksPlugin = struct {
    pub fn EngineHooks(comptime task_engine: *TaskEngine) type {
        return struct {
            // When ECS component changes, notify task engine
            pub fn on_component_changed(entity: Entity, comptime C: type, old: C, new: C) void {
                if (C == TaskStorage) {
                    if (old.quantity < new.quantity) {
                        task_engine.notifyItemAdded(entity, new.item, new.quantity - old.quantity);
                    } else if (old.quantity > new.quantity) {
                        task_engine.notifyItemRemoved(entity, old.item, old.quantity - new.quantity);
                    }
                }
            }

            // When entity destroyed
            pub fn on_entity_destroyed(entity: Entity) void {
                task_engine.notifyStorageCleared(entity);
                task_engine.notifyWorkerRemoved(entity);
                task_engine.notifyWorkstationRemoved(entity);
            }
        };
    }
};
```

Or for games not using labelle-engine, direct calls:

```zig
// In game code
fn onPlayerDropItem(storage_id: u32, item: Item) void {
    // Update game state
    game.storages[storage_id].item = item;
    game.storages[storage_id].quantity += 1;

    // Notify task engine
    task_engine.notifyItemAdded(storage_id, item, 1);
}
```

## Design Decisions

### 1. Payload Structure: Mirror TaskHooks

GameHooks use the same pattern as TaskHooks for symmetry:

```zig
// TaskHooks payload (tasks → engine) - already exists
pub fn TaskHookPayload(comptime GameId: type, comptime Item: type) type {
    return union(enum) {
        cycle_completed: struct { workstation_id: GameId, cycles_completed: u32 },
        worker_assigned: struct { worker_id: GameId, workstation_id: GameId },
        pickup_started: struct { worker_id: GameId, storage_id: GameId, item: Item },
        // ...
    };
}

// GameHooks payload (engine → tasks) - NEW
pub fn GameHookPayload(comptime GameId: type, comptime Item: type) type {
    return union(enum) {
        // Storage
        item_added: struct { storage_id: GameId, item: Item },
        item_removed: struct { storage_id: GameId },
        storage_cleared: struct { storage_id: GameId },

        // Worker
        worker_available: struct { worker_id: GameId },
        worker_unavailable: struct { worker_id: GameId },
        worker_removed: struct { worker_id: GameId },

        // Workstation
        workstation_enabled: struct { workstation_id: GameId },
        workstation_disabled: struct { workstation_id: GameId },
        workstation_removed: struct { workstation_id: GameId },

        // Step completion
        pickup_completed: struct { worker_id: GameId },
        store_completed: struct { worker_id: GameId },

        // Work accumulation (called every frame while worker is processing)
        work: struct { workstation_id: GameId, delta_time: f32 },
    };
}
```

**Usage - symmetric with TaskHooks:**

```zig
// TaskHooks: game receives from tasks
const MyTaskHooks = struct {
    pub fn cycle_completed(payload: TaskHookPayload(u32, Item)) void {
        const info = payload.cycle_completed;
        playSound("ding");
    }
};

// GameHooks: tasks receives from game
// Engine has a handle() method that receives GameHookPayload
const result = engine.handle(GameHookPayload(u32, Item){
    .item_added = .{ .storage_id = 42, .item = .Flour }
});
if (!result) {
    // Hook was rejected, error already logged
}
```

**Convenience methods (optional sugar):**

```zig
// Instead of constructing payload manually:
engine.handle(.{ .item_added = .{ .storage_id = 42, .item = .Flour } });

// Provide shorthand methods that construct the payload:
pub fn itemAdded(self: *Self, storage_id: GameId, item: Item) bool {
    return self.handle(.{ .item_added = .{ .storage_id = storage_id, .item = item } });
}

// Usage
engine.itemAdded(42, .Flour);
```

This gives both:
- **Symmetric API** via `handle(GameHookPayload)`
- **Ergonomic API** via convenience methods

### 2. Single-Item Model (No Quantity)

Storages hold 0 or 1 item. Hooks are simply:
- `item_added(storage_id, item)` - storage now has item
- `item_removed(storage_id)` - storage is now empty

No quantity parameter needed.

### 3. Naming Style: Past Tense Events

All hooks use **past tense** to indicate something that happened:

| Current | Renamed |
|---------|---------|
| `worker_idle` | `worker_became_idle` or `worker_idled`? |
| `pickup_complete` | `pickup_completed` |
| `store_complete` | `store_completed` |

Looking at existing TaskHooks for consistency:
- `pickup_started`, `process_completed`, `store_started`
- `worker_assigned`, `worker_released`
- `workstation_blocked`, `workstation_activated`

For states, use past participle: `worker_idled` sounds odd → use **`worker_available`** instead (describes the resulting state, matches intent).

**Final naming:**
- `item_added`, `item_removed`, `storage_cleared`
- `worker_available`, `worker_unavailable`, `worker_removed`
- `workstation_enabled`, `workstation_disabled`, `workstation_removed`
- `pickup_completed`, `store_completed`

### 4. Rename Existing `notifyXxx` Methods

| Current Method | New Name |
|----------------|----------|
| `notifyWorkerIdle()` | `worker_available()` |
| `notifyPickupComplete()` | `pickup_completed()` |
| `notifyStoreComplete()` | `store_completed()` |
| `notifyResourcesAvailable()` | Remove (implicit via `item_added`) |

### 5. Precise Hook Scenarios

| Hook | When to Call |
|------|--------------|
| `item_added` | External source adds item to storage (player drop, delivery, spawn) |
| `item_removed` | External source removes item (player pickup, decay, despawn) |
| `storage_cleared` | Storage destroyed or reset |
| `worker_available` | Worker finishes non-task activity, becomes available for assignment |
| `worker_unavailable` | Worker starts non-task activity (eating, sleeping, player control) |
| `worker_removed` | Worker entity destroyed |
| `workstation_enabled` | Workstation repaired, powered on |
| `workstation_disabled` | Workstation broken, unpowered |
| `workstation_removed` | Workstation entity destroyed |
| `pickup_completed` | Worker finished pickup movement (arrived at workstation with item in IIS) |
| `work` | Every frame while worker is processing (accumulates work time) |
| `store_completed` | Worker finished store movement (arrived at EOS, item stored) |

**Note:** Task engine internally manages items during task execution. External hooks (`item_added`, `item_removed`) are for changes **outside** of task workflow.

### 5b. Work Accumulation and Transformation

The `work` hook is special - it's called every frame while a worker is processing:

```zig
// Game loop while worker is at workstation
fn update(delta_time: f32) void {
    if (worker.state == .Processing) {
        _ = engine.handle(.{ .work = .{
            .workstation_id = worker.assigned_workstation,
            .delta_time = delta_time,
        }});
    }
}
```

**Task engine internally:**
1. Accumulates work time for the workstation
2. When `accumulated_work >= workstation.required_work`:
   - Transforms IIS items → IOS items
   - Emits `work_completed` TaskHook to notify game
   - Advances to Store step

```zig
// Inside engine.handleWork()
fn handleWork(self: *Self, workstation_id: GameId, delta_time: f32) bool {
    const ws = self.workstations.getPtr(workstation_id) orelse return false;

    ws.accumulated_work += delta_time;

    if (ws.accumulated_work >= ws.required_work) {
        // Transform IIS → IOS
        self.transformItems(workstation_id);

        // Notify game
        self.dispatchHook(.{ .work_completed = .{
            .workstation_id = workstation_id,
            .worker_id = ws.assigned_worker,
        }});

        // Advance to store step
        ws.current_step = .Store;
        ws.accumulated_work = 0;
    }

    return true;
}
```

**TaskHook emitted (tasks → game):**
```zig
// In TaskHookPayload
work_completed: struct {
    workstation_id: GameId,
    worker_id: GameId,
},
```

The game receives `work_completed` and knows:
- Transformation happened (IIS → IOS)
- Worker should now move to EOS to store

### 5b. Transport Responsibility

**labelle-tasks does NOT handle transportation.**

The task engine:
- Determines what needs to move (e.g., "item X should go from storage A to storage B")
- Emits hooks like `pickup_started`, `store_started` to inform the game
- Tracks workflow state (which step we're on)

The game is responsible for:
- Actual movement (pathfinding, animation, physics)
- Timing (how long movement takes)
- Notifying task engine when movement completes (`pickup_completed`, `store_completed`)

```
Task Engine                          Game
     │                                 │
     │──pickup_started(worker, eis)───>│  "Worker should pick up from EIS"
     │                                 │
     │                                 │  Game: pathfind, animate, move
     │                                 │
     │<──pickup_completed(worker)──────│  "Worker arrived, item in IIS"
     │                                 │
     │──process_started(worker, ws)───>│  "Worker should process"
     │                                 │
     │                                 │  Game: play animation
     │<──work(ws, dt)──────────────────│  (every frame)
     │<──work(ws, dt)──────────────────│  (every frame)
     │<──work(ws, dt)──────────────────│  (every frame)
     │   ... accumulated >= required   │
     │                                 │
     │──work_completed(ws, worker)────>│  "IIS→IOS done, go store"
     │                                 │
     │──store_started(worker, eos)────>│  "Worker should store at EOS"
     │                                 │
     │                                 │  Game: animate, move
     │                                 │
     │<──store_completed(worker)───────│  "Item stored"
     │                                 │
     │──cycle_completed(ws)───────────>│  "Cycle done!"
```

### 6. Error Handling: Log Unknown Entities

If game calls hook for unknown entity, task engine:
1. Logs error with entity ID and hook name
2. Returns without crashing
3. Optionally returns `false` to indicate failure

```zig
pub fn item_added(self: *Self, storage_id: GameId, item: Item) bool {
    const storage = self.storages.getPtr(storage_id) orelse {
        log.err("item_added called for unknown storage: {}", .{storage_id});
        return false;
    };
    // ... handle
    return true;
}
```

### 7. Return Values: Success/Failure with Logging

Hooks return `bool`:
- `true` - hook handled successfully
- `false` - hook rejected (logged error explaining why)

Rejection reasons:
- Unknown entity
- Invalid state transition (e.g., `item_added` to already-full storage)
- Item type mismatch

```zig
pub fn item_added(self: *Self, storage_id: GameId, item: Item) bool {
    const storage = self.storages.getPtr(storage_id) orelse {
        log.err("item_added: unknown storage {}", .{storage_id});
        return false;
    };
    if (storage.item != null) {
        log.err("item_added: storage {} already has item", .{storage_id});
        return false;
    }
    if (!storage.accepts.contains(item)) {
        log.err("item_added: storage {} doesn't accept {}", .{storage_id, item});
        return false;
    }
    storage.item = item;
    self.reevaluateWorkstations();
    return true;
}
```

### 8. Save/Load and Initial State

When loading a save or starting with pre-existing state, the game must restore task engine state.

**Option A: Replay hooks**
```zig
// After creating engine and registering entities...
// Replay current state as hooks
for (storages) |storage| {
    if (storage.item) |item| {
        _ = engine.handle(.{ .item_added = .{ .storage_id = storage.id, .item = item } });
    }
}
for (workers) |worker| {
    if (worker.is_available) {
        _ = engine.handle(.{ .worker_available = .{ .worker_id = worker.id } });
    }
}
```

**Option B: Bulk restore API**
```zig
// Dedicated method for loading saved state
engine.restoreState(.{
    .storages = &.{
        .{ .id = 1, .item = .Flour },
        .{ .id = 2, .item = null },
    },
    .workers = &.{
        .{ .id = 10, .state = .Idle },
        .{ .id = 11, .state = .Working, .assigned_to = 100 },
    },
    .workstations = &.{
        .{ .id = 100, .status = .Active, .current_step = .Process },
    },
});
```

**Option C: Serialize/deserialize engine state**
```zig
// Save
const saved_state = engine.serialize();
save_to_file(saved_state);

// Load
const saved_state = load_from_file();
engine.deserialize(saved_state);
```

**Recommendation:** Start with **Option A** (replay hooks) - simplest, uses existing API. Add Option C later if serialization becomes important.

## Final Design

### Architecture (Symmetric Hooks)

```
┌─────────────────┐                      ┌─────────────────┐
│  labelle-engine │                      │  labelle-tasks  │
│      (ECS)      │                      │ (internal state)│
├─────────────────┤                      ├─────────────────┤
│                 │                      │                 │
│ game.handle(    │───GameHookPayload───>│ engine.handle() │
│   .item_added   │                      │   → updates     │
│   .worker_avail │                      │     internal    │
│   ...           │                      │     state       │
│ )               │                      │   → returns     │
│                 │                      │     bool        │
│                 │                      │                 │
│ MyTaskHooks.    │<──TaskHookPayload────│ dispatches via  │
│   cycle_complete│                      │   TaskHooks     │
│   worker_assign │                      │                 │
│   ...           │                      │                 │
└─────────────────┘                      └─────────────────┘
```

### Engine API

```zig
pub fn Engine(
    comptime GameId: type,
    comptime Item: type,
    comptime TaskHooks: type,
) type {
    return struct {
        const Self = @This();
        const GamePayload = GameHookPayload(GameId, Item);

        // Main hook handler (symmetric with TaskHooks dispatch)
        pub fn handle(self: *Self, payload: GamePayload) bool {
            return switch (payload) {
                .item_added => |p| self.handleItemAdded(p.storage_id, p.item),
                .item_removed => |p| self.handleItemRemoved(p.storage_id),
                .storage_cleared => |p| self.handleStorageCleared(p.storage_id),
                .worker_available => |p| self.handleWorkerAvailable(p.worker_id),
                .worker_unavailable => |p| self.handleWorkerUnavailable(p.worker_id),
                .worker_removed => |p| self.handleWorkerRemoved(p.worker_id),
                .workstation_enabled => |p| self.handleWorkstationEnabled(p.workstation_id),
                .workstation_disabled => |p| self.handleWorkstationDisabled(p.workstation_id),
                .workstation_removed => |p| self.handleWorkstationRemoved(p.workstation_id),
                .pickup_completed => |p| self.handlePickupCompleted(p.worker_id),
                .work => |p| self.handleWork(p.workstation_id, p.delta_time),
                .store_completed => |p| self.handleStoreCompleted(p.worker_id),
            };
        }

        // Convenience methods (optional, for ergonomics)
        pub fn itemAdded(self: *Self, storage_id: GameId, item: Item) bool {
            return self.handle(.{ .item_added = .{ .storage_id = storage_id, .item = item } });
        }

        pub fn workerAvailable(self: *Self, worker_id: GameId) bool {
            return self.handle(.{ .worker_available = .{ .worker_id = worker_id } });
        }

        pub fn work(self: *Self, workstation_id: GameId, delta_time: f32) bool {
            return self.handle(.{ .work = .{ .workstation_id = workstation_id, .delta_time = delta_time } });
        }

        // ... other convenience methods
    };
}
```

### Usage Example

```zig
const Item = enum { Flour, Bread, Water };

// Game's TaskHooks (receives from tasks)
const MyTaskHooks = struct {
    pub fn cycle_completed(payload: tasks.TaskHookPayload(u32, Item)) void {
        const info = payload.cycle_completed;
        game.playSound("production_complete");
    }

    pub fn worker_assigned(payload: tasks.TaskHookPayload(u32, Item)) void {
        const info = payload.worker_assigned;
        game.startWalkAnimation(info.worker_id, info.workstation_id);
    }
};

// Create engine
var engine = tasks.Engine(u32, Item, MyTaskHooks).init(allocator);

// Game sends events to tasks via handle()
fn onPlayerDropItem(storage_id: u32, item: Item) void {
    const success = engine.handle(.{ .item_added = .{ .storage_id = storage_id, .item = item } });
    if (!success) {
        game.showMessage("Can't place item here");
    }
}

// Or using convenience method
fn onWorkerFinishedEating(worker_id: u32) void {
    _ = engine.workerAvailable(worker_id);
}
```

### labelle-engine Integration (TasksPlugin)

```zig
pub const TasksPlugin = struct {
    engine: *TaskEngine,

    // Wire ECS observers to GameHooks
    pub fn onComponentChanged(self: *Self, entity: Entity, comptime C: type, old: C, new: C) void {
        if (C == TaskStorage) {
            if (old.item == null and new.item != null) {
                _ = self.engine.handle(.{ .item_added = .{
                    .storage_id = entity,
                    .item = new.item.?,
                } });
            } else if (old.item != null and new.item == null) {
                _ = self.engine.handle(.{ .item_removed = .{
                    .storage_id = entity,
                } });
            }
        }
    }

    pub fn onEntityDestroyed(self: *Self, entity: Entity) void {
        // Try all removal hooks (only relevant one will succeed)
        _ = self.engine.handle(.{ .storage_cleared = .{ .storage_id = entity } });
        _ = self.engine.handle(.{ .worker_removed = .{ .worker_id = entity } });
        _ = self.engine.handle(.{ .workstation_removed = .{ .workstation_id = entity } });
    }
};
```

## Summary

### Hook Comparison

| Aspect | TaskHooks (tasks→game) | GameHooks (game→tasks) |
|--------|------------------------|------------------------|
| Payload | `TaskHookPayload` union | `GameHookPayload` union |
| Direction | Tasks dispatches | Game dispatches |
| Receiver | Game's hook struct | Engine's `handle()` method |
| Return | `void` | `bool` (success/failure) |
| On error | N/A | Logs and returns `false` |

### All GameHooks (game → tasks)

| Hook | Payload Fields | Purpose |
|------|----------------|---------|
| `item_added` | `storage_id`, `item` | External item added to storage |
| `item_removed` | `storage_id` | External item removed from storage |
| `storage_cleared` | `storage_id` | Storage destroyed/reset |
| `worker_available` | `worker_id` | Worker ready for task assignment |
| `worker_unavailable` | `worker_id` | Worker busy with non-task work |
| `worker_removed` | `worker_id` | Worker entity destroyed |
| `workstation_enabled` | `workstation_id` | Workstation operational |
| `workstation_disabled` | `workstation_id` | Workstation non-operational |
| `workstation_removed` | `workstation_id` | Workstation entity destroyed |
| `pickup_completed` | `worker_id` | Worker finished pickup step |
| `work` | `workstation_id`, `delta_time` | Accumulate work (every frame) |
| `store_completed` | `worker_id` | Worker finished store step |

### New TaskHook (tasks → game)

| Hook | Payload Fields | Purpose |
|------|----------------|---------|
| `work_completed` | `workstation_id`, `worker_id` | Transformation done (IIS→IOS), advance to store |

### Key Points

1. **No timers** - Game calls `work(delta_time)` every frame, task engine accumulates
2. **No transport** - Game handles movement, task engine tracks state
3. **Event-driven** - All state changes via hooks
4. **Symmetric** - Both directions use typed payload unions
5. **Transformation** - Happens automatically when work accumulates to required amount

## References

- [RFC 026: Comptime Workstations](./026-comptime-workstations.md)
- [labelle-tasks hooks system](../src/hooks.zig)
