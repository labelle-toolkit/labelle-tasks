# RFC 035: Worker Movement States

**Issue**: #35
**Status**: Accepted
**Decision**: Option A (simplified) - Single `MovingTo` substate with target entity ID
**Author**: @alexandrecalvao
**Created**: 2026-01-06

## Summary

Add explicit movement states to the worker workflow so the task engine can track when workers are moving to workstations or storages.

## Motivation

Currently, workers are assigned to workstations **instantly** without any movement prerequisite:

```
Worker (Idle) + Workstation (Queued) → Instant Assignment
                                      Worker = Working
                                      Workstation = Active
```

The engine emits hooks like `pickup_started`, and the **game** is responsible for:
1. Moving the worker to the target location
2. Waiting for movement to complete
3. Calling the completion handler (e.g., `pickup_completed`)

### Problems with Current Approach

1. **No explicit movement state**: Worker states are `Idle`, `Working`, `Unavailable` - no `Moving` state
2. **Game must track movement separately**: More complex game implementations
3. **No validation**: Engine accepts `pickup_completed` even if worker hasn't moved
4. **Unclear workflow**: The movement phase is implicit, not part of the documented workflow

### Benefits of Explicit Movement States

1. **Clearer workflow**: Movement is a first-class concept
2. **Better hooks**: `movement_started`, `movement_completed` hooks
3. **Validation possible**: Engine can optionally validate movement completion
4. **Simpler game code**: Game just handles hook → animation, engine handles state

## Current Workflow

```
1. Worker Idle, Workstation Queued
2. worker_available → tryAssignWorkers()
3. assignWorkerToWorkstation():
   - Worker.state = Working
   - Workstation.status = Active
   - Emit: worker_assigned, workstation_activated
4. startPickupStep():
   - Emit: pickup_started { worker_id, storage_id (EIS), item }
5. Game: Move worker to EIS (NOT TRACKED BY ENGINE)
6. Game: engine.handle(.{ .pickup_completed = { .worker_id } })
7. completePickupStep():
   - Move item EIS → IIS
   - Emit: process_started
... etc
```

## Proposed Workflow Options

### Option A: Add Movement as Worker Substates

Keep existing states but add substates for movement tracking:

```zig
pub const WorkerState = enum {
    Idle,
    Working,
    Unavailable,
};

pub const WorkerSubstate = enum {
    None,
    MovingToWorkstation,
    MovingToStorage,
    AtWorkstation,
    Processing,
};
```

**Workflow**:
```
1. Worker Idle, Workstation Queued
2. worker_available → tryAssignWorkers()
3. assignWorkerToWorkstation():
   - Worker.state = Working
   - Worker.substate = MovingToWorkstation
   - Emit: worker_assigned, movement_started { target: workstation }
4. Game: Animate movement
5. Game: engine.handle(.{ .arrival_completed = { .worker_id } })
6. Worker.substate = AtWorkstation
7. Emit: movement_completed, pickup_started
... etc
```

**Pros**:
- Minimal breaking changes
- Backward compatible (substate can be ignored)
- Clear separation of state vs substate

**Cons**:
- Two-level state machine complexity
- New handlers needed

### Option B: Expand Worker States

Add movement as explicit states:

```zig
pub const WorkerState = enum {
    Idle,
    MovingToWorkstation,
    MovingToStorage,
    AtWorkstation,      // Ready to work
    Processing,         // Actively working
    Unavailable,
};
```

**Workflow**:
```
1. Worker Idle, Workstation Queued
2. worker_available → tryAssignWorkers()
3. assignWorkerToWorkstation():
   - Worker.state = MovingToWorkstation
   - Workstation.status = Active
   - Emit: worker_assigned, movement_started { target: workstation }
4. Game: Animate movement
5. Game: engine.handle(.{ .arrival_completed = { .worker_id } })
6. Worker.state = AtWorkstation
7. Emit: movement_completed
8. startPickupStep():
   - Worker.state = MovingToStorage
   - Emit: pickup_started { worker_id, storage_id, item }
... etc
```

**Pros**:
- Clear, explicit states
- One-level state machine
- Better debugging/logging

**Cons**:
- Breaking change to WorkerState enum
- More states to handle

### Option C: Movement as Separate Step Type

Add movement as a step in the workstation cycle:

```zig
pub const StepType = enum {
    MoveToWorkstation,  // NEW
    Pickup,
    MoveToEIS,          // NEW (implicit in pickup?)
    Process,
    MoveToEOS,          // NEW (implicit in store?)
    Store,
};
```

**Workflow**: Movement becomes explicit steps in the cycle.

**Pros**:
- Very explicit workflow
- Each step has clear start/complete

**Cons**:
- Significantly more steps
- May be overkill

### Option D: Keep Engine Pure, Add Movement Helper Module

Keep engine as pure state machine, add optional movement helper:

```zig
// Separate module
const movement = @import("labelle-tasks").movement;

// Game creates movement tracker
var tracker = movement.Tracker.init(allocator);

// When worker assigned, game registers movement
tracker.startMovement(worker_id, target_position);

// Game updates each frame
tracker.update(dt);

// Tracker emits hooks when movement complete
// Game then calls engine.handle(.{ .pickup_completed = ... })
```

**Pros**:
- No changes to core engine
- Optional for games that want it
- Keeps engine pure

**Cons**:
- Two systems to coordinate
- Movement state not visible in engine

## New Hooks (for Options A, B, or C)

```zig
// Engine → Game
movement_started: struct {
    worker_id: GameId,
    target_type: enum { workstation, storage },
    target_id: GameId,
},
movement_completed: struct {
    worker_id: GameId,
},

// Game → Engine
arrival_completed: struct {
    worker_id: GameId,
},
```

## Chosen Approach

After discussion, we chose a simplified version of Option A:

### Worker Substate

```zig
pub const MovingTo = struct {
    target: GameId,      // Entity ID worker is moving towards
    target_type: TargetType,
};

pub const TargetType = enum {
    workstation,
    storage,
    dangling_item,
};
```

### Workflow

```
1. Worker Idle, Workstation Queued
2. worker_available → tryAssignWorkers()
3. assignWorkerToWorkstation():
   - Worker.state = Working
   - Worker.moving_to = { target: workstation_id, target_type: .workstation }
   - Emit: worker_assigned, movement_started { worker_id, target, target_type }
4. Game: Animate movement to workstation
5. Game: engine.handle(.{ .worker_arrived = { .worker_id } })
6. Worker.moving_to = null
7. Emit: worker_arrived
8. startPickupStep():
   - Worker.moving_to = { target: eis_id, target_type: .storage }
   - Emit: pickup_started { worker_id, storage_id, item }
9. Game: Animate movement to EIS
10. Game: engine.handle(.{ .worker_arrived = { .worker_id } })
11. Emit: worker_arrived
12. completePickupStep():
    - Move item EIS → IIS
    - Emit: process_started
... etc
```

### Key Points

1. **Single substate**: `moving_to: ?MovingTo` tracks current movement target
2. **Generic arrival handler**: `worker_arrived` works for all movement types
3. **Engine tracks target**: Knows where worker is heading
4. **Backward compatible**: Games can ignore movement if they want instant behavior

### New Hooks

```zig
// Engine → Game
movement_started: struct {
    worker_id: GameId,
    target: GameId,
    target_type: TargetType,
},

// Game → Engine
worker_arrived: struct {
    worker_id: GameId,
},
```

---

## Questions for Discussion

1. **Which option do you prefer?** A (substates), B (expanded states), C (steps), or D (helper)?

2. **Should movement be optional?** Some games may want instant assignment (strategy games) while others need movement (colony sims).

3. **What about movement to multiple storages?** A workstation might have multiple EIS - should worker move to each?

4. **Should we track movement target?** Currently engine doesn't track positions. Should it track "worker is moving to storage X"?

5. **Distance/pathfinding integration?** The engine has an optional distance function. Should movement integrate with this?

## Migration Path

If we choose a breaking change (Option B or C):

1. Add new states/steps
2. Provide migration guide
3. Consider compatibility mode for existing games

---

## Workstation States

A workstation has three possible states:

```zig
pub const WorkstationStatus = enum {
    Blocked,  // Cannot operate - conditions not met
    Queued,   // Ready for worker assignment
    Active,   // Worker assigned and working
};
```

### State Definitions

| State | Description | Worker |
|-------|-------------|--------|
| **Blocked** | Workstation cannot operate. Missing inputs, outputs full, or no matching ingredients available. | None |
| **Queued** | Workstation ready to operate. At least one assignment condition is met. Waiting for worker. | None |
| **Active** | Worker assigned and executing workflow (Pickup → Process → Store). | Assigned |

### State Transition Diagram

```
                    ┌────────────────────────────────────────────┐
                    │                                            │
                    ▼                                            │
┌─────────────────────────────────────────────────────────────┐  │
│                        BLOCKED                               │  │
│                                                              │  │
│  Storage conditions NOT met:                                 │  │
│  - No IOS items AND no IIS filled AND no matching EIS       │  │
│  - OR: IOS has items but EOS is full                        │  │
│  - OR: IIS needs items but no matching EIS available        │  │
└─────────────────────────────────────────────────────────────┘  │
                    │                                            │
                    │ Any condition becomes true                 │
                    │ (storage state changes)                    │
                    ▼                                            │
┌─────────────────────────────────────────────────────────────┐  │
│                        QUEUED                                │  │
│                                                              │  │
│  At least ONE condition met:                                 │  │
│  1. FLUSH: IOS has item AND EOS has space                   │  │
│  2. PRODUCE: All IIS filled AND all IOS empty               │  │
│  3. CAN GET ITEMS: Matching EIS for each empty IIS          │  │
└─────────────────────────────────────────────────────────────┘  │
                    │                                            │
                    │ Worker assigned                            │
                    │ (tryAssignWorkers)                         │
                    ▼                                            │
┌─────────────────────────────────────────────────────────────┐  │
│                        ACTIVE                                │  │
│                                                              │  │
│  Worker executing workflow:                                  │  │
│  - Pickup: EIS → IIS                                        │  │
│  - Process: IIS → IOS                                       │  │
│  - Store: IOS → EOS                                         │  │
└─────────────────────────────────────────────────────────────┘  │
                    │                                            │
                    │ Cycle complete OR                          │
                    │ Worker released (blocked mid-cycle)        │
                    │                                            │
                    └────────────────────────────────────────────┘
                         (re-evaluate conditions)
```

### Storage Events That Trigger Re-evaluation

The workstation status is re-evaluated when storage state changes:

| Event | Effect | May Transition |
|-------|--------|----------------|
| `item_added` to EIS | New ingredient available | Blocked → Queued |
| `item_removed` from EIS | Ingredient consumed | Queued → Blocked |
| `item_added` to EOS | Output slot filled | Queued → Blocked (if all EOS full) |
| `item_removed` from EOS | Output slot freed | Blocked → Queued |
| `store_completed` | IOS → EOS transfer | Active → Queued/Blocked |
| `pickup_completed` | EIS → IIS transfer | (stays Active) |
| `work_completed` | IIS → IOS transform | (stays Active) |
| `cycle_completed` | Full cycle done | Active → Queued/Blocked |

### Example: Kitchen State Transitions

```
Initial State:
  EIS: [Vegetable, Meat]
  IIS: [empty, empty]
  IOS: [empty]
  EOS: [empty, empty]

  Check: Condition 3 (CAN GET ITEMS) ✓
  Status: QUEUED

Worker Assigned:
  Status: ACTIVE
  Worker moves to workstation...

After Pickup (EIS → IIS):
  EIS: [empty, empty]      ← items consumed
  IIS: [Vegetable, Meat]   ← items received
  IOS: [empty]
  EOS: [empty, empty]

  Status: ACTIVE (still working)

After Process (IIS → IOS):
  EIS: [empty, empty]
  IIS: [empty, empty]      ← items transformed
  IOS: [Meal]              ← output produced
  EOS: [empty, empty]

  Status: ACTIVE (still working)

After Store (IOS → EOS):
  EIS: [empty, empty]
  IIS: [empty, empty]
  IOS: [empty]             ← item moved
  EOS: [Meal, empty]       ← item stored

  Cycle Complete!
  Worker Released.

  Re-evaluate:
  - Condition 1: IOS empty → NO
  - Condition 2: IIS empty → NO
  - Condition 3: No EIS items → NO

  Status: BLOCKED (waiting for new ingredients)

New Ingredients Added:
  EIS: [Vegetable, Meat]   ← player/game adds items

  Re-evaluate:
  - Condition 3: Matching EIS ✓

  Status: QUEUED (ready for next cycle)
```

---

## Workstation Assignment Rules

A workstation can receive a worker (transition from `Blocked` → `Queued`) when **any** of the following conditions is true:

### Condition 1: FLUSH (Clear Leftover Items)

```
At least one IOS has item AND at least one EOS is empty
```

**Purpose**: Clear leftover items from an interrupted cycle before starting a new one.

**Example**:
```
IOS: [Bread, null]  → has item
EOS: [null, null]   → has space
Result: CAN ASSIGN (worker will store Bread to EOS)
```

### Condition 2: PRODUCE (Ready to Process)

```
All IIS have items AND all IOS are empty
```

**Purpose**: All inputs are ready, no leftover outputs blocking - can start processing immediately.

**Example**:
```
IIS: [Flour, Water]  → all filled
IOS: [null]          → all empty
Result: CAN ASSIGN (worker will start process_started)
```

### Condition 3: CAN GET ITEMS (Fill from Pantry/Storage)

```
For each empty IIS, there exists an EIS with matching item type
(counting duplicates - need one EIS per empty IIS slot)
```

**Purpose**: The required ingredients are available in external storage to fill the workstation inputs.

**Matching Algorithm**:
1. Count empty IIS slots grouped by `accepts` type
2. Count EIS slots grouped by `item_type`
3. For each required item type: `EIS_count >= empty_IIS_count`

**Example 1 - Simple match**:
```
IIS: [accepts: Potato (empty), accepts: Water (empty)]
EIS: [item: Potato, item: Water, item: Flour]

Required: {Potato: 1, Water: 1}
Available: {Potato: 1, Water: 1, Flour: 1}
Result: CAN ASSIGN
```

**Example 2 - Multiple same type**:
```
IIS: [accepts: Potato (empty), accepts: Potato (empty)]
EIS: [item: Potato, item: Potato]

Required: {Potato: 2}
Available: {Potato: 2}
Result: CAN ASSIGN (worker makes 2 trips)
```

**Example 3 - Insufficient count**:
```
IIS: [accepts: Potato (empty), accepts: Potato (empty)]
EIS: [item: Potato]

Required: {Potato: 2}
Available: {Potato: 1}
Result: CANNOT ASSIGN (need 2 Potatoes, only have 1)
```

**Example 4 - Partially filled IIS**:
```
IIS: [accepts: Potato (has Potato), accepts: Water (empty)]
EIS: [item: Water]

Required: {Water: 1}  ← only check empty slots
Available: {Water: 1}
Result: CAN ASSIGN
```

**Counter-example - Missing ingredient**:
```
IIS: [accepts: Potato (empty), accepts: Butter (empty)]
EIS: [item: Potato, item: Water]

Required: {Potato: 1, Butter: 1}
Available: {Potato: 1, Water: 1}
Result: CANNOT ASSIGN (no Butter available)
```

### Important Constraints

1. **IIS.accepts must never be null**: Each IIS must specify what item type it accepts. If `IIS.accepts == null`, the engine should throw an error. Think of IIS as recipe slots - they must define what ingredient they need.

2. **EIS.item_type can be null**: An empty EIS has no item_type.

3. **Conditions are evaluated as OR**: If ANY condition is true, the workstation is operable.

### Producer Workstations

A **producer** is a workstation with no external inputs - it generates items from nothing.

**Definition**:
```zig
pub fn isProducer(self: *const Self) bool {
    return self.eis.len == 0 and self.iis.len == 0;
}
```

**Examples**: Well (produces Water), Mine (produces Ore), Tree (produces Wood)

**Configuration**:
```
EIS: 0 (none)
IIS: 0 (none)
IOS: 1+ (produced items)
EOS: 1+ (storage for produced items)
```

**How Conditions Apply to Producers**:

| Condition | Evaluation for Producer |
|-----------|------------------------|
| 1. FLUSH | Normal - IOS has item AND EOS has space |
| 2. PRODUCE | "All IIS filled" is **vacuously true** (no IIS to check) |
| 3. CAN GET ITEMS | **N/A** - no IIS means nothing to fill |

**Assignment Check Example (Well)**:
```
IOS: [empty]
EOS: [empty, empty, empty, empty]

Condition 1 (FLUSH): IOS has item? No → Continue
Condition 2 (PRODUCE):
  - All IIS filled? Yes (vacuously true - no IIS)
  - All IOS empty? Yes
  → QUEUED ✓
```

**After Production**:
```
IOS: [Water]
EOS: [empty, empty, empty, empty]

Condition 1 (FLUSH):
  - IOS has item? Yes (Water)
  - EOS has space? Yes
  → QUEUED ✓ (Store water to EOS)
```

**Producer Workflow**:
```
1. Worker assigned → moves to workstation
2. Check IOS → empty → Start Process (produce item)
3. work_completed → IOS now has item
4. Check IOS → has item → Store to EOS
5. Cycle complete → worker released
```

**Key Insight**: Producers skip Condition 3 entirely. They only need:
- Empty IOS to produce (Condition 2)
- EOS space to store produced items (Condition 1)

### Decision Flow Diagram

```
┌─────────────────────────────────────┐
│   Can Workstation Receive Worker?   │
└─────────────────────────────────────┘
                  │
                  ▼
    ┌─────────────────────────────┐
    │  Condition 1: FLUSH         │
    │  IOS has item AND           │
    │  EOS has space?             │
    └─────────────────────────────┘
           │ YES              │ NO
           ▼                  ▼
     ┌─────────┐    ┌─────────────────────────────┐
     │ QUEUED  │    │  Condition 2: PRODUCE       │
     └─────────┘    │  All IIS filled AND         │
                    │  All IOS empty?             │
                    └─────────────────────────────┘
                           │ YES              │ NO
                           ▼                  ▼
                     ┌─────────┐    ┌─────────────────────────────┐
                     │ QUEUED  │    │  Condition 3: CAN GET ITEMS │
                     └─────────┘    │  For each empty IIS,        │
                                    │  exists EIS with matching   │
                                    │  item_type?                 │
                                    └─────────────────────────────┘
                                           │ YES              │ NO
                                           ▼                  ▼
                                     ┌─────────┐        ┌─────────┐
                                     │ QUEUED  │        │ BLOCKED │
                                     └─────────┘        └─────────┘
```

### Priority Order (On Worker Arrival)

When a worker arrives at a workstation, the engine handles conditions in priority order:

| Priority | Condition | Action |
|----------|-----------|--------|
| 1 | IOS has items | Store to EOS (FLUSH) |
| 2 | All IIS filled | Start processing (PRODUCE) |
| 3 | IIS needs items | Pickup from EIS (CAN GET ITEMS) |

### Resolved Questions

1. **Multiple IIS needing same item type**: Need **multiple EIS** with the same item type. Worker makes multiple trips, one EIS per IIS slot.

   **Example**:
   ```
   IIS: [accepts: Potato (empty), accepts: Potato (empty)]
   EIS: [item: Potato, item: Potato, item: Flour]
   Result: CAN ASSIGN (worker trips: EIS[0]→IIS[0], EIS[1]→IIS[1])

   EIS: [item: Potato, item: Flour]
   Result: CANNOT ASSIGN (only one Potato, need two)
   ```

2. **Partial matching**: **Full match required** for initial assignment. All empty IIS slots must have a matching EIS available. Exception: if IIS is already partially filled (some slots have items), only check the empty slots.

   **Example**:
   ```
   IIS: [accepts: Potato (has Potato), accepts: Water (empty)]
   EIS: [item: Water]
   Result: CAN ASSIGN (only need Water, Potato already present)

   IIS: [accepts: Potato (empty), accepts: Water (empty)]
   EIS: [item: Water]
   Result: CANNOT ASSIGN (need both Potato and Water)
   ```

3. **EIS selection strategy**: **Priority-based**. Select EIS with the **lowest priority value first** (lower = higher priority). When priorities are equal, use first available.

   **Example**:
   ```
   EIS: [item: Potato, priority: 2], [item: Potato, priority: 1]
   Worker picks from: EIS[1] (priority 1 < priority 2)
   ```

4. **Partially filled IIS**: **Only check empty IIS slots** for Condition 3. If some IIS already have items, those are satisfied and don't need EIS matching.

## References

- Current workflow: `src/handlers.zig`, `src/helpers.zig`
- Worker states: `src/types.zig`
- Hook system: `src/hooks.zig`
