# labelle-tasks

ECS task/job queue system for Zig games. Part of the [labelle-toolkit](https://github.com/labelle-toolkit).

## Overview

A generic task/job queue system designed for game AI, worker management, and job assignment. Built to integrate with [zig-ecs](https://github.com/prime31/zig-ecs).

## Features

- **Priority-based task queue** - Tasks have priorities (Low, Normal, High, Critical)
- **Standalone tasks** - One-off tasks that complete and are done
- **Task groups** - Persistent workflows that cycle (e.g., kitchen, workshop)
- **Worker assignment** - Workers assigned to tasks or groups
- **Resource reservation** - Prevent multiple tasks from claiming the same resource
- **Interrupt levels** - Control when tasks can be interrupted
- **Serialization ready** - Designed to work with [labelle-toolkit/serialization](https://github.com/labelle-toolkit/serialization)
- **Pathfinding integration** - Scorer callbacks can use [labelle-pathfinding](https://github.com/labelle-toolkit/labelle-pathfinding) for distance-based assignment

## Concepts

### Standalone Tasks

One-off tasks that a worker picks up, executes, and completes. Once done, the task is finished.

**Examples:** Deliver an item, fight an enemy, repair a wall.

### Task Groups

Persistent workflows that cycle continuously. A group contains a sequence of steps. When all steps complete, the group goes back to Blocked, waiting for conditions to be met again.

**Examples:** Kitchen (pickup ingredients → cook → store), Workshop (gather materials → craft → store).

## Standalone Task Lifecycle

```
                    ┌─────────┐
                    │  Queued │
                    └────┬────┘
                         │ assign worker
                         ▼
                    ┌─────────┐
                    │  Active │
                    └────┬────┘
                         │
           ┌─────────────┴─────────────┐
           │ complete                  │ cancel
           ▼                           ▼
     ┌───────────┐               ┌───────────┐
     │ Completed │               │ Cancelled │
     └───────────┘               └───────────┘
```

- **Queued**: Task waiting for a worker
- **Active**: Worker is executing the task
- **Completed**: Task finished successfully
- **Cancelled**: Task terminated, cannot resume. Resources released, game logic handles consequences (e.g., dropped items become new tasks)

## Task Group Lifecycle

```
     ┌─────────┐  conditions met   ┌─────────┐  assign worker  ┌─────────┐
     │ Blocked │ ────────────────► │  Queued │ ──────────────► │  Active │
     └─────────┘                   └─────────┘                 └────┬────┘
          ▲                                                        │
          │                              ┌─────────────────────────┤
          │                              │                         │
          │ cycle done /                 │ interrupted             │ all steps done
          │ conditions not met           │ (worker released)       │
          │                              ▼                         │
          │                        ┌─────────┐                     │
          └────────────────────────│  Queued │◄────────────────────┘
                                   └─────────┘
```

- **Blocked**: Waiting for conditions (e.g., ingredients available, storage space)
- **Queued**: Conditions met, waiting for worker
- **Active**: Worker assigned, executing steps sequentially
- When interrupted: Worker released, group goes back to Queued
- When all steps done: Group cycles back to Blocked (or Queued if conditions still met)

**Groups never complete.** They represent ongoing workflows.

## Components

### Common

```zig
pub const Priority = enum {
    Low,
    Normal,
    High,
    Critical,
};

pub const InterruptLevel = enum {
    None,      // can always be interrupted
    Low,       // only High/Critical can interrupt
    High,      // only Critical can interrupt
    Atomic,    // cannot be interrupted
};
```

### Standalone Task Components

```zig
pub const TaskStatus = enum {
    Queued,
    Active,
    Completed,
    Cancelled,
};

pub const Task = struct {
    status: TaskStatus,
    priority: Priority,
    interrupt_level: InterruptLevel,
};

// On task entity - which worker is assigned
pub const AssignedTo = struct { worker: Entity };

// On worker entity - current standalone task
pub const CurrentTask = struct { task: Entity };
```

### Task Group Components

```zig
pub const TaskGroupStatus = enum {
    Blocked,
    Queued,
    Active,
};

pub const TaskGroup = struct {
    status: TaskGroupStatus,
    priority: Priority,
    interrupt_level: InterruptLevel,
};

pub const GroupSteps = struct {
    steps: []const StepDef,
    current_index: u8,
};

pub const StepDef = struct {
    type: StepType,
    // Additional step-specific data can be added via union or payload
};

// User-defined step types
pub const StepType = enum {
    Pickup,
    Cook,
    Store,
    Craft,
    // ... extend as needed
};

// On group entity - which worker is assigned
pub const GroupAssignedTo = struct { worker: Entity };

// On worker entity - current group assignment
pub const CurrentGroup = struct { group: Entity };
```

### Reservation Components

```zig
// On resource entity
pub const ReservedBy = struct { task: Entity };

// On task/group entity
pub const Reserves = struct { resources: []Entity };
```

## Callbacks

User-provided functions to customize behavior:

```zig
pub const TaskConfig = struct {
    // Score a standalone task for a worker (return null = can't do it)
    taskScorer: fn (registry: *Registry, worker: Entity, task: Entity) ?f32,
};

pub const TaskGroupConfig = struct {
    // Can the group unblock? (e.g., ingredients available)
    canUnblock: fn (registry: *Registry, group: Entity) bool,

    // Score a group for worker assignment (return null = can't do it)
    groupScorer: fn (registry: *Registry, worker: Entity, group: Entity) ?f32,
};
```

## API

```zig
pub fn TaskManager(comptime Registry: type, comptime Entity: type) type {
    return struct {
        registry: *Registry,

        // === Standalone Task Assignment ===

        /// Find best standalone task for worker, assign it
        pub fn assignBestTask(
            self: *@This(),
            worker: Entity,
            scorer: fn (*Registry, Entity, Entity) ?f32,
        ) ?Entity;

        // === Standalone Task Lifecycle ===

        /// Cancel task - releases reservations, clears assignment
        pub fn cancelTask(self: *@This(), task: Entity) void;

        /// Mark task complete
        pub fn completeTask(self: *@This(), task: Entity) void;

        // === Task Group Assignment ===

        /// Find best group for worker, assign it
        pub fn assignBestGroup(
            self: *@This(),
            worker: Entity,
            scorer: fn (*Registry, Entity, Entity) ?f32,
        ) ?Entity;

        /// Release worker from group (group goes back to Queued)
        pub fn releaseWorkerFromGroup(self: *@This(), group: Entity) void;

        // === Task Group Lifecycle ===

        /// Check all blocked groups and unblock those where canUnblock returns true
        pub fn updateBlockedGroups(
            self: *@This(),
            canUnblock: fn (*Registry, Entity) bool,
        ) void;

        /// Advance to next step in group
        pub fn advanceGroupStep(self: *@This(), group: Entity) void;

        /// Mark current cycle done, group goes back to Blocked
        pub fn completeGroupCycle(self: *@This(), group: Entity) void;

        // === Queries ===

        /// Can this task/group be interrupted by given priority?
        pub fn canInterrupt(self: *@This(), entity: Entity, by_priority: Priority) bool;

        /// Get current step index of a group
        pub fn currentGroupStep(self: *@This(), group: Entity) ?u8;

        // === Reservations ===

        pub fn reserve(self: *@This(), task_or_group: Entity, resource: Entity) !void;
        pub fn release(self: *@This(), task_or_group: Entity, resource: Entity) void;
        pub fn releaseAll(self: *@This(), task_or_group: Entity) void;
    };
}
```

## Usage Examples

### Standalone Task: Delivery

```zig
// Create delivery task
const task = registry.create();
registry.add(task, Task{
    .status = .Queued,
    .priority = .Normal,
    .interrupt_level = .Low,
});
registry.add(task, DeliveryData{
    .item = item_entity,
    .destination = storage_entity,
});

// Worker picks it up
var task_manager = TaskManager(Registry, Entity){ .registry = &registry };
if (task_manager.assignBestTask(worker, deliveryScorer)) |assigned_task| {
    // Worker now executing delivery
}

// When delivery completes
task_manager.completeTask(task);
```

### Task Group: Kitchen

```zig
// Define kitchen steps
const kitchen_steps = [_]StepDef{
    .{ .type = .Pickup },   // pickup meat
    .{ .type = .Pickup },   // pickup vegetable
    .{ .type = .Cook },
    .{ .type = .Store },
};

// Create kitchen group (persistent)
const kitchen = registry.create();
registry.add(kitchen, TaskGroup{
    .status = .Blocked,
    .priority = .Normal,
    .interrupt_level = .High,
});
registry.add(kitchen, GroupSteps{
    .steps = &kitchen_steps,
    .current_index = 0,
});

// Each frame/tick: check if blocked groups can unblock
task_manager.updateBlockedGroups(canKitchenUnblock);

fn canKitchenUnblock(registry: *Registry, group: Entity) bool {
    // Check if ingredients available and storage has space
    return hasIngredients(registry) and hasStorageSpace(registry);
}

// Worker picks up kitchen group
if (task_manager.assignBestGroup(worker, kitchenScorer)) |group| {
    // Worker now assigned to kitchen
}

// As worker completes each step
task_manager.advanceGroupStep(kitchen);

// When all steps done
task_manager.completeGroupCycle(kitchen);  // Goes back to Blocked
```

### Handling Interrupts

```zig
// Enemy appears, worker needs to fight
const fight_priority = Priority.Critical;

// Check if worker has a task
if (registry.tryGet(CurrentTask, worker)) |current| {
    if (task_manager.canInterrupt(current.task, fight_priority)) {
        task_manager.cancelTask(current.task);
        // Game logic: drop items, etc.
    }
}

// Check if worker has a group
if (registry.tryGet(CurrentGroup, worker)) |current| {
    if (task_manager.canInterrupt(current.group, fight_priority)) {
        task_manager.releaseWorkerFromGroup(current.group);
        // Group goes back to Queued, another worker can pick it up
    }
}

// Now assign fight task
_ = task_manager.assignBestTask(worker, fightScorer);
```

## Design Philosophy

- **Tasks and groups are entities** - Natural ECS integration, easy to query and serialize
- **Agent-rated job selection** - Workers score and pick tasks/groups, not a global FIFO queue
- **Library manages state, game handles consequences** - On cancel, library releases reservations; game decides what happens to dropped items
- **No pause/resume** - Cancelled tasks stay cancelled. Dropped resources become new tasks via game logic
- **Groups are persistent** - They cycle indefinitely, representing ongoing workflows

## Alternative Design: Steps as Entities

The current design uses `StepDef` structs for group steps. An alternative approach is to make each step a full task entity:

```zig
// Group entity
const kitchen_group = registry.create();
registry.add(kitchen_group, TaskGroup{ .status = .Blocked, ... });
registry.add(kitchen_group, GroupTaskEntities{
    .tasks = &[_]Entity{ pickup_meat, pickup_veg, cook, store },
    .current_index = 0,
});

// Each step is also an entity with its own components
const pickup_meat = registry.create();
registry.add(pickup_meat, Task{ .status = .Blocked, ... });
registry.add(pickup_meat, PickupData{ .item_type = .Meat });
registry.add(pickup_meat, BelongsToGroup{ .group = kitchen_group });
```

**Pros:**
- Steps can have arbitrary components
- Can query steps directly via ECS
- More flexible for complex scenarios

**Cons:**
- More entities to manage
- Need to sync step status with group status
- Higher complexity

This alternative may be implemented in the future if needed.

## Dependencies

- [zig-ecs](https://github.com/prime31/zig-ecs) - Entity Component System

## Optional Integrations

- [labelle-pathfinding](https://github.com/labelle-toolkit/labelle-pathfinding) - For distance-based task scoring
- [serialization](https://github.com/labelle-toolkit/serialization) - For save/load support

## License

MIT
