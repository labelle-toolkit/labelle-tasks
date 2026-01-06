# RFC 035: Worker Movement States

**Issue**: #35
**Status**: Draft
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

## References

- Current workflow: `src/handlers.zig`, `src/helpers.zig`
- Worker states: `src/types.zig`
- Hook system: `src/hooks.zig`
