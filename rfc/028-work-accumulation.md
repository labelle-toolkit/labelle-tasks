# RFC 028: Work Completion Model

**Status**: Draft
**Issue**: TBD
**Author**: @alexandrecalvao
**Created**: 2025-12-28
**Related**: [RFC 027: Engine-to-Tasks Communication](./027-engine-to-tasks-communication.md)

## Summary

Define how the game notifies the task engine that work is complete, triggering the IIS → IOS transformation.

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
│  - required_work: 5.0 seconds       │
│  - accumulated_work: 0.0            │
│  - tracks progress                   │
│  - shows progress bar                │
│  - decides when complete             │
└──────────────────┬──────────────────┘
                   │
                   │ work_completed(workstation_id)
                   ▼
┌─────────────────────────────────────┐
│          Task Engine                 │
│  - receives notification             │
│  - transforms IIS → IOS             │
│  - advances to Store step            │
│  - emits store_started hook          │
└─────────────────────────────────────┘
```

**No duplicated state.** Task engine doesn't track work progress.

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

    // Transform IIS → IOS
    self.transformItems(workstation_id);

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
  │                                    │  transform IIS → IOS
  │<─────────────store_started─────────│  "go store"
  │                                    │
  │  (worker moves to EOS)             │
  │──store_completed(worker)──────────>│
  │                                    │
  │<─────────────cycle_completed───────│  "done!"
```

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

| Responsibility | Owner |
|----------------|-------|
| Track work progress | Game |
| Know required time | Game |
| Show progress UI | Game |
| Decide when complete | Game |
| Do transformation | Task Engine |
| Advance workflow | Task Engine |
| Emit hooks | Task Engine |

## References

- [RFC 027: Engine-to-Tasks Communication](./027-engine-to-tasks-communication.md)
- [RFC 026: Comptime Workstations](./026-comptime-workstations.md)
