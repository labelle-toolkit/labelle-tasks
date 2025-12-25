# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**labelle-tasks** is a self-contained task orchestration engine for Zig games. It manages worker assignment, task progression, and workstation workflows with storage-based item management.

**Purpose**: Enable games to coordinate multi-step tasks (cooking, crafting, farming) where workers move items between storages and process them at workstations.

## Build Commands

```bash
# Run unit tests (zspec BDD-style tests)
zig build test

# Run individual examples
zig build kitchen-sim   # Interactive kitchen simulator
zig build components    # ECS component usage
zig build farm          # Full engine workflow
zig build hooks         # Hook-based event observation

# Run all examples
zig build examples
```

## Architecture

### Core Concept

The engine uses a **storage-based workflow**:
- **EIS** (External Input Storage): Source of raw materials
- **IIS** (Internal Input Storage): Recipe buffer (defines what items are needed)
- **IOS** (Internal Output Storage): Output buffer
- **EOS** (External Output Storage): Final product storage

Workflow: `EIS → IIS (Pickup) → IOS (Process) → EOS (Store)`

### Key Design Principles

1. **Generic over GameId and Item types** - `Engine(u32, MyItemEnum)`
2. **Storage-based workflow** - Items flow through defined storage paths
3. **Multiple EIS/EOS support** - Flexible input/output routing
4. **Transport tasks** - Recurring item movement between any storages
5. **Callback-driven** - Games control movement/animations

### Core Types

**Worker States**: `.Idle`, `.Working`, `.Blocked`

**Workstation Status**: `.Blocked`, `.Queued`, `.Active`

**Step Types**: `.Pickup`, `.Process`, `.Store`

### Main Files

- `src/root.zig` - Public API exports
- `src/engine.zig` - Core Engine and EngineWithHooks implementation
- `src/storage.zig` - Storage management
- `src/hooks.zig` - Hook system for event observation
- `src/log.zig` - Scoped logging utilities

### Callback System

Six callback types (all optional):

```zig
FindBestWorkerFn: fn(workstation_game_id: ?GameId, available_workers: []const GameId) ?GameId
OnPickupStartedFn: fn(worker_id, workstation_id, eis_id) void
OnProcessStartedFn: fn(worker_id, workstation_id) void
OnProcessCompleteFn: fn(worker_id, workstation_id) void
OnStoreStartedFn: fn(worker_id, workstation_id, eos_id) void
OnWorkerReleasedFn: fn(worker_id, workstation_id) void
OnTransportStartedFn: fn(worker_id, from_storage_id, to_storage_id, item) void
```

### Hook System

In addition to callbacks, labelle-tasks provides a hook system compatible with labelle-engine.

**Hook Types:**
- `pickup_started`, `process_started`, `process_completed`, `store_started` - Step lifecycle
- `worker_assigned`, `worker_released` - Worker lifecycle
- `workstation_blocked`, `workstation_queued`, `workstation_activated` - Workstation status
- `transport_started`, `transport_completed` - Transport lifecycle
- `cycle_completed` - Cycle lifecycle

**Using Hooks:**
```zig
const MyHooks = struct {
    pub fn cycle_completed(payload: tasks.hooks.HookPayload(u32, Item)) void {
        const info = payload.cycle_completed;
        std.log.info("Cycle {d} completed!", .{info.cycles_completed});
    }
};

const Dispatcher = tasks.hooks.HookDispatcher(u32, Item, MyHooks);
var engine = tasks.EngineWithHooks(u32, Item, Dispatcher).init(allocator);
```

## Usage Pattern

```zig
const Item = enum { Flour, Bread };
var engine = tasks.Engine(u32, Item).init(allocator);
defer engine.deinit();

// Create storages
_ = engine.addStorage(EIS_ID, .{ .slots = &.{.{ .item = .Flour, .capacity = 10 }} });
_ = engine.addStorage(IIS_ID, .{ .slots = &.{.{ .item = .Flour, .capacity = 1 }} });
_ = engine.addStorage(IOS_ID, .{ .slots = &.{.{ .item = .Bread, .capacity = 1 }} });
_ = engine.addStorage(EOS_ID, .{ .slots = &.{.{ .item = .Bread, .capacity = 5 }} });

// Create workstation
_ = engine.addWorkstation(BAKERY_ID, .{
    .eis = &.{EIS_ID},
    .iis = IIS_ID,
    .ios = IOS_ID,
    .eos = &.{EOS_ID},
    .process_duration = 3,
});

// Add worker and items
_ = engine.addWorker(BAKER_ID, .{});
_ = engine.addToStorage(EIS_ID, .Flour, 5);

// Game loop notifications
engine.notifyWorkerIdle(BAKER_ID);      // Worker available
engine.update();                         // Process timers
engine.notifyPickupComplete(BAKER_ID);   // Pickup done
engine.notifyStoreComplete(BAKER_ID);    // Store done
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
