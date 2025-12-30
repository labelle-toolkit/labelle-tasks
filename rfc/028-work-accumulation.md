# RFC 028: Work Completion Model

**Status**: Draft
**Issue**: TBD
**Author**: @alexandrecalvao
**Created**: 2025-12-28
**Updated**: 2025-12-29
**Related**: [RFC 027: Engine-to-Tasks Communication](./027-engine-to-tasks-communication.md), [RFC 029: Task Engine as Pure State Machine](./029-engine-actions-api.md)

## Summary

Define how the game notifies the task engine that work is complete. The task engine updates its **abstract state** (IIS cleared, IOS populated) and emits hooks. The **game** handles actual entity transformation (destroy input prefabs, create output prefabs) in response to hooks.

## Motivation

labelle-tasks is purely event-driven with no internal timers or state duplication. The game is the single source of truth for:

- How long work takes (required time)
- How much work has been done (accumulated time)
- When work is complete

The task engine only needs to know **when** work is complete, not track progress.

## Design Principle: Single Source of Truth

```
┌─────────────────────────────────────┐
│              Game                    │
│  (Concrete State)                    │
│  - required_work: 5.0 seconds       │
│  - accumulated_work: 0.0            │
│  - tracks progress                   │
│  - shows progress bar                │
│  - decides when complete             │
│  - owns entity lifecycle             │
└──────────────────┬──────────────────┘
                   │
                   │ work_completed(workstation_id)
                   ▼
┌─────────────────────────────────────┐
│          Task Engine                 │
│  (Abstract State Only)               │
│  - receives notification             │
│  - updates abstract state:           │
│      IIS: has_item = false           │
│      IOS: has_item = true            │
│  - advances to Store step            │
│  - emits process_completed hook      │
│  - emits store_started hook          │
│  - NEVER touches game entities       │
└─────────────────────────────────────┘
                   │
                   │ process_completed hook
                   ▼
┌─────────────────────────────────────┐
│              Game                    │
│  (Reacts to Hook)                    │
│  - destroys input entity prefabs     │
│  - creates output entity prefabs     │
│  - starts worker movement to EOS     │
└─────────────────────────────────────┘
```

**No duplicated state.** Task engine doesn't track work progress or entity references. Game handles all entity lifecycle.

## GameHook: `work_completed`

Called by game when processing work is complete:

```zig
// In GameHookPayload
work_completed: struct {
    workstation_id: GameId,
},
```

**Game usage:**
```zig
// Game tracks work internally
const WorkProgress = struct {
    workstation_id: u32,
    required: f32,
    accumulated: f32 = 0,
};

fn update(delta_time: f32) void {
    for (work_in_progress.items) |*progress| {
        progress.accumulated += delta_time;

        if (progress.accumulated >= progress.required) {
            // Notify task engine
            _ = engine.handle(.{ .work_completed = .{
                .workstation_id = progress.workstation_id,
            }});
            work_in_progress.remove(progress);
        }
    }
}
```

## Task Engine Handler

The task engine only updates **abstract state** - it never touches game entities:

```zig
fn handleWorkCompleted(self: *Self, workstation_id: GameId) bool {
    const ws = self.workstations.getPtr(workstation_id) orelse {
        log.err("work_completed: unknown workstation {}", .{workstation_id});
        return false;
    };

    // Must be in Process step
    if (ws.current_step != .Process) {
        log.err("work_completed: workstation {} not in Process step", .{workstation_id});
        return false;
    }

    // Must have assigned worker
    const worker_id = ws.assigned_worker orelse {
        log.err("work_completed: workstation {} has no assigned worker", .{workstation_id});
        return false;
    };

    // Update ABSTRACT state only (no entity manipulation)
    // Clear IIS abstract state
    for (self.getIisStorages(workstation_id)) |iis_id| {
        const storage = self.storages.getPtr(iis_id);
        storage.has_item = false;
        storage.item_type = null;
    }
    // Populate IOS abstract state
    for (self.getIosStorages(workstation_id)) |ios_id| {
        const storage = self.storages.getPtr(ios_id);
        storage.has_item = true;
        storage.item_type = self.getOutputItemType(workstation_id);
    }

    // Emit process_completed hook - game reacts by doing entity transformation
    self.dispatchHook(.{ .process_completed = .{
        .workstation_id = workstation_id,
        .worker_id = worker_id,
    }});

    // Advance to Store step
    ws.current_step = .Store;

    // Notify game to start store movement
    self.dispatchHook(.{ .store_started = .{
        .worker_id = worker_id,
        .storage_id = self.selectEos(workstation_id),
    }});

    return true;
}
```

**Note**: The task engine updates `has_item` and `item_type` flags. The game, upon receiving `process_completed`, destroys input entity prefabs and creates output entity prefabs.

## Sequence Diagram

```
Game                              Task Engine
  │                                    │
  │  (worker arrives at workstation)   │
  │──pickup_completed(worker)─────────>│
  │                                    │
  │<─────────────process_started───────│  "start processing"
  │                                    │
  │  Game: start timer/animation       │
  │  Game: accumulate work             │
  │  Game: show progress bar           │
  │  Game: when done...                │
  │                                    │
  │──work_completed(workstation)──────>│
  │                                    │  Updates abstract state:
  │                                    │    IIS.has_item = false
  │                                    │    IOS.has_item = true
  │<─────────────process_completed─────│  "processing done"
  │                                    │
  │  Game: destroy input entities      │
  │  Game: create output entities      │
  │                                    │
  │<─────────────store_started─────────│  "go store at EOS"
  │                                    │
  │  Game: move worker to EOS          │
  │──store_completed(worker)──────────>│
  │                                    │  Updates abstract state:
  │                                    │    IOS.has_item = false
  │                                    │    EOS.has_item = true
  │<─────────────cycle_completed───────│  "cycle done!"
```

**Key insight**: Task engine emits `process_completed` and `store_started` hooks. Game reacts to `process_completed` by handling entity transformation. Task engine never manipulates game entities.

## Edge Cases

### Worker Interrupted Mid-Work

If worker is pulled away before work completes:

```zig
engine.handle(.{ .worker_unavailable = .{ .worker_id = worker_id } });
```

**Game responsibility:**
- Pause or continue tracking work progress (game decides)
- Keep accumulated work for when worker returns
- When new worker assigned and work resumes, continue from where left off

**Task engine:**
- Unassigns worker from workstation
- Workstation goes to Queued status
- Waits for new worker assignment
- Does NOT reset any work state (because it doesn't track any)

### Workstation Configuration

Where does `required_work` live?

**Option A: Game only (recommended)**
```zig
// Game knows recipe requirements
const recipes = .{
    .kitchen = .{ .required_work = 5.0 },
    .well = .{ .required_work = 2.0 },
};
```

**Option B: Task engine stores but doesn't use**
```zig
// Task engine stores for reference, but game still decides when done
const WorkstationConfig = struct {
    required_work: f32,  // Informational only
};
```

**Recommendation:** Option A. Task engine doesn't need this information.

### Progress Query

If UI needs progress, game provides it:

```zig
// Game API
pub fn getWorkProgress(workstation_id: u32) f32 {
    const progress = work_in_progress.get(workstation_id) orelse return 0;
    return progress.accumulated / progress.required;
}
```

Task engine has no progress information - it's not its responsibility.

## What Task Engine Tracks

For the Process step, task engine only tracks:

```zig
const WorkstationState = struct {
    current_step: Step,        // .Process during work
    assigned_worker: ?GameId,  // Who is working
    // NO accumulated_work
    // NO required_work
};
```

## Comparison with Previous Design

| Aspect | Previous (RFC draft) | Current |
|--------|---------------------|---------|
| Work tracking | Task engine | Game only |
| required_work | Task engine | Game only |
| accumulated_work | Task engine | Game only |
| Progress query | Task engine | Game |
| Hook frequency | Every frame | Once when done |
| Transformation trigger | Task engine decides | Game decides |

## Benefits

1. **Single source of truth** - No state duplication
2. **Simpler task engine** - Less state to manage
3. **Game flexibility** - Game controls timing completely
4. **Less coupling** - Task engine doesn't need recipe timings
5. **Fewer hooks** - One `work_completed` vs many `work(dt)`

## Summary

| Responsibility | Owner | Details |
|----------------|-------|---------|
| Track work progress | Game | `accumulated_work`, `required_work` |
| Know required time | Game | Recipe data, configuration |
| Show progress UI | Game | Progress bars, animations |
| Decide when complete | Game | Calls `work_completed` |
| Update abstract state | Task Engine | `has_item`, `item_type` flags |
| Advance workflow | Task Engine | `current_step` transitions |
| Emit hooks | Task Engine | `process_completed`, `store_started` |
| Destroy input entities | Game | Reacts to `process_completed` hook |
| Create output entities | Game | Reacts to `process_completed` hook |
| Move worker | Game | Reacts to `store_started` hook |

### Key Principle

**Task engine is a pure state machine.** It tracks abstract workflow state and emits hooks. The game owns all entity lifecycle and reacts to hooks by manipulating its own ECS state.

## References

- [RFC 027: Engine-to-Tasks Communication](./027-engine-to-tasks-communication.md)
- [RFC 029: Task Engine as Pure State Machine](./029-engine-actions-api.md)
