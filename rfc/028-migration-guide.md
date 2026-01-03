# RFC #28 Migration Guide

## Overview

RFC #28 simplifies labelle-tasks integration by:
1. Exporting auto-registering component types from labelle-tasks
2. Providing a type-erased interface to connect components to the engine
3. Eliminating wrapper component boilerplate in games

## Before (bakery-game current approach)

Games define wrapper components that manually bridge to task_state:

```zig
// components/storage.zig (BOILERPLATE - 87 lines)
pub const Storage = struct {
    storage_type: StorageType,
    initial_item: ?ItemType = null,

    pub fn onAdd(payload: engine.ComponentPayload) void {
        // Get entity, registry, component data...
        // Convert types...
        // Call task_state.addStorage()...
    }

    pub fn onRemove(payload: engine.ComponentPayload) void {
        // Call task_state cleanup...
    }
};

// components/worker.zig (BOILERPLATE - similar pattern)
// components/dangling_item.zig (BOILERPLATE - similar pattern)
// components/task_state.zig (BOILERPLATE - 350+ lines)
```

Total boilerplate: ~500 lines across 4+ files

## After (RFC #28 approach)

Games use tasks components directly:

```zig
// hooks/task_hooks.zig
const tasks = @import("labelle-tasks");
const Item = @import("../components/items.zig").ItemType;

pub fn game_init(payload: engine.HookPayload) void {
    const allocator = payload.game_init.allocator;

    // Create task engine (still needed for hooks)
    var task_engine = try allocator.create(tasks.Engine(u64, Item, TaskHooks));
    task_engine.* = tasks.Engine(u64, Item, TaskHooks).init(allocator, .{}, getDistance);

    // Connect tasks components to engine (ONE LINE!)
    tasks.setEngineInterface(u64, Item, task_engine.interface());
}

pub fn game_deinit(_: engine.HookPayload) void {
    tasks.clearEngineInterface(u64, Item);
}
```

```zig
// In scenes/main.zon - use tasks components directly
.entities = .{
    // Storage auto-registers with task engine via interface
    .{
        .components = .{
            .Position = .{ .x = 200, .y = 150 },
            .Storage = .{
                .role = .eis,
                .initial_item = .Flour,
            },
        },
    },

    // Worker auto-registers and becomes available
    .{
        .prefab = "baker",
        .components = .{
            .Position = .{ .x = 400, .y = 300 },
            .Worker = .{ .available = true },
        },
    },

    // Dangling item auto-registers for pickup
    .{
        .components = .{
            .Position = .{ .x = 100, .y = 150 },
            .DanglingItem = .{ .item_type = .Flour },
        },
    },
}
```

Total boilerplate: ~30 lines in one file

## API Reference

### Setting up the interface

```zig
const tasks = @import("labelle-tasks");
const Item = enum { Flour, Bread, Water };

// Create engine
var engine = tasks.Engine(u64, Item, MyHooks).init(allocator, .{}, distance_fn);

// Connect interface (components auto-register after this)
tasks.setEngineInterface(u64, Item, engine.interface());

// Later, cleanup
tasks.clearEngineInterface(u64, Item);
```

### Component types

```zig
// Storage - represents a slot that can hold one item
tasks.Storage(Item) = struct {
    role: StorageRole,          // .eis, .iis, .ios, .eos
    initial_item: ?Item = null, // Item in storage at creation
    accepts: ?Item = null,      // Item type this storage accepts (null = any)
};

// Worker - represents an entity that can perform work
tasks.Worker(Item) = struct {
    available: bool = true,     // Start as available?
};

// DanglingItem - represents an item not in storage
tasks.DanglingItem(Item) = struct {
    item_type: Item,            // What type of item this is
};
```

### Component callbacks

All components have built-in `onAdd` and `onRemove` callbacks that:
1. Access the ECS interface via `tasks.InterfaceStorage`
2. Register/unregister with the task engine automatically
3. Log warnings if interface not set

## Migration Steps

1. **Add dependency** on labelle-tasks (already using it)

2. **Update game_init hook** to call `tasks.setEngineInterface()`

3. **Replace wrapper components** with imports:
   ```zig
   // OLD
   pub const Storage = @import("components/storage.zig").Storage;

   // NEW
   const tasks = @import("labelle-tasks");
   pub const Storage = tasks.Storage(ItemType);
   ```

4. **Update ComponentRegistry** to use tasks components:
   ```zig
   pub const Components = engine.ComponentRegistry(struct {
       pub const Storage = tasks.Storage(Item);
       pub const Worker = tasks.Worker(Item);
       pub const DanglingItem = tasks.DanglingItem(Item);
   });
   ```

5. **Remove boilerplate files**:
   - components/storage.zig (use tasks.Storage)
   - components/worker.zig (use tasks.Worker)
   - components/dangling_item.zig (use tasks.DanglingItem)
   - components/task_state.zig (simplify to just engine init)

## What's Still Needed in Games

- **Workstation component**: Complex logic, game-specific
- **TaskHooks implementation**: Game-specific behavior for hooks
- **Distance function**: Game provides spatial queries
- **Movement script**: Game handles worker movement

## Limitations

- Workstation is not auto-registered (too complex)
- Games still need to define hooks for game-specific behavior
- The Item enum is still game-defined
