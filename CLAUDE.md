# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**labelle-tasks** is a pure state machine task orchestration engine for Zig games. It tracks abstract workflow state and emits hooks to notify the game of events, but never mutates game state directly.

**Purpose**: Enable games to coordinate multi-step tasks (cooking, crafting, farming) where workers move items between storages and process them at workstations.

**Key Principle**: The engine is a pure state machine. It tracks abstract state (has_item, item_type, current_step) and emits hooks. The game owns all entity lifecycle, timing, and ECS state.

## Build Commands

```bash
# Run unit tests
zig build test
```

## Architecture

### Pure State Machine

The engine tracks **abstract workflow state** only:
- `has_item: bool` - Does storage have an item?
- `item_type: ?Item` - What type of item?
- `current_step: StepType` - Pickup/Process/Store
- `assigned_worker: ?GameId` - Which worker is assigned?

The engine **never**:
- Holds entity references
- Manages timers or work progress
- Instantiates or destroys prefabs
- Accesses ECS components

### Communication

**Game → Tasks** (via `handle()`):
```zig
engine.handle(.{ .worker_available = .{ .worker_id = id } });
engine.handle(.{ .pickup_completed = .{ .worker_id = id } });
engine.handle(.{ .work_completed = .{ .workstation_id = id } });
engine.handle(.{ .store_completed = .{ .worker_id = id } });
```

**Tasks → Game** (via hooks):
```zig
const MyHooks = struct {
    pub fn process_completed(payload: anytype) void {
        // Game destroys input entities, creates output entities
    }
    pub fn store_started(payload: anytype) void {
        // Game starts worker movement animation
    }
};
```

### Storage-Based Workflow

Items flow through storages: `EIS → IIS (Pickup) → IOS (Process) → EOS (Store)`

- **EIS** (External Input Storage): Source of raw materials
- **IIS** (Internal Input Storage): Recipe inputs
- **IOS** (Internal Output Storage): Recipe outputs
- **EOS** (External Output Storage): Final products

Each storage holds **one item** (has_item: bool).

### State Ownership

| State | Owner |
|-------|-------|
| `has_item`, `item_type` | Task Engine |
| `current_step`, `assigned_worker` | Task Engine |
| Entity references | Game |
| Work timers, progress | Game |
| Positions, sprites | Game |
| Prefab instances | Game |

### Main Files

- `src/root.zig` - Public API exports
- `src/engine.zig` - Core Engine implementation
- `src/hooks.zig` - Hook payloads and dispatcher

### Core Types

**Worker States**: `.Idle`, `.Working`, `.Unavailable`

**Workstation Status**: `.Blocked`, `.Queued`, `.Active`

**Step Types**: `.Pickup`, `.Process`, `.Store`

### Hook Types (Tasks → Game)

- `pickup_started`, `process_started`, `process_completed`, `store_started` - Step lifecycle
- `worker_assigned`, `worker_released` - Worker lifecycle
- `workstation_blocked`, `workstation_queued`, `workstation_activated` - Workstation status
- `cycle_completed` - Cycle lifecycle
- `transport_started`, `transport_completed` - Transport lifecycle

### GameHook Types (Game → Tasks)

- `item_added`, `item_removed`, `storage_cleared` - Storage changes
- `worker_available`, `worker_unavailable`, `worker_removed` - Worker changes
- `workstation_enabled`, `workstation_disabled`, `workstation_removed` - Workstation changes
- `pickup_completed`, `work_completed`, `store_completed` - Step completion

## Usage Pattern

```zig
const tasks = @import("labelle-tasks");
const Item = enum { Flour, Bread };

// Define hooks to receive from task engine (pure functions)
const MyHooks = struct {
    pub fn process_completed(payload: anytype) void {
        // Game handles entity transformation
        // payload.workstation_id, payload.item, etc.
    }

    pub fn store_started(payload: anytype) void {
        // payload.worker_id, payload.storage_id
    }
};

// Create engine
var engine = tasks.Engine(u32, Item, MyHooks).init(allocator, .{});
defer engine.deinit();

// Register entities (just IDs - engine doesn't know about game's data)
try engine.addStorage(eis_id, .Flour);  // Has flour
try engine.addStorage(iis_id, null);     // Empty
try engine.addStorage(ios_id, null);     // Empty
try engine.addStorage(eos_id, null);     // Empty

try engine.addWorkstation(ws_id, .{
    .eis = &.{eis_id},
    .iis = &.{iis_id},
    .ios = &.{ios_id},
    .eos = &.{eos_id},
});

try engine.addWorker(worker_id);

// Game notifies engine of events
_ = engine.handle(.{ .worker_available = .{ .worker_id = worker_id } });
// Engine emits pickup_started hook → game starts movement

// When worker arrives at EIS...
_ = engine.handle(.{ .pickup_completed = .{ .worker_id = worker_id } });
// Engine emits process_started hook → game starts work timer

// When game's work timer completes...
_ = engine.handle(.{ .work_completed = .{ .workstation_id = ws_id } });
// Engine emits process_completed, store_started hooks
// Game destroys input entities, creates output entities, starts movement

// When worker arrives at EOS...
_ = engine.handle(.{ .store_completed = .{ .worker_id = worker_id } });
// Engine emits cycle_completed hook
```

## Testing

Tests are in the source files using Zig's built-in test framework.

Run with: `zig build test`

## Technology Stack

- **Language**: Zig 0.15+
- **Build System**: Zig build system (`build.zig`)

## labelle-engine Integration

For integration with labelle-engine, the library provides helpers:

- `createEngineHooks(GameId, Items, GameHooks)` - Creates engine lifecycle hooks
- `TaskEngineContext` - Pre-built context struct with allocator, task_engine, and game pointers
- `MergeHooks` - Combines multiple hook handler structs
- `LoggingHooks` - Default logging implementation for all hooks
- `bind(Items)` - Returns parameterized component types (Storage, Worker, Workstation)

See README.md for detailed integration examples.
