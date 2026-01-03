# labelle-tasks

Task orchestration engine for Zig games. Part of the [labelle-toolkit](https://github.com/labelle-toolkit).

## Overview

A pure state machine task orchestration engine for games. The engine tracks abstract workflow state (storage contents, worker assignments, current steps) and emits hooks to notify the game of events, but never mutates game state directly.

**Key Principle**: The engine is a pure state machine. It tracks abstract state and emits hooks. The game owns all entity lifecycle, timing, and ECS state.

## Features

- **Pure state machine** - Engine tracks abstract state, game owns entity lifecycle
- **Storage management** - Tracks items in storages (each storage holds one item type)
- **Automatic step derivation** - Steps derived from storage configuration (Pickup, Process, Store)
- **Priority-based assignment** - Workstations and transports have priorities (Low, Normal, High, Critical)
- **Producer workstations** - Workstations that produce items without inputs (e.g., water condenser)
- **Recurring transports** - Automatic item movement between storages
- **Worker management** - Workers assigned to workstations and transports automatically
- **Cycle tracking** - Track how many times a workstation has completed its workflow
- **Hook-based events** - Comptime-resolved event hooks with zero runtime overhead
- **labelle-engine integration** - TaskEngineContext and createEngineHooks helpers
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
const tasks = @import("labelle-tasks");

// Define your item types (can be enum or tagged union)
const Item = enum { Vegetable, Meat, Water, Meal };

// Define hook handlers (optional - only implement the hooks you need)
const MyHooks = struct {
    pub fn pickup_started(payload: anytype) void {
        // payload has worker_id, eis_id, workstation_id, item
        // Start worker movement to EIS location
    }

    pub fn process_started(payload: anytype) void {
        // Play cooking animation, start work timer
    }

    pub fn cycle_completed(payload: anytype) void {
        std.log.info("Cycle {d} completed!", .{payload.cycles_completed});
    }
};

// Create engine with hooks
var engine = tasks.Engine(u32, Item, MyHooks).init(allocator, .{});
defer engine.deinit();

// For an engine without hooks, pass an empty struct:
// var engine = tasks.Engine(u32, Item, struct {}).init(allocator, .{});

// Create storages (each storage holds ONE item type)
_ = try engine.addStorage(VEG_EIS_ID, .Vegetable);
_ = try engine.addStorage(MEAT_EIS_ID, .Meat);
_ = try engine.addStorage(VEG_IIS_ID, .Vegetable);  // Recipe needs 1 vegetable
_ = try engine.addStorage(MEAT_IIS_ID, .Meat);      // Recipe needs 1 meat
_ = try engine.addStorage(KITCHEN_IOS_ID, .Meal);   // Produces 1 meal
_ = try engine.addStorage(KITCHEN_EOS_ID, .Meal);

// Create workstation referencing storages
_ = try engine.addWorkstation(KITCHEN_ID, .{
    .eis = &.{ VEG_EIS_ID, MEAT_EIS_ID },      // Multiple input sources
    .iis = &.{ VEG_IIS_ID, MEAT_IIS_ID },      // Recipe: 1 veg + 1 meat
    .ios = &.{KITCHEN_IOS_ID},                  // Produces: 1 meal
    .eos = &.{KITCHEN_EOS_ID},                  // Output destination
    .process_duration = 40,
});

// Register workers
_ = try engine.addWorker(CHEF_ID);

// Add items to storage - engine tracks state, emits hooks
_ = engine.handle(.{ .item_added = .{ .storage_id = VEG_EIS_ID, .item = .Vegetable, .quantity = 5 } });
_ = engine.handle(.{ .item_added = .{ .storage_id = MEAT_EIS_ID, .item = .Meat, .quantity = 2 } });

// Game notifies engine of events via handle()
_ = engine.handle(.{ .worker_available = .{ .worker_id = CHEF_ID } });
// Engine emits pickup_started → game starts worker movement

_ = engine.handle(.{ .pickup_completed = .{ .worker_id = CHEF_ID } });
// Engine emits process_started → game starts work timer

_ = engine.handle(.{ .work_completed = .{ .workstation_id = KITCHEN_ID } });
// Engine emits process_completed, store_started → game handles transformation

_ = engine.handle(.{ .store_completed = .{ .worker_id = CHEF_ID } });
// Engine emits cycle_completed → workflow complete
```

## Hook System

The engine emits hooks for lifecycle events with zero runtime overhead.
Only implement the hooks you need - unhandled hooks are no-ops at comptime.

```zig
const tasks = @import("labelle-tasks");

// Define hook handlers
const MyHooks = struct {
    pub fn pickup_started(payload: anytype) void {
        std.log.info("Worker {d} picking from EIS {d}", .{ payload.worker_id, payload.eis_id });
    }

    pub fn cycle_completed(payload: anytype) void {
        std.log.info("Cycle {d} completed!", .{ payload.cycles_completed });
    }
};

// Create engine with hooks
var engine = tasks.Engine(u32, Item, MyHooks).init(allocator, .{});
defer engine.deinit();

_ = try engine.addWorker(WORKER_ID);
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

Combine multiple hook handler structs using `MergeHooks`:

```zig
const GameHooks = struct {
    pub fn cycle_completed(payload: anytype) void {
        // Game logic
    }
};

const AnalyticsHooks = struct {
    pub fn cycle_completed(payload: anytype) void {
        // Analytics tracking
    }
};

// Both handlers will be called (GameHooks has priority)
const MergedHooks = tasks.MergeHooks(.{ GameHooks, AnalyticsHooks });
var engine = tasks.Engine(u32, Item, MergedHooks).init(allocator, .{});
```

### LoggingHooks

A default logging implementation is provided for debugging:

```zig
// Use LoggingHooks to log all hook events
var engine = tasks.Engine(u32, Item, tasks.LoggingHooks).init(allocator, .{});

// Or merge with your hooks (your hooks have priority)
const MergedHooks = tasks.MergeHooks(.{ MyHooks, tasks.LoggingHooks });
```

## labelle-engine Integration

For integration with labelle-engine, the library provides `createEngineHooks` and `TaskEngineContext`:

```zig
const tasks = @import("labelle-tasks");
const engine = @import("labelle-engine");

// Define your item types
const Items = enum { flour, bread, water };

// Entity ID type from your game
const GameId = engine.Entity;

// Define game-specific task hooks
const GameHooks = struct {
    pub fn pickup_started(payload: anytype) void {
        // Start worker movement to EIS location
    }
    pub fn process_started(payload: anytype) void {
        // Start work animation/timer
    }
};

// Create engine hooks that wrap task events with game context
const task_engine_hooks = tasks.createEngineHooks(GameId, Items, GameHooks);

// TaskEngineContext provides a pre-built context struct
pub const TasksContext = task_engine_hooks.Context;
// Contains: allocator, task_engine pointer, game pointer

// Use in labelle-engine hooks folder:
pub fn scene_before_load(payload: engine.HookPayload) void {
    // Initialize task engine before entities are created
    const allocator = payload.scene_before_load.allocator;
    task_engine = tasks.Engine(GameId, Items, GameHooks).init(allocator, .{}) catch unreachable;
}
```

### Plugin Integration (project.labelle)

When using the labelle-engine generator, configure the plugin in `project.labelle`:

```zig
.plugins = .{
    .{
        .name = "labelle-tasks",
        .version = "0.9.0",
        .bind = .{
            .{ .func = "bind", .arg = "Items", .components = "Storage,Worker,Workstation" },
        },
        .engine_hooks = .{
            .create = "createEngineHooks",
            .task_hooks = "task_hooks.GameHooks",
        },
    },
},
```

This auto-generates the engine hook wiring and exports `labelle_tasksContext` for scripts.

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
