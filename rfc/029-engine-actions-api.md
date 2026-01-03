# RFC 029: Task Engine as Pure State Machine

**Status**: Draft
**Issue**: TBD
**Author**: @alexandrecalvao
**Created**: 2025-12-28
**Updated**: 2025-12-29
**Related**: [RFC 027: Engine-to-Tasks Communication](./027-engine-to-tasks-communication.md)

## Summary

The task engine is a **pure state machine** that tracks abstract workflow state. It never mutates game state directly - all entity lifecycle (creation, destruction, transformation) is handled by the game in response to hooks.

## Problem

Previous design considered an `Actions` API where the task engine would call back into the game to perform mutations:

```zig
// REJECTED: Actions API
Actions.performTransformation(workstation_id);  // Task engine calls game
```

This created unnecessary coupling and complexity. The game already knows when processing completes (it owns the timer), so it can handle entity transformation itself.

## Design: Pure State Machine

The task engine:
1. **Tracks abstract state** - `has_item`, `item_type`, workflow step, worker assignment
2. **Receives notifications** - Game tells it what happened via `handle()`
3. **Emits hooks** - Notifies game of workflow events
4. **Never mutates game state** - No entity creation, destruction, or modification

```
┌─────────────────────────────────────────────────────────────────┐
│                        Task Engine                               │
│                    (Pure State Machine)                          │
├─────────────────────────────────────────────────────────────────┤
│  Tracks:                                                         │
│  - Abstract item presence (has_item: bool, item_type: ?Item)    │
│  - Workflow state (current_step: .Pickup/.Process/.Store)       │
│  - Worker assignment (assigned_worker: ?GameId)                 │
│  - Workstation status (.Blocked/.Queued/.Active)                │
├─────────────────────────────────────────────────────────────────┤
│  Does NOT track:                                                 │
│  - Entity references                                             │
│  - Positions                                                     │
│  - Timers or work progress                                       │
│  - Prefab instances                                              │
└─────────────────────────────────────────────────────────────────┘
```

## Communication Flow

All communication is **one-way notifications**:

```
Game                                Task Engine
  │                                      │
  │── handle(.pickup_completed) ────────>│  "worker arrived with item"
  │                                      │  (updates: IIS has_item = true)
  │<──────── process_started ────────────│  "start processing"
  │                                      │
  │   (game starts timer, animation)     │
  │   (game tracks work progress)        │
  │   (when timer completes...)          │
  │                                      │
  │── handle(.work_completed) ──────────>│  "processing done"
  │                                      │  (updates: IIS has_item = false,
  │                                      │            IOS has_item = true)
  │<──────── process_completed ──────────│  "transformation done"
  │<──────── store_started ──────────────│  "go store at EOS"
  │                                      │
  │   (game destroys input entities)     │
  │   (game creates output entities)     │
  │   (game moves worker to EOS)         │
  │                                      │
  │── handle(.store_completed) ─────────>│  "item stored"
  │                                      │  (updates: IOS has_item = false,
  │                                      │            EOS has_item = true)
  │<──────── cycle_completed ────────────│  "cycle done!"
```

## Key Insight: Game Owns Entity Transformation

When the task engine receives `work_completed`:
1. It updates its **abstract state** (clear IIS, populate IOS)
2. It emits `process_completed` and `store_started` hooks
3. The **game** reacts to these hooks to handle actual entities:
   - Destroy input entity prefabs
   - Instantiate output entity prefabs
   - Start worker movement animation

The task engine never calls back into the game to "do" anything. It just tracks state and emits notifications.

## Why No Actions API?

| Aspect | Actions API (Rejected) | Pure State Machine |
|--------|------------------------|-------------------|
| Coupling | Task engine depends on game | Game depends on task engine hooks |
| Responsibility | Shared mutation responsibility | Game owns all mutations |
| Complexity | Bidirectional calls | Unidirectional notifications |
| Testing | Harder (mock Actions) | Easier (just send events) |
| Sync issues | Possible state mismatch | Single source of truth per domain |

## State Ownership

```
┌────────────────────────────────────────────────────────────────┐
│                    Task Engine Owns                             │
│  - Abstract item presence (has_item, item_type per storage)    │
│  - Workflow state (current step)                                │
│  - Worker-workstation assignment                                │
│  - Workstation status (Blocked/Queued/Active)                  │
│  - Routing decisions (which EIS, which EOS)                    │
├────────────────────────────────────────────────────────────────┤
│                      Game Owns                                  │
│  - Concrete entities (item_entity: ?Entity)                    │
│  - Prefab instantiation/destruction                            │
│  - Positions, sprites, physics                                 │
│  - Work timing (required_work, accumulated_work)               │
│  - Movement/pathfinding                                        │
│  - All ECS state                                               │
└────────────────────────────────────────────────────────────────┘
```

## Example: Processing Cycle

```zig
// Game receives process_completed hook
const MyTaskHooks = struct {
    game: *Game,

    pub fn process_completed(self: *@This(), payload: TaskHookPayload) void {
        const info = payload.process_completed;

        // Game handles entity transformation using its own data structures
        // Task engine only provides the workstation_id (entity id)
        self.game.transformWorkstationItems(info.workstation_id);
    }

    pub fn store_started(self: *@This(), payload: TaskHookPayload) void {
        const info = payload.store_started;
        // Start worker movement animation toward EOS
        self.game.startWalkAnimation(info.worker_id, info.storage_id);
    }
};

// Game implements its own transformation logic
fn transformWorkstationItems(game: *Game, workstation_id: u32) void {
    // Game looks up its own data (ECS components, prefabs, etc.)
    // Task engine doesn't know or care about these details
    const ws_data = game.getWorkstationData(workstation_id);

    // Destroy input entities
    for (ws_data.input_storages) |storage_id| {
        game.destroyItemAt(storage_id);
    }

    // Create output entities
    for (ws_data.output_storages) |storage_id| {
        const output_item = game.getRecipeOutput(workstation_id);
        game.createItemAt(storage_id, output_item);
    }
}
```

## Engine Signature

No Actions parameter needed:

```zig
// Final signature - 3 comptime parameters
pub fn Engine(
    comptime GameId: type,
    comptime Item: type,
    comptime TaskHooks: type,
) type {
    return struct {
        // handle() for receiving game events
        pub fn handle(self: *Self, payload: GameHookPayload) bool { ... }

        // Internal state updates only, no game mutations
    };
}
```

## Summary

| Mechanism | Direction | Purpose |
|-----------|-----------|---------|
| **GameHooks** (`handle()`) | game → tasks | Notify task engine of events |
| **TaskHooks** | tasks → game | Notify game of workflow events |

The task engine is a pure orchestrator. It decides **what** should happen (workflow logic) and the game decides **how** (entity lifecycle, timing, rendering).

## References

- [RFC 027: Engine-to-Tasks Communication](./027-engine-to-tasks-communication.md)
- [RFC 028: Work Completion Model](./028-work-accumulation.md)
