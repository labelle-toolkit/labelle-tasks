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
- `priority: Priority` - Low/Normal/High/Critical

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

### Priority System

Storages and workstations support priority levels: `.Low`, `.Normal`, `.High`, `.Critical`.

- `selectEis` picks the highest-priority EIS with an item
- `selectEos` picks the highest-priority empty EOS
- `tryAssignWorkers` assigns idle workers to highest-priority queued workstations first

### State Ownership

| State | Owner |
|-------|-------|
| `has_item`, `item_type` | Task Engine |
| `current_step`, `assigned_worker` | Task Engine |
| `priority` (storage/workstation) | Task Engine |
| Entity references | Game |
| Work timers, progress | Game |
| Positions, sprites | Game |
| Prefab instances | Game |

### Main Files

- `src/root.zig` - Public API exports + `createEngineHooks`
- `src/engine.zig` - Core Engine struct, registration API, `handle()`, query/introspection API, status tracking sets, reverse index
- `src/handlers.zig` - Event handlers (game → engine), return `anyerror!void`
- `src/helpers.zig` - Internal helpers (evaluation, assignment, priority-based selection)
- `src/dangling.zig` - Dangling item management (evaluation, worker assignment, EIS lookup)
- `src/bridge.zig` - ECS bridge vtable implementations (type-erased function wrappers)
- `src/hooks.zig` - Hook payloads, dispatcher, `RecordingHooks` for testing
- `src/state.zig` - Internal state structs (StorageState, WorkerData, WorkstationData)
- `src/types.zig` - Core enums (WorkerState, WorkstationStatus, StepType, Priority)
- `src/context.zig` - `TaskEngineContextWith` (engine lifecycle + ECS integration)
- `src/ecs_bridge.zig` - Type-erased `EcsInterface` with vtable pattern
- `src/components.zig` - ECS components with auto-registration callbacks
- `src/logging_hooks.zig` - `LoggingHooks` + `MergeHooks` for hook composition

### Core Types

**Worker States**: `.Idle`, `.Working`, `.Unavailable`

**Workstation Status**: `.Blocked`, `.Queued`, `.Active`

**Step Types**: `.Pickup`, `.Process`, `.Store`

**Priority**: `.Low`, `.Normal`, `.High`, `.Critical` (u8: 0-3)

### Hook Types (Tasks → Game)

- `pickup_started`, `process_started`, `process_completed`, `store_started` - Step lifecycle
- `worker_assigned`, `worker_released` - Worker lifecycle
- `workstation_blocked`, `workstation_queued`, `workstation_activated` - Workstation status
- `cycle_completed` - Cycle lifecycle
- `transport_started`, `transport_completed` - Transport lifecycle
- `pickup_dangling_started`, `item_delivered` - Dangling item lifecycle
- `input_consumed` - IIS item consumed during processing

### GameHook Types (Game → Tasks)

- `item_added`, `item_removed`, `storage_cleared` - Storage changes
- `worker_available`, `worker_unavailable`, `worker_removed` - Worker changes
- `workstation_enabled`, `workstation_disabled`, `workstation_removed` - Workstation changes
- `pickup_completed`, `work_completed`, `store_completed` - Step completion

### Key Internal Patterns

- **Reverse index**: `storage_to_workstations` map enables `reevaluateAffectedWorkstations()` for targeted re-evaluation instead of scanning all workstations
- **Status tracking sets**: `idle_workers_set` and `queued_workstations_set` provide O(1) lookups
- **Snapshot-based assignment**: `tryAssignWorkers` snapshots sets into local buffers to avoid reentrancy issues during hook dispatch
- **Error unions**: Internal handlers return `anyerror!void`; `engine.handle()` catches and returns `bool`

## Usage Pattern

```zig
const tasks = @import("labelle-tasks");
const Item = enum { Flour, Bread };

// Define hooks (2-param with self or 1-param static)
const MyHooks = struct {
    pub fn process_completed(payload: anytype) void {
        // payload.workstation_id, payload.worker_id
    }
    pub fn store_started(payload: anytype) void {
        // payload.worker_id, payload.storage_id, payload.item
    }
};

// Create engine
var engine = tasks.Engine(u32, Item, MyHooks).init(allocator, .{}, null);
defer engine.deinit();

// Register entities
try engine.addStorage(eis_id, .{ .role = .eis, .initial_item = .Flour, .priority = .High });
try engine.addStorage(iis_id, .{ .role = .iis });
try engine.addStorage(ios_id, .{ .role = .ios });
try engine.addStorage(eos_id, .{ .role = .eos });

try engine.addWorkstation(ws_id, .{
    .eis = &.{eis_id},
    .iis = &.{iis_id},
    .ios = &.{ios_id},
    .eos = &.{eos_id},
    .priority = .Normal,
});

try engine.addWorker(worker_id);

// Game notifies engine of events
_ = engine.handle(.{ .worker_available = .{ .worker_id = worker_id } });
_ = engine.handle(.{ .pickup_completed = .{ .worker_id = worker_id } });
_ = engine.handle(.{ .work_completed = .{ .workstation_id = ws_id } });
_ = engine.handle(.{ .store_completed = .{ .worker_id = worker_id } });
```

## Testing

Tests use the **zspec** BDD framework in `test/` directory:
- `test/root.zig` - Test root, aggregates all specs
- `test/engine_spec.zig` - Engine workflow tests (priority, lifecycle, dangling items)
- `test/hooks_spec.zig` - Hook dispatcher tests

`RecordingHooks(GameId, Item)` enables test assertions:
```zig
var recorder = RecordingHooks(u32, Item){};
recorder.init(allocator);
defer recorder.deinit();
// ... use recorder as TaskHooks ...
try recorder.expectNext(.pickup_started);
try recorder.expectEmpty();
```

Run with: `zig build test`

## Technology Stack

- **Language**: Zig 0.15+
- **Build System**: Zig build system (`build.zig`)
- **Testing**: zspec BDD framework

## labelle-engine Integration

For integration with labelle-engine, the library provides helpers:

- `createEngineHooks(GameId, Items, GameHooks, EngineTypes)` - Creates engine lifecycle hooks with enriched payloads
- `TaskEngineContextWith` - Context with injected engine types (avoids WASM module collision)
- `MergeHooks` - Combines two hook handler structs (Primary + Fallback)
- `LoggingHooks` - Default logging implementation for all hooks
- `bind(Items, EngineTypes)` - Returns parameterized component types for plugin integration
- `Registration` - Pure registration functions for unit testing without full ECS
- `EcsInterface` - Type-erased vtable interface for ECS bridge
- Auto-registering components: `Storage`, `Worker`, `Workstation`, `DanglingItem`
