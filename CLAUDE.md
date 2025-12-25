# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**labelle-tasks** is a self-contained task orchestration engine for Zig games. It manages worker assignment, task progression, and workstation workflows without requiring an external ECS dependency.

**Purpose**: Enable games to coordinate multi-step tasks (cooking, crafting, farming) where workers are assigned to workstations with predefined workflows. The engine handles state management and progression; games provide callbacks for game-specific logic (pathfinding, animations, entity management).

## Build Commands

```bash
# Run unit tests (zspec BDD-style tests)
zig build test

# Run individual examples
zig build simple        # Priority-based workstation selection
zig build kitchen       # Multi-step workflow with priority
zig build abandonment   # Worker abandonment with step preservation
zig build multicycle    # Multi-cycle workflows with shouldContinue
zig build hooks         # Hook-based event observation
zig build multiworker   # Multi-worker on multiple workstations

# Run all examples
zig build examples
```

## Architecture

### Core Concept

The engine is **callback-driven** and **self-contained**:
- Games register workers and workstations with entity IDs
- Engine tracks internal state (worker states, workstation status, step progress)
- Games control execution via callbacks, notifying engine of events (step complete, worker idle)
- Engine calls callbacks to trigger game-side logic (movement, animation)

### Key Design Principles

1. **Generic over entity ID type** - `Engine(u32)`, `Engine(u64)`, or custom types
2. **Step preservation** - When workers abandon work, step progress is kept for resumption
3. **Workstations cycle indefinitely** - Not one-off tasks but ongoing workflows
4. **Priority-based selection** - Higher priority queued workstations get workers first
5. **No ECS dependency** - Engine manages state; games integrate with their own ECS if desired

### Core Types

**Worker States**: `.Idle`, `.Working`, `.Blocked`

**Workstation Status**: `.Blocked`, `.Queued`, `.Active`

**Step Types**: `.Pickup`, `.Cook`, `.Store`, `.Craft`

### Main Files

- `src/root.zig` - Public API exports (Priority, StepType, StepDef, Engine type)
- `src/engine.zig` - Core Engine implementation (~600 lines)

### Callback System

Five callback types (all optional):

```zig
FindBestWorkerFn: fn(workstation_id, step, available_workers) ?GameId
OnStepStartedFn: fn(worker_id, workstation_id, step) void
OnStepCompletedFn: fn(worker_id, workstation_id, step) void
OnWorkerReleasedFn: fn(worker_id, workstation_id) void
ShouldContinueFn: fn(workstation_id, worker_id, cycles_completed) bool
```

### Event Notification Pattern

Games notify engine via methods:
- `notifyResourcesAvailable(workstation_id)` - Triggers Blocked→Queued→Active transition
- `notifyStepComplete(worker_id)` - Advances to next step or triggers cycle completion
- `notifyWorkerIdle(worker_id)` - Makes available for assignment
- `notifyWorkerBusy(worker_id)` - Marks blocked (preserves step progress)
- `abandonWork(worker_id)` - Worker leaves (preserves step progress)

### Hook System

In addition to callbacks, labelle-tasks provides a hook system compatible with labelle-engine. Hooks allow observing engine events without modifying engine behavior.

**Hook Types:**
- `step_started`, `step_completed` - Step lifecycle
- `worker_assigned`, `worker_released` - Worker lifecycle
- `workstation_blocked`, `workstation_queued`, `workstation_activated` - Workstation status
- `cycle_completed` - Cycle lifecycle

**Using Hooks:**
```zig
const MyTaskHooks = struct {
    pub fn step_completed(payload: tasks.hooks.HookPayload(u32)) void {
        const info = payload.step_completed;
        std.log.info("Step completed!", .{});
    }
};

const Dispatcher = tasks.hooks.HookDispatcher(u32, MyTaskHooks);
var engine = tasks.EngineWithHooks(u32, Dispatcher).init(allocator);
```

## Usage Pattern

```zig
// 1. Initialize
var engine = tasks.Engine(u32).init(allocator);
defer engine.deinit();

// 2. Register callbacks
engine.setFindBestWorker(findBestWorkerFn);
engine.setOnStepStarted(onStepStartedFn);
engine.setOnStepCompleted(onStepCompletedFn);

// 3. Register game entities
engine.addWorker(chef_id, .{});
engine.addWorkstation(stove_id, .{
    .steps = &cooking_steps,
    .priority = .High,
});

// 4. Game events trigger engine state changes
engine.notifyResourcesAvailable(stove_id);
engine.notifyStepComplete(chef_id);
engine.notifyWorkerIdle(chef_id);
```

## Testing

Tests use **zspec** (BDD-style):
- `test/engine_spec.zig` - Core behavior tests
- `test/priority_spec.zig` - Priority selection tests

Run with: `zig build test`

## Technology Stack

- **Language**: Zig 0.15+
- **Build System**: Zig build system (`build.zig`)
- **Testing**: zspec (BDD-style test runner)

## Documentation

- **README.md** - High-level overview, concepts, API documentation
- **uml/** - Visual diagrams (component, lifecycle, workflows)
- **usage/** - Runnable examples demonstrating features
