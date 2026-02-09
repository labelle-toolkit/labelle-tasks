# labelle-tasks

Task orchestration engine for Zig games. Part of the [labelle-toolkit](https://github.com/labelle-toolkit).

## Overview

A pure state machine task orchestration engine for games. The engine tracks abstract workflow state (storage contents, worker assignments, current steps) and emits hooks to notify the game of events, but never mutates game state directly.

**Key Principle**: The engine is a pure state machine. It tracks abstract state and emits hooks. The game owns all entity lifecycle, timing, and ECS state.

## Features

- **Pure state machine** - Engine tracks abstract state, game owns entity lifecycle
- **Storage management** - Tracks items in storages (each storage holds one item)
- **Automatic step derivation** - Steps derived from storage configuration (Pickup, Process, Store)
- **Priority-based selection** - Storages and workstations have priorities (Low, Normal, High, Critical)
- **Producer workstations** - Workstations that produce items without inputs (e.g., water condenser)
- **Worker management** - Workers assigned to workstations automatically by priority
- **Dangling item pickup** - Workers auto-collect items not in any storage
- **Cycle tracking** - Track how many times a workstation has completed its workflow
- **Hook-based events** - Comptime-resolved event hooks with zero runtime overhead
- **Recording hooks** - Built-in `RecordingHooks` for test assertions
- **labelle-engine integration** - `TaskEngineContextWith`, `createEngineHooks`, auto-registering ECS components
- **Type-erased ECS bridge** - `EcsInterface` vtable pattern for engine-agnostic integration

## Storage Model

The engine uses a four-storage model for workstations:

```
EIS (External Input) → IIS (Internal Input) → [Process] → IOS (Internal Output) → EOS (External Output)
```

- **EIS** - Where raw materials are stored (e.g., ingredients shelf)
- **IIS** - Recipe inputs buffer at the workstation
- **IOS** - Recipe outputs buffer at the workstation
- **EOS** - Where finished products go (e.g., serving counter)

Each storage holds **one item** (has_item: bool, item_type: ?Item).

## Concepts

### Workers

Entities that perform work at workstations. Workers have three states:
- **Idle** - Available for assignment
- **Working** - Executing steps at a workstation
- **Unavailable** - Temporarily unavailable (fighting, sleeping, etc.)

### Workstations

Locations where work happens. Steps are derived from storage configuration:
- Has EIS/IIS → **Pickup** step (transfer EIS → IIS)
- Always → **Process** step (transforms IIS → IOS)
- Has IOS/EOS → **Store** step (transfer IOS → EOS)

Workstation statuses:
- **Blocked** - EIS doesn't have required items, or EOS is full
- **Queued** - Has resources, waiting for worker
- **Active** - Worker assigned and executing steps

### Priority System

Storages and workstations support priority levels: `Low`, `Normal` (default), `High`, `Critical`.

- Higher-priority EIS is selected first when picking up items
- Higher-priority EOS is selected first when storing items
- Higher-priority workstations receive idle workers before lower-priority ones

## Engine API

```zig
const tasks = @import("labelle-tasks");

// Define your item types
const Item = enum { Flour, Water, Dough, Bread };

// Define hook handlers (only implement the hooks you need)
const MyHooks = struct {
    pub fn pickup_started(payload: anytype) void {
        // payload.worker_id, payload.storage_id, payload.item
    }

    pub fn process_completed(payload: anytype) void {
        // payload.workstation_id, payload.worker_id
    }

    pub fn cycle_completed(payload: anytype) void {
        std.log.info("Cycle {d} completed!", .{payload.cycles_completed});
    }
};

// Create engine (with optional distance function)
var engine = tasks.Engine(u32, Item, MyHooks).init(allocator, .{}, null);
defer engine.deinit();

// Register storages with role and optional priority
try engine.addStorage(eis_id, .{ .role = .eis, .initial_item = .Flour, .priority = .High });
try engine.addStorage(iis_id, .{ .role = .iis });
try engine.addStorage(ios_id, .{ .role = .ios });
try engine.addStorage(eos_id, .{ .role = .eos });

// Register workstation referencing storages
try engine.addWorkstation(ws_id, .{
    .eis = &.{eis_id},
    .iis = &.{iis_id},
    .ios = &.{ios_id},
    .eos = &.{eos_id},
    .priority = .Normal,
});

// Register worker
try engine.addWorker(worker_id);

// Game notifies engine of events via handle()
_ = engine.handle(.{ .worker_available = .{ .worker_id = worker_id } });
// Engine emits pickup_started hook → game starts movement

_ = engine.handle(.{ .pickup_completed = .{ .worker_id = worker_id } });
// Engine emits process_started hook → game starts work timer

_ = engine.handle(.{ .work_completed = .{ .workstation_id = ws_id } });
// Engine emits process_completed, store_started hooks

_ = engine.handle(.{ .store_completed = .{ .worker_id = worker_id } });
// Engine emits cycle_completed hook
```

## Hook System

The engine emits hooks for lifecycle events with zero runtime overhead.
Only implement the hooks you need - unhandled hooks are no-ops at comptime.

Hooks support two calling conventions:
- **1-param (static)**: `pub fn hook_name(payload: anytype) void`
- **2-param (instance)**: `pub fn hook_name(self: *@This(), payload: anytype) void`

### Available Hooks

**Step lifecycle:**
- `pickup_started` - Worker begins pickup from EIS
- `process_started` - Processing begins at workstation
- `process_completed` - Processing finished
- `store_started` - Worker begins storing to EOS

**Worker lifecycle:**
- `worker_assigned` - Worker assigned to workstation
- `worker_released` - Worker released from workstation

**Workstation lifecycle:**
- `workstation_blocked` - Workstation blocked (no inputs or outputs full)
- `workstation_queued` - Workstation ready, waiting for worker
- `workstation_activated` - Worker assigned, work starting

**Cycle lifecycle:**
- `cycle_completed` - Workstation completed a full cycle

**Dangling item lifecycle:**
- `pickup_dangling_started` - Worker dispatched to pick up a dangling item
- `item_delivered` - Item delivered to target storage

**Input consumption:**
- `input_consumed` - IIS item consumed during processing

**Transport lifecycle:**
- `transport_started` - Transport task began
- `transport_completed` - Transport task finished

### Merging Hook Handlers

Combine two hook handler structs using `MergeHooks`:

```zig
const GameHooks = struct {
    pub fn cycle_completed(payload: anytype) void {
        // Game logic
    }
};

// GameHooks has priority, LoggingHooks is fallback
const MergedHooks = tasks.MergeHooks(GameHooks, tasks.LoggingHooks);
var engine = tasks.Engine(u32, Item, MergedHooks).init(allocator, .{}, null);
```

### Recording Hooks (Testing)

Built-in recording hooks for test assertions:

```zig
const Recorder = tasks.RecordingHooks(u32, Item);
var recorder = Recorder{};
recorder.init(std.testing.allocator);
defer recorder.deinit();

var engine = tasks.Engine(u32, Item, Recorder).init(std.testing.allocator, recorder, null);
defer engine.deinit();

// ... trigger events ...

const p = try recorder.expectNext(.pickup_started);
try std.testing.expectEqual(worker_id, p.worker_id);
try recorder.expectEmpty();
```

## Producer Workstations

Workstations without EIS/IIS produce items from nothing (e.g., water condenser, mine):

```zig
// Water condenser - produces water without inputs
try engine.addStorage(ios_id, .{ .role = .ios });
try engine.addStorage(eos_id, .{ .role = .eos });

try engine.addWorkstation(condenser_id, .{
    .ios = &.{ios_id},
    .eos = &.{eos_id},
    .priority = .Low,
});
// Producer starts as Queued immediately - no inputs needed
// Skips Pickup step, goes straight to Process
```

## Dangling Items

Items not in any storage can be tracked and auto-collected:

```zig
// Register a dangling item (e.g., dropped by player)
try engine.addDanglingItem(item_entity_id, .Flour);

// Engine dispatches idle worker to pick it up and deliver to matching empty EIS
// Emits pickup_dangling_started hook, then item_delivered on completion
```

## Multiple Input/Output Storages

Workstations can reference multiple EIS and EOS for flexible routing:

```zig
try engine.addWorkstation(kitchen_id, .{
    .eis = &.{ pantry_id, fridge_id, shelf_id },  // Pick from highest-priority with item
    .iis = &.{ingredient_iis_id},
    .ios = &.{meal_ios_id},
    .eos = &.{ counter_1_id, counter_2_id },       // Store to highest-priority empty
    .priority = .High,
});
```

## Dynamic Storage Attachment

Storages can be attached to workstations after creation:

```zig
try engine.addWorkstation(ws_id, .{});
try engine.attachStorageToWorkstation(eis_id, ws_id, .eis);
try engine.attachStorageToWorkstation(eos_id, ws_id, .eos);
```

## Query API

```zig
engine.getWorkerState(worker_id)       // ?WorkerState
engine.getWorkerCurrentStep(worker_id) // ?StepType
engine.getWorkstationStatus(ws_id)     // ?WorkstationStatus
engine.getStorageHasItem(storage_id)   // ?bool
engine.getStorageItemType(storage_id)  // ?Item
engine.getDistance(from_id, to_id)     // ?f32
engine.findNearest(target, candidates) // ?GameId
```

## labelle-engine Integration

For integration with labelle-engine, the library provides `createEngineHooks` and `TaskEngineContextWith`:

```zig
const tasks = @import("labelle-tasks");
const engine = @import("labelle-engine");

const Items = enum { flour, bread, water };

const GameHooks = struct {
    pub fn store_started(payload: anytype) void {
        // payload.worker_id, payload.storage_id, payload.item
        // payload.registry, payload.game (enriched by createEngineHooks)
    }
};

pub const TaskHooks = tasks.createEngineHooks(u64, Items, GameHooks, engine.EngineTypes);
pub const Context = TaskHooks.Context;

// Engine hooks are provided: game_init, scene_load, game_deinit
```

### Auto-Registering ECS Components

Components auto-register with the task engine via the `EcsInterface` vtable:

```zig
const Components = tasks.bind(Items, engine.EngineTypes);
// Components.Storage, Components.Worker, Components.Workstation, Components.DanglingItem
```

### Plugin Integration (project.labelle)

```zig
.plugins = .{
    .{
        .name = "labelle-tasks",
        .path = "../../labelle-tasks",
        .bind = .{
            .{ .func = "bind", .args = .{"Items", "engine.EngineTypes"} },
        },
    },
},
```

## Running Tests

```bash
zig build test
```

## Design Philosophy

- **Pure state machine** - No external ECS dependency, manages state internally
- **Engine-agnostic** - No labelle-engine dependency; types injected via comptime parameters
- **Storage-aware** - Engine tracks resources and validates automatically
- **Hook-driven** - Engine handles orchestration, game handles movement/animations
- **Generic entity IDs** - Engine is generic over ID type (u32, u64, custom)
- **Priority-aware** - Higher-priority workstations and storages are served first

## License

MIT
