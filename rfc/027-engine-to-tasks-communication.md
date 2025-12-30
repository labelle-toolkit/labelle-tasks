# RFC 027: Engine-to-Tasks Communication

**Status**: Draft
**Issue**: TBD
**Author**: @alexandrecalvao
**Created**: 2025-12-28
**Updated**: 2025-12-29

## Summary

Define how labelle-engine communicates state changes to labelle-tasks via `GameHooks`. The task engine is a **pure state machine** - it tracks abstract workflow state and emits hooks, but never mutates game state.

## Context

**Communication flow:**
- **Tasks → Game**: labelle-tasks emits hooks (`cycle_completed`, `worker_assigned`, etc.) that game observes
- **Game → Tasks**: Game calls `engine.handle()` with `GameHookPayload` to notify of events

**Key insight: labelle-tasks is a pure state machine.**
- Tracks abstract workflow state only (has_item, item_type, current_step)
- No internal timers or update loop
- No transportation logic
- No entity references or ECS knowledge
- Never mutates game state - only updates its own abstract state
- Game controls all timing, movement, and entity lifecycle

**Problem**: When game logic modifies state that affects tasks, how does labelle-tasks learn about it?

Examples:
- Player drops item into storage → task engine needs to know storage has item
- Worker finishes walking/animation → task engine needs to know step is complete
- Worker finishes processing → task engine needs to know (no internal timer!)
- External system fills EIS → workstation may become unblocked

## Design Goals

1. **Pure state machine** - Task engine only tracks abstract state, never touches game entities
2. **Decoupled** - labelle-tasks maintains its own internal state (workers, workstations, storages, items)
3. **Explicit** - Clear contract of what notifications are expected
4. **Efficient** - No polling, immediate notification
5. **Symmetric** - Mirror the existing hooks pattern (tasks→game) for game→tasks

## Architecture

```
┌─────────────────┐                    ┌─────────────────┐
│      Game       │                    │  labelle-tasks  │
│  (ECS, Entities)│                    │ (Abstract State)│
├─────────────────┤                    ├─────────────────┤
│ item_entity     │                    │ has_item: bool  │
│ positions       │───GameHookPayload─>│ item_type: ?Item│
│ prefabs         │    handle()        │ current_step    │
│ timers          │                    │ worker_state    │
│ ...             │<──TaskHookPayload──│ hooks system    │
└─────────────────┘                    └─────────────────┘
```

**Key principle**: Task engine tracks **abstract state** (has_item, item_type), game tracks **concrete entities** (item_entity, positions). Task engine never references game entities.

labelle-tasks owns its internal abstract state. Game must notify labelle-tasks when external changes occur that affect workflow state.

## Options

### Option A: Direct Method Calls

The game/engine calls task engine methods directly when state changes:

```zig
// In game code when player drops item
fn onPlayerDropItem(storage_entity: Entity, item: Item) void {
    // Update game's own state (ECS, etc.)
    game.addItemToStorage(storage_entity, item);

    // Notify task engine (just the entity id)
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

The game wires its own state changes to task engine notifications. This is game-specific - the task engine doesn't know about ECS or any specific data structures:

```zig
// Example: Game wires its own systems to notify task engine
pub const GameTaskIntegration = struct {
    task_engine: *TaskEngine,

    // Game calls this when its storage state changes
    pub fn onStorageItemAdded(self: *@This(), entity_id: u32, item: Item) void {
        _ = self.task_engine.handle(.{ .item_added = .{
            .storage_id = entity_id,
            .item = item,
        }});
    }

    pub fn onStorageItemRemoved(self: *@This(), entity_id: u32) void {
        _ = self.task_engine.handle(.{ .item_removed = .{
            .storage_id = entity_id,
        }});
    }

    // When entity destroyed
    pub fn onEntityDestroyed(self: *@This(), entity_id: u32) void {
        // Try all removal hooks (only relevant one will succeed)
        _ = self.task_engine.handle(.{ .storage_cleared = .{ .storage_id = entity_id } });
        _ = self.task_engine.handle(.{ .worker_removed = .{ .worker_id = entity_id } });
        _ = self.task_engine.handle(.{ .workstation_removed = .{ .workstation_id = entity_id } });
    }
};
```

Or direct inline calls:

```zig
// In game code
fn onPlayerDropItem(storage_id: u32, item: Item) void {
    // Update game's own state (however the game stores it)
    game.addItemToStorage(storage_id, item);

    // Notify task engine (just the entity id and item type)
    _ = task_engine.handle(.{ .item_added = .{ .storage_id = storage_id, .item = item } });
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
        work_completed: struct { workstation_id: GameId },  // Game tracks timing
        store_completed: struct { worker_id: GameId },
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
| `work_completed` | Game's work timer finished (processing complete) |
| `store_completed` | Worker finished store movement (arrived at EOS, item stored) |

**Note:** Task engine internally manages items during task execution. External hooks (`item_added`, `item_removed`) are for changes **outside** of task workflow.

### 5b. Work Completion (Single Source of Truth)

**Game owns work timing.** Task engine does NOT track:
- `required_work`
- `accumulated_work`
- Progress percentage

Game tracks work internally and notifies when complete:

```zig
// Game tracks work progress
fn update(delta_time: f32) void {
    for (work_in_progress.items) |*progress| {
        progress.accumulated += delta_time;

        if (progress.accumulated >= progress.required) {
            // Notify task engine - work is done
            _ = engine.handle(.{ .work_completed = .{
                .workstation_id = progress.workstation_id,
            }});
        }
    }
}
```

**Task engine handler:**
```zig
fn handleWorkCompleted(self: *Self, workstation_id: GameId) bool {
    const ws = self.workstations.getPtr(workstation_id) orelse return false;

    // Transform IIS → IOS
    self.transformItems(workstation_id);

    // Advance to store step
    ws.current_step = .Store;

    // Emit store_started hook
    self.dispatchHook(.{ .store_started = .{
        .worker_id = ws.assigned_worker,
        .storage_id = self.selectEos(workstation_id),
    }});

    return true;
}
```

See [RFC 028: Work Completion Model](./028-work-accumulation.md) for details.

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
     │                                 │  Game: play animation, track time
     │                                 │  Game: when timer complete...
     │                                 │
     │<──work_completed(ws)────────────│  "Processing done"
     │                                 │
     │   (transform IIS → IOS)         │
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

### Architecture (Pure State Machine)

```
┌─────────────────────────────────────┐    ┌─────────────────────────────────────┐
│              Game                    │    │           Task Engine                │
│        (Concrete State)              │    │        (Abstract State)              │
├─────────────────────────────────────┤    ├─────────────────────────────────────┤
│  item_entity: ?Entity               │    │  has_item: bool                     │
│  position: Vec2                     │    │  item_type: ?Item                   │
│  prefab instances                   │    │  current_step: Step                 │
│  work_timer: f32                    │    │  assigned_worker: ?GameId           │
│  accumulated_work: f32              │    │  workstation_status: Status         │
├─────────────────────────────────────┤    ├─────────────────────────────────────┤
│                                     │    │                                     │
│  engine.handle(.{                   │───>│  Updates abstract state only        │
│    .work_completed = ...            │    │  (has_item, current_step, etc.)     │
│  })                                 │    │                                     │
│                                     │    │                                     │
│  MyTaskHooks.process_completed()    │<───│  Emits hooks to notify game         │
│  MyTaskHooks.store_started()        │    │  (game reacts by mutating entities) │
│                                     │    │                                     │
└─────────────────────────────────────┘    └─────────────────────────────────────┘
```

**Key principle**: Task engine tracks **abstract state** only. It never holds entity references, never instantiates prefabs, never mutates game state. All entity lifecycle is handled by the game in response to TaskHooks.

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
                .work_completed => |p| self.handleWorkCompleted(p.workstation_id),
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

        pub fn workCompleted(self: *Self, workstation_id: GameId) bool {
            return self.handle(.{ .work_completed = .{ .workstation_id = workstation_id } });
        }

        // ... other convenience methods
    };
}
```

### Usage Example

```zig
const Item = enum { Flour, Bread, Water };

// Game's TaskHooks (receives from tasks)
// Game reacts to hooks by mutating its own entity state
const MyTaskHooks = struct {
    game: *Game,

    pub fn cycle_completed(self: *@This(), payload: tasks.TaskHookPayload(u32, Item)) void {
        const info = payload.cycle_completed;
        self.game.playSound("production_complete");
    }

    pub fn worker_assigned(self: *@This(), payload: tasks.TaskHookPayload(u32, Item)) void {
        const info = payload.worker_assigned;
        self.game.startWalkAnimation(info.worker_id, info.workstation_id);
    }

    // Game handles entity transformation when processing completes
    pub fn process_completed(self: *@This(), payload: tasks.TaskHookPayload(u32, Item)) void {
        const info = payload.process_completed;

        // Game uses workstation_id to look up its own data
        // Task engine doesn't know about game's data structures
        self.game.transformWorkstationItems(info.workstation_id);
    }

    pub fn store_started(self: *@This(), payload: tasks.TaskHookPayload(u32, Item)) void {
        const info = payload.store_started;
        // Start worker movement to EOS
        self.game.startWalkAnimation(info.worker_id, info.storage_id);
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

### Game Integration Pattern

The game is responsible for notifying the task engine when state changes. How it does this is up to the game - the task engine doesn't prescribe any specific pattern:

```zig
// Example: Game notifies task engine when its storage state changes
pub const GameTaskBridge = struct {
    engine: *TaskEngine,

    pub fn onItemAddedToStorage(self: *@This(), entity_id: u32, item: Item) void {
        _ = self.engine.handle(.{ .item_added = .{
            .storage_id = entity_id,
            .item = item,
        }});
    }

    pub fn onItemRemovedFromStorage(self: *@This(), entity_id: u32) void {
        _ = self.engine.handle(.{ .item_removed = .{
            .storage_id = entity_id,
        }});
    }

    pub fn onEntityDestroyed(self: *@This(), entity_id: u32) void {
        // Try all removal hooks (only relevant one will succeed)
        _ = self.engine.handle(.{ .storage_cleared = .{ .storage_id = entity_id } });
        _ = self.engine.handle(.{ .worker_removed = .{ .worker_id = entity_id } });
        _ = self.engine.handle(.{ .workstation_removed = .{ .workstation_id = entity_id } });
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
| `work_completed` | `workstation_id` | Game's work timer finished |
| `store_completed` | `worker_id` | Worker finished store step |

### Key Points

1. **Pure state machine** - Task engine tracks abstract state only, never mutates game entities
2. **No timers in task engine** - Game owns work timing, calls `work_completed` when done
3. **No transport** - Game handles movement, task engine tracks workflow step
4. **No entity references** - Task engine uses GameId for correlation, not entity pointers
5. **Game handles entity lifecycle** - Destruction/creation of items in response to TaskHooks
6. **Event-driven** - All state changes via hooks
7. **Symmetric** - Both directions use typed payload unions

### State Ownership Summary

| State | Owner | Description |
|-------|-------|-------------|
| `has_item` | Task Engine | Abstract: "does this storage have an item?" |
| `item_type` | Task Engine | Abstract: "what type of item?" |
| `current_step` | Task Engine | Workflow: Pickup/Process/Store |
| `assigned_worker` | Task Engine | Which worker is assigned |
| `item_entity` | Game | Concrete: actual entity reference |
| `position` | Game | Where things are in the world |
| `work_timer` | Game | How long until processing completes |
| `prefab_instance` | Game | Visual representation |

## References

- [RFC 028: Work Completion Model](./028-work-accumulation.md)
- [RFC 029: Task Engine as Pure State Machine](./029-engine-actions-api.md)
- [labelle-tasks hooks system](../src/hooks.zig)
