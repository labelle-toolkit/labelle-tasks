# labelle-tasks

ECS task/job queue system for Zig games. Part of the [labelle-toolkit](https://github.com/labelle-toolkit).

## Overview

A generic task/job queue system designed for game AI, worker management, and job assignment. Built to integrate with [zig-ecs](https://github.com/prime31/zig-ecs).

## Features

- **Priority-based task queue** - Tasks have priorities (Low, Normal, High, Critical)
- **Worker pools** - Group workers by capability
- **Task dependencies** - Tasks can depend on other tasks
- **Resource reservation** - Prevent multiple tasks from claiming the same resource
- **Composite tasks** - Multi-step tasks with subtask progression
- **Interrupt levels** - Control when tasks can be interrupted
- **Serialization ready** - Designed to work with [labelle-toolkit/serialization](https://github.com/labelle-toolkit/serialization)
- **Pathfinding integration** - Scorer callbacks can use [labelle-pathfinding](https://github.com/labelle-toolkit/labelle-pathfinding) for distance-based assignment

## Task Lifecycle

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

## Components

### Task Components

```zig
pub const TaskStatus = enum {
    Queued,
    Active,
    Completed,
    Cancelled,
};

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

pub const Task = struct {
    status: TaskStatus,
    priority: Priority,
    interrupt_level: InterruptLevel,
};

// For multi-step tasks
pub const CompositeTask = struct {
    subtasks: []const SubtaskDef,
    current_step: u8,
};

pub const SubtaskDef = struct {
    name: []const u8,
};
```

### Link Components

```zig
// On task entity
pub const AssignedTo = struct { worker: Entity };

// On worker entity
pub const CurrentTask = struct { task: Entity };
```

### Reservation Components

```zig
// On resource entity
pub const ReservedBy = struct { task: Entity };

// On task entity
pub const Reserves = struct { resources: []Entity };
```

## API

```zig
pub fn TaskManager(comptime Registry: type, comptime Entity: type) type {
    return struct {
        registry: *Registry,

        // === Assignment ===

        /// Find best task for worker using scorer, assign it
        pub fn assignBestTask(
            self: *@This(),
            worker: Entity,
            scorer: fn(*Registry, Entity, Entity) ?f32,
        ) ?Entity;

        // === Lifecycle ===

        /// Cancel task - releases reservations, clears assignment
        pub fn cancel(self: *@This(), task: Entity) void;

        /// Mark task complete
        pub fn complete(self: *@This(), task: Entity) void;

        /// Advance to next subtask step
        pub fn advanceStep(self: *@This(), task: Entity) bool;

        // === Queries ===

        /// Can this task be interrupted by given priority?
        pub fn canInterrupt(self: *@This(), task: Entity, by_priority: Priority) bool;

        /// Get current step of composite task
        pub fn currentStep(self: *@This(), task: Entity) ?u8;

        // === Reservations ===

        pub fn reserve(self: *@This(), task: Entity, resource: Entity) !void;
        pub fn release(self: *@This(), task: Entity, resource: Entity) void;
        pub fn releaseAll(self: *@This(), task: Entity) void;
    };
}
```

## Usage Example

### Defining a Scorer

The scorer function determines which task is best for a given worker. Return `null` if the worker cannot perform the task, or a score where higher is better.

```zig
fn taskScorer(registry: *Registry, worker: Entity, task: Entity) ?f32 {
    const task_data = registry.get(Task, task);

    // Skip completed/cancelled tasks
    if (task_data.status != .Queued) return null;

    // Check worker capabilities
    const worker_caps = registry.get(WorkerCapabilities, worker);
    const task_reqs = registry.get(TaskRequirements, task);
    if (!worker_caps.canDo(task_reqs)) return null;

    // Score based on priority and distance
    var score: f32 = @intToFloat(f32, @enumToInt(task_data.priority)) * 100.0;

    // Closer tasks score higher (using pathfinding)
    const worker_pos = registry.get(Position, worker);
    const task_pos = registry.get(Position, task);
    const distance = pathfinding.distance(worker_pos, task_pos) orelse return null;
    score -= distance;

    return score;
}
```

### Assigning Tasks

```zig
var task_manager = TaskManager(Registry, Entity){ .registry = &registry };

// When worker becomes idle, find best task
if (task_manager.assignBestTask(worker, taskScorer)) |task| {
    // Worker now has task assigned
    startTaskExecution(worker, task);
}
```

### Handling Interrupts

```zig
// Enemy appears, worker needs to fight
const fight_priority = Priority.Critical;

if (registry.tryGet(CurrentTask, worker)) |current| {
    if (task_manager.canInterrupt(current.task, fight_priority)) {
        // Cancel current task
        task_manager.cancel(current.task);

        // Game logic: handle consequences (drop items, etc.)
        handleTaskCancellation(current.task);
    }
}

// Assign fight task
_ = task_manager.assignBestTask(worker, fightTaskScorer);
```

### Composite Tasks

```zig
const cooking_steps = [_]SubtaskDef{
    .{ .name = "pickup_meat" },
    .{ .name = "pickup_vegetable" },
    .{ .name = "cook" },
    .{ .name = "store_result" },
};

// Create cooking task
const task = registry.create();
registry.add(task, Task{
    .status = .Queued,
    .priority = .Normal,
    .interrupt_level = .High,  // Don't interrupt cooking easily
});
registry.add(task, CompositeTask{
    .subtasks = &cooking_steps,
    .current_step = 0,
});

// During execution, advance steps
if (stepCompleted) {
    if (!task_manager.advanceStep(task)) {
        // All steps done
        task_manager.complete(task);
    }
}
```

## Design Philosophy

- **Tasks are entities** - Natural ECS integration, easy to query and serialize
- **Agent-rated job selection** - Workers score and pick tasks, not a global FIFO queue
- **Library manages state, game handles consequences** - On cancel, library releases reservations; game decides what happens to dropped items
- **No pause/resume** - Cancelled tasks stay cancelled. Dropped resources become new tasks via game logic

## Dependencies

- [zig-ecs](https://github.com/prime31/zig-ecs) - Entity Component System

## Optional Integrations

- [labelle-pathfinding](https://github.com/labelle-toolkit/labelle-pathfinding) - For distance-based task scoring
- [serialization](https://github.com/labelle-toolkit/serialization) - For save/load support

## License

MIT
