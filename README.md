# labelle-tasks

Task orchestration engine for Zig games. Part of the [labelle-toolkit](https://github.com/labelle-toolkit).

## Overview

A self-contained task orchestration engine with storage management for games. The engine handles task assignment, resource tracking, and workflow progression internally, emitting hooks for game-specific logic (pathfinding, animations, etc.).

## Features

- **Storage management** - Engine tracks items in storages (each storage holds one item type)
- **Automatic step derivation** - Steps derived from storage configuration (Pickup, Process, Store)
- **Priority-based assignment** - Workstations and transports have priorities (Low, Normal, High, Critical)
- **Producer workstations** - Workstations that produce items without inputs (e.g., water condenser)
- **Recurring transports** - Automatic item movement between storages
- **Worker management** - Workers assigned to workstations and transports automatically
- **Cycle tracking** - Track how many times a workstation has completed its workflow
- **Hook-based events** - Comptime-resolved event hooks with zero runtime overhead
- **ECS Components** - Generic components for labelle-engine integration

## Storage Model

The engine uses a four-storage model for workstations:

```
EIS (External Input) → IIS (Internal Input) → [Process] → IOS (Internal Output) → EOS (External Output)
```

Each storage holds **one item type** with unlimited quantity:
- **EIS** - Where raw materials are stored (e.g., ingredients shelf)
- **IIS** - Recipe inputs - each IIS defines one ingredient needed per cycle
- **IOS** - Recipe outputs - each IOS defines one product produced per cycle
- **EOS** - Where finished products go (e.g., serving counter)

For multi-item recipes, use multiple IIS storages (one for each unit of an ingredient required). For example, a recipe needing 2 Flour and 1 Meat would require three IIS storages: two for Flour and one for Meat.

## Concepts

### Workers

Entities that perform work at workstations. Workers have three states:
- **Idle** - Available for assignment
- **Working** - Executing steps at a workstation or transport
- **Blocked** - Temporarily unavailable (fighting, sleeping, etc.)

### Workstations

Locations where work happens. Steps are derived automatically from storage configuration:
- Has IIS → **Pickup** step (transfer EIS → IIS)
- Has process_duration → **Process** step (timed, transforms IIS → IOS)
- Has IOS → **Store** step (transfer IOS → EOS)

Workstation statuses:
- **Blocked** - EIS doesn't have recipe requirements
- **Queued** - Has resources, waiting for worker
- **Active** - Worker assigned and executing steps

### Transports

Recurring tasks that move items between any two storages. Activate when source has items.

## Engine API

```zig
const tasks = @import("labelle_tasks");

// Define your item types (can be enum or tagged union)
const Item = enum { Vegetable, Meat, Water, Meal };

// Define hook handlers (optional - only implement the hooks you need)
const MyHooks = struct {
    pub fn pickup_started(payload: tasks.hooks.HookPayload(u32, Item)) void {
        const info = payload.pickup_started;
        // Start worker movement to EIS location
    }

    pub fn process_started(payload: tasks.hooks.HookPayload(u32, Item)) void {
        const info = payload.process_started;
        // Play cooking animation, etc.
    }

    pub fn cycle_completed(payload: tasks.hooks.HookPayload(u32, Item)) void {
        const info = payload.cycle_completed;
        std.log.info("Cycle {d} completed!", .{info.cycles_completed});
    }
};

// Create dispatcher and engine
const Dispatcher = tasks.hooks.HookDispatcher(u32, Item, MyHooks);
var engine = tasks.Engine(u32, Item, Dispatcher).init(allocator);
defer engine.deinit();

// Set worker selection callback (required)
engine.setFindBestWorker(findBestWorker);

// Create storages (each storage holds ONE item type)
_ = engine.addStorage(VEG_EIS_ID, .{ .item = .Vegetable });
_ = engine.addStorage(MEAT_EIS_ID, .{ .item = .Meat });
_ = engine.addStorage(VEG_IIS_ID, .{ .item = .Vegetable });  // Recipe needs 1 vegetable
_ = engine.addStorage(MEAT_IIS_ID, .{ .item = .Meat });      // Recipe needs 1 meat
_ = engine.addStorage(KITCHEN_IOS_ID, .{ .item = .Meal });   // Produces 1 meal
_ = engine.addStorage(KITCHEN_EOS_ID, .{ .item = .Meal });

// Create workstation referencing storages
// All storage references are slices for flexible routing
_ = engine.addWorkstation(KITCHEN_ID, .{
    .eis = &.{ VEG_EIS_ID, MEAT_EIS_ID },      // Multiple input sources
    .iis = &.{ VEG_IIS_ID, MEAT_IIS_ID },      // Recipe: 1 veg + 1 meat
    .ios = &.{KITCHEN_IOS_ID},                  // Produces: 1 meal
    .eos = &.{KITCHEN_EOS_ID},                  // Output destination
    .process_duration = 40,
    .priority = .High,
});

// Register workers
_ = engine.addWorker(CHEF_ID, .{});

// Add items to storage - engine automatically manages state transitions
_ = engine.addToStorage(VEG_EIS_ID, .Vegetable, 5);
_ = engine.addToStorage(MEAT_EIS_ID, .Meat, 2);

// Call update() each game tick to advance process timers
engine.update();

// Game events
engine.notifyPickupComplete(CHEF_ID);     // Worker arrived at EIS
engine.notifyStoreComplete(CHEF_ID);      // Worker arrived at EOS
engine.notifyTransportComplete(CHEF_ID);  // Worker completed transport
engine.notifyWorkerIdle(CHEF_ID);         // Worker available
engine.notifyWorkerBusy(CHEF_ID);         // Worker unavailable
engine.abandonWork(CHEF_ID);              // Worker abandons task
```

## findBestWorker Callback

The only required callback selects which worker to assign:

```zig
fn findBestWorker(
    workstation_id: ?u32,  // null for transport tasks
    available_workers: []const u32,
) ?u32 {
    // Use pathfinding, skills, etc. to pick best worker
    if (available_workers.len > 0) return available_workers[0];
    return null;
}
```

## Hook System

The engine emits hooks for lifecycle events with zero runtime overhead.
Only implement the hooks you need - unhandled hooks are no-ops at comptime.

```zig
const tasks = @import("labelle_tasks");

// Define hook handlers
const MyHooks = struct {
    pub fn pickup_started(payload: tasks.hooks.HookPayload(u32, Item)) void {
        const info = payload.pickup_started;
        std.log.info("Worker {d} picking from EIS {d}", .{ info.worker_id, info.eis_id });
    }

    pub fn cycle_completed(payload: tasks.hooks.HookPayload(u32, Item)) void {
        const info = payload.cycle_completed;
        std.log.info("Cycle {d} completed!", .{ info.cycles_completed });
    }
};

// Create dispatcher and engine
const Dispatcher = tasks.hooks.HookDispatcher(u32, Item, MyHooks);
var engine = tasks.Engine(u32, Item, Dispatcher).init(allocator);
defer engine.deinit();

engine.setFindBestWorker(findBestWorker);
_ = engine.addWorker(WORKER_ID, .{});
// Hooks are emitted automatically during engine operations
```

### Available Hooks

**Step lifecycle:**
- `pickup_started` - Worker begins pickup from EIS
- `process_started` - Processing begins at workstation
- `process_completed` - Processing finished
- `store_started` - Worker begins storing to EOS

**Worker lifecycle:**
- `worker_assigned` - Worker assigned to workstation or transport
- `worker_released` - Worker released from workstation

**Workstation lifecycle:**
- `workstation_blocked` - Workstation blocked (no inputs or outputs full)
- `workstation_queued` - Workstation ready, waiting for worker
- `workstation_activated` - Worker assigned, work starting

**Transport lifecycle:**
- `transport_started` - Transport task began
- `transport_completed` - Transport task finished

**Cycle lifecycle:**
- `cycle_completed` - Workstation completed a full cycle

### Merging Hook Handlers

Combine multiple hook handler structs:

```zig
const GameHooks = struct {
    pub fn cycle_completed(payload: tasks.hooks.HookPayload(u32, Item)) void {
        // Game logic
    }
};

const AnalyticsHooks = struct {
    pub fn cycle_completed(payload: tasks.hooks.HookPayload(u32, Item)) void {
        // Analytics tracking
    }
};

// Both handlers will be called
const AllHooks = tasks.hooks.MergeTasksHooks(u32, Item, .{ GameHooks, AnalyticsHooks });
var engine = tasks.Engine(u32, Item, AllHooks).init(allocator);
```

## Producer Workstations

Workstations without EIS/IIS produce items from nothing (e.g., water condenser, mine):

```zig
// Water condenser - produces water without inputs
_ = engine.addStorage(CONDENSER_IOS_ID, .{ .item = .Water });
_ = engine.addStorage(CONDENSER_EOS_ID, .{ .item = .Water });

_ = engine.addWorkstation(CONDENSER_ID, .{
    .ios = &.{CONDENSER_IOS_ID},
    .eos = &.{CONDENSER_EOS_ID},
    .process_duration = 30,
    .priority = .Low,
});
// Condenser starts immediately (Queued) - no inputs needed
```

## Multiple Input/Output Storages

Workstations can reference multiple EIS and EOS for flexible routing:

```zig
// Kitchen with multiple ingredient sources and serving counters
_ = engine.addWorkstation(KITCHEN_ID, .{
    .eis = &.{ PANTRY_ID, FRIDGE_ID, SHELF_ID },  // Pick from any that has ingredients
    .iis = &.{INGREDIENT_IIS_ID},                  // Recipe requirement
    .ios = &.{MEAL_IOS_ID},                        // Produced output
    .eos = &.{ COUNTER_1_ID, COUNTER_2_ID },       // Store to first available
    .process_duration = 40,
    .priority = .High,
});
```

The engine automatically:
- Checks all EIS storages when looking for available ingredients
- Picks from the first EIS that has the required item
- Stores outputs to the first EOS that accepts the item type
- Blocks only when NO EIS has required ingredients

## Transports

Recurring tasks that move items between storages:

```zig
// Transport vegetables from garden to kitchen
_ = engine.addTransport(.{
    .from = GARDEN_STORAGE_ID,
    .to = KITCHEN_EIS_ID,
    .item = .Vegetable,
    .priority = .Normal,
});
// Transport activates when garden has vegetables
```

## ECS Components

For integration with labelle-engine, the library provides generic ECS components parameterized by your game's item type:

```zig
const tasks = @import("labelle_tasks");

// Define your game's item types
const ItemType = enum { wheat, carrot, flour, bread };

// Create components for your item type
const Components = tasks.EcsComponents(ItemType);

// Use the components
const worker = Components.TaskWorker{ .priority = 7 };
const workstation = Components.TaskWorkstation{ .process_duration = 60, .priority = 5 };

// Storage with item filtering using EnumSet
const wheat_silo = Components.TaskStorage{
    .accepts = Components.ItemSet.initOne(.wheat),
};
const pantry = Components.TaskStorage{
    .accepts = Components.ItemSet.initMany(&.{ .wheat, .flour, .bread }),
};
const general_storage = Components.TaskStorage{}; // accepts all (default)

// Items
const wheat_item = Components.TaskItem{ .item_type = .wheat };

// Check if storage accepts item
if (wheat_silo.canAccept(wheat_item.item_type)) {
    // ...
}
```

### Available Components

- **TaskWorker** - Marks an entity as a worker with priority (0-15)
- **TaskWorkstation** - Configures processing duration and priority
- **TaskStorage** - Storage with item type filtering via `EnumSet`
- **TaskItem** - Item with its type
- **TaskTransport** - Transport route with priority

## Running Examples

```bash
# Run the interactive kitchen simulator
zig build kitchen-sim

# Run the components usage example
zig build components

# Run the farm game example
zig build farm

# Run the hooks example
zig build hooks

# Run all examples
zig build examples

# Run tests
zig build test
```

## Logging

The engine uses Zig's `std.log` with scoped loggers for debugging and monitoring:

- `labelle_tasks_engine` - Task orchestration, worker assignments, cycle events
- `labelle_tasks_storage` - Item additions, removals, and transfers

Configure log levels in your root file:

```zig
pub const std_options: std.Options = .{
    .log_level = .debug,
    .log_scope_levels = &.{
        .{ .scope = .labelle_tasks_engine, .level = .info },
        .{ .scope = .labelle_tasks_storage, .level = .warn },
    },
};
```

## Design Philosophy

- **Self-contained engine** - No external ECS dependency, manages state internally
- **Storage-aware** - Engine tracks resources and validates recipes automatically
- **Callback-driven** - Engine handles orchestration, game handles movement/animations
- **Game entity IDs** - Engine is generic over ID type (u32, u64, custom struct)
- **Automatic state management** - Workstations transition based on storage state

## License

MIT
