# RFC 028: Work Accumulation Model

**Status**: Draft
**Issue**: TBD
**Author**: @alexandrecalvao
**Created**: 2025-12-28
**Related**: [RFC 027: Engine-to-Tasks Communication](./027-engine-to-tasks-communication.md)

## Summary

Define how work accumulation triggers the IIS → IOS transformation at workstations.

## Motivation

labelle-tasks is purely event-driven with no internal timers. The game controls all timing, including how long processing takes. This RFC defines the mechanism for:

1. Game reporting work progress to task engine
2. Task engine tracking accumulated work
3. Triggering transformation when work is complete
4. Notifying game that transformation occurred

## Design

### Work Flow

```
┌─────────────┐          ┌──────────────┐          ┌─────────────┐
│    Game     │          │ Task Engine  │          │    Game     │
│  (caller)   │          │  (internal)  │          │ (observer)  │
└──────┬──────┘          └──────┬───────┘          └──────┬──────┘
       │                        │                         │
       │  work(ws, dt)          │                         │
       │───────────────────────>│                         │
       │                        │ accumulated += dt       │
       │                        │                         │
       │  work(ws, dt)          │                         │
       │───────────────────────>│                         │
       │                        │ accumulated += dt       │
       │                        │                         │
       │  work(ws, dt)          │                         │
       │───────────────────────>│                         │
       │                        │ accumulated += dt       │
       │                        │                         │
       │                        │ if accumulated >= required:
       │                        │   transform IIS → IOS   │
       │                        │   emit work_completed ──────────>│
       │                        │   advance to Store step │
       │                        │                         │
```

### Workstation State

```zig
const WorkstationState = struct {
    // Configuration (set at creation)
    required_work: f32,  // e.g., 5.0 seconds

    // Runtime state
    accumulated_work: f32 = 0,
    current_step: Step = .Pickup,
    assigned_worker: ?GameId = null,

    // ... other fields
};
```

### GameHook: `work`

Called by game every frame while worker is processing:

```zig
// In GameHookPayload
work: struct {
    workstation_id: GameId,
    delta_time: f32,
},
```

**Usage:**
```zig
// Game loop
fn update(delta_time: f32) void {
    for (workers) |worker| {
        if (worker.state == .Processing) {
            _ = engine.work(worker.assigned_workstation, delta_time);
        }
    }
}
```

### Internal Handler

```zig
fn handleWork(self: *Self, workstation_id: GameId, delta_time: f32) bool {
    const ws = self.workstations.getPtr(workstation_id) orelse {
        log.err("work: unknown workstation {}", .{workstation_id});
        return false;
    };

    // Must be in Process step
    if (ws.current_step != .Process) {
        log.err("work: workstation {} not in Process step", .{workstation_id});
        return false;
    }

    // Must have assigned worker
    const worker_id = ws.assigned_worker orelse {
        log.err("work: workstation {} has no assigned worker", .{workstation_id});
        return false;
    };

    // Accumulate work
    ws.accumulated_work += delta_time;

    // Check if transformation should happen
    if (ws.accumulated_work >= ws.required_work) {
        self.completeWork(workstation_id, worker_id);
    }

    return true;
}

fn completeWork(self: *Self, workstation_id: GameId, worker_id: GameId) void {
    const ws = self.workstations.getPtr(workstation_id).?;

    // Transform IIS → IOS
    self.transformItems(workstation_id);

    // Reset for next cycle
    ws.accumulated_work = 0;

    // Advance to Store step
    ws.current_step = .Store;

    // Notify game
    self.dispatchHook(.{ .work_completed = .{
        .workstation_id = workstation_id,
        .worker_id = worker_id,
    }});

    // Also emit store_started
    self.dispatchHook(.{ .store_started = .{
        .worker_id = worker_id,
        .storage_id = self.selectEos(workstation_id),
    }});
}
```

### TaskHook: `work_completed`

Emitted when transformation completes:

```zig
// In TaskHookPayload
work_completed: struct {
    workstation_id: GameId,
    worker_id: GameId,
},
```

**Game receives:**
```zig
const MyTaskHooks = struct {
    pub fn work_completed(payload: TaskHookPayload(u32, Item)) void {
        const info = payload.work_completed;
        // Transformation done!
        // - IIS items consumed
        // - IOS items produced
        // - Worker should now move to EOS
        game.playSound("crafting_complete");
    }
};
```

## Edge Cases

### 1. Worker Interrupted Mid-Work

If worker is pulled away (e.g., player takes control):

```zig
// Game notifies worker is unavailable
engine.handle(.{ .worker_unavailable = .{ .worker_id = worker_id } });
```

Task engine should:
- Keep `accumulated_work` (work not lost)
- Unassign worker from workstation
- Workstation goes back to Queued status
- When new worker assigned, continues from accumulated work

**Or** reset accumulated work (configurable?):
```zig
const WorkstationConfig = struct {
    required_work: f32,
    reset_on_interrupt: bool = false,  // If true, lose progress when worker leaves
};
```

### 2. Multiple Workers at Same Workstation

Current design: one worker per workstation. If needed later:
- Multiple workers could contribute to same `accumulated_work`
- Would need `work` to include `worker_id` for tracking

### 3. Variable Work Rate

Worker efficiency could modify delta_time:

```zig
// Game applies worker efficiency
const effective_dt = delta_time * worker.efficiency;  // e.g., 1.5x faster
engine.work(workstation_id, effective_dt);
```

Task engine doesn't need to know about efficiency - just accumulates what it receives.

### 4. Work Progress Query

Game might want to show progress bar:

```zig
// Add query method
pub fn getWorkProgress(self: *Self, workstation_id: GameId) ?f32 {
    const ws = self.workstations.get(workstation_id) orelse return null;
    return ws.accumulated_work / ws.required_work;  // 0.0 to 1.0
}
```

## Alternatives Considered

### A: Process Timer in Task Engine

Task engine owns timer, game just calls `update(delta_time)`:

```zig
engine.update(delta_time);  // Advances all timers
```

**Rejected because:**
- Less control for game
- Can't have variable work rates per worker
- Mixes orchestration with timing

### B: Game Tells Task Engine "Work Done"

Game tracks time, calls when complete:

```zig
engine.handle(.{ .process_completed = .{ .worker_id = worker_id } });
```

**Rejected because:**
- Game must track required_work per workstation (duplicated knowledge)
- Task engine can't validate timing
- Harder to show progress

### C: Discrete Work Units

Game calls `addWork(amount)` instead of delta time:

```zig
engine.addWork(workstation_id, 1);  // Add 1 unit of work
```

**Could work, but:**
- Requires game to convert time → units
- Less intuitive than delta time
- Same result, more indirection

## Summary

| Aspect | Design |
|--------|--------|
| Who tracks time | Task engine (accumulated_work) |
| Who controls pace | Game (calls work every frame) |
| Who decides "done" | Task engine (accumulated >= required) |
| Who gets notified | Game (via work_completed hook) |
| Progress visibility | Query method: getWorkProgress() |

## References

- [RFC 027: Engine-to-Tasks Communication](./027-engine-to-tasks-communication.md)
- [RFC 026: Comptime Workstations](./026-comptime-workstations.md)
