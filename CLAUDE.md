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
- **IIS** (Internal Input Storage): Recipe input - each IIS defines one ingredient needed per cycle
- **IOS** (Internal Output Storage): Recipe output - each IOS defines one product per cycle
- **EOS** (External Output Storage): Final product storage

Each storage holds **one item type** (quantity 0 or 1 in single-item model).
For multi-item recipes, use multiple IIS storages (one for each unit of an ingredient required). For example, a recipe needing 2 Flour and 1 Meat would require three IIS storages: two for Flour and one for Meat.

Workflow: `EIS → IIS (Pickup) → IOS (Process) → EOS (Store)`

### Key Design Principles

1. **Generic over GameId, Item, and Dispatcher types** - `Engine(u32, MyItemEnum, MyDispatcher)`
2. **Storage-based workflow** - Items flow through defined storage paths
3. **Single-item storages** - Each storage holds one item type
4. **Multiple storage support** - All storage references are slices for flexible routing
5. **Transport tasks** - Recurring item movement between any storages
6. **Hook-driven** - Games receive events via comptime hooks with zero overhead

### Core Types

**Worker States**: `.Idle`, `.Working`, `.Blocked`

**Workstation Status**: `.Blocked`, `.Queued`, `.Active`

**Step Types**: `.Pickup`, `.Process`, `.Store`

### Main Files

- `src/root.zig` - Public API exports
- `src/engine.zig` - Core Engine implementation with hook support
- `src/storage.zig` - Storage management (item type definition only, quantities in engine)
- `src/hooks.zig` - Hook system for event observation
- `src/log.zig` - Scoped logging utilities

### Hook System

The engine uses a comptime hook system compatible with labelle-engine.

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

// Simplified API - auto-wraps HookDispatcher
var engine = tasks.EngineWithHooks(u32, Item, MyHooks).init(allocator);

// For an engine without hooks:
// var engine = tasks.EngineWithHooks(u32, Item, struct {}).init(allocator);
```

### FindBestWorker Callback

The only required callback selects which worker to assign:

```zig
engine.setFindBestWorker(fn(workstation_id: ?GameId, available_workers: []const GameId) ?GameId);
```

## Usage Pattern

```zig
const Item = enum { Flour, Bread };

// Define hooks (optional)
const MyHooks = struct {
    pub fn process_started(payload: tasks.hooks.HookPayload(u32, Item)) void {
        // Play animation, etc.
    }
};

// Create engine with hooks
var engine = tasks.EngineWithHooks(u32, Item, MyHooks).init(allocator);
defer engine.deinit();

engine.setFindBestWorker(findBestWorker);

// Create storages (each storage holds ONE item type)
_ = engine.addStorage(EIS_ID, .{ .item = .Flour });
_ = engine.addStorage(IIS_ID, .{ .item = .Flour });   // Recipe needs 1 flour
_ = engine.addStorage(IOS_ID, .{ .item = .Bread });   // Produces 1 bread
_ = engine.addStorage(EOS_ID, .{ .item = .Bread });

// Create workstation (all storage references are slices)
_ = engine.addWorkstation(BAKERY_ID, .{
    .eis = &.{EIS_ID},
    .iis = &.{IIS_ID},   // Multiple IIS for multi-ingredient recipes
    .ios = &.{IOS_ID},   // Multiple IOS for multi-output recipes
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

Tests use **zspec** (BDD-style) with factory helpers:
- `test/engine_spec.zig` - Core behavior tests
- `test/priority_spec.zig` - Priority selection tests
- `test/factories.zig` - Test factories and helpers (KitchenFactory, ProducerFactory, etc.)
- `test/factories.zon` - Factory default values

Run with: `zig build test`

## Technology Stack

- **Language**: Zig 0.15+
- **Build System**: Zig build system (`build.zig`)
- **Testing**: zspec (BDD-style test runner)

## Documentation

- **README.md** - High-level overview, concepts, API documentation
- **uml/** - Visual diagrams (component, lifecycle, workflows)
- **usage/** - Runnable examples demonstrating features
