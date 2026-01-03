# RFC #28 Implementation Analysis

## Investigation Summary

This document analyzes how labelle-tasks can implement direct ECS access as proposed in RFC #28 (GitHub issue #28).

## Current Architecture

### Engine ECS Callback System

Both ECS adapters (zig_ecs, zflecs) use the same pattern:

1. **Component callbacks are static methods** on component structs:
   ```zig
   pub const MyComponent = struct {
       value: u32,

       pub fn onAdd(payload: ComponentPayload) void { ... }
       pub fn onRemove(payload: ComponentPayload) void { ... }
   };
   ```

2. **ComponentPayload** provides access to the game:
   ```zig
   pub const ComponentPayload = struct {
       entity_id: u64,
       game_ptr: *anyopaque,

       pub fn getGame(comptime T: type) *T {
           return @ptrCast(@alignCast(game_ptr));
       }
   };
   ```

3. **Global game_ptr** is set by engine during initialization
4. **No dynamic observer API** - callbacks must be declared at comptime

### Current Game Integration (bakery-game)

The game uses wrapper components that bridge to task_state:

```
bakery-game/components/storage.zig (wrapper)
  → Storage.onAdd()
    → task_state.addStorage()
      → task_engine.addStorage()
```

**Boilerplate involved:**
- 6 component wrapper files
- Global task_engine pointer in task_state.zig
- Global game_ptr/game_registry for hooks
- Manual sync between component data and task state

## Implementation Options

### Option A: Type-Erased Engine Interface (Recommended)

Tasks exports components with callbacks that use a type-erased interface:

```zig
// In labelle-tasks
pub const EngineInterface = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    const VTable = struct {
        registerStorage: *const fn(*anyopaque, u64, StorageConfig) anyerror!void,
        unregisterStorage: *const fn(*anyopaque, u64) void,
        registerWorker: *const fn(*anyopaque, u64) anyerror!void,
        unregisterWorker: *const fn(*anyopaque, u64) void,
        // ... other methods
    };
};

// Module-level interface pointer
var engine_interface: ?EngineInterface = null;

pub fn setEngineInterface(iface: EngineInterface) void {
    engine_interface = iface;
}

// Generic component that uses the interface
pub fn Storage(comptime Item: type) type {
    return struct {
        storage_type: StorageType,
        initial_item: ?Item = null,
        accepts: ?Item = null,

        pub fn onAdd(payload: engine.ComponentPayload) void {
            const iface = engine_interface orelse return;
            const entity = engine.entityFromU64(payload.entity_id);
            const registry = payload.getGame(engine.Game).getRegistry();
            const self = registry.tryGet(@This(), entity) orelse return;

            iface.vtable.registerStorage(iface.ptr, payload.entity_id, .{
                .role = self.storage_type,
                .initial_item = self.initial_item,
                .accepts = self.accepts,
            }) catch return;
        }

        pub fn onRemove(payload: engine.ComponentPayload) void {
            const iface = engine_interface orelse return;
            iface.vtable.unregisterStorage(iface.ptr, payload.entity_id);
        }
    };
}
```

**Game initialization:**
```zig
var task_engine = TaskEngine.init(allocator, ...);
tasks.setEngineInterface(task_engine.interface());
```

**Pros:**
- No engine changes required
- Tasks owns component definitions
- Single source of truth for component data
- Automatic registration/unregistration via ECS callbacks

**Cons:**
- Requires type erasure (small runtime cost)
- Tasks must import engine for ComponentPayload type

### Option B: Dynamic Observer API in Engine

Add dynamic callback registration to engine:

```zig
// In labelle-engine
pub fn Registry.observeAdd(comptime T: type, ctx: *anyopaque, callback: fn(*anyopaque, u64) void) void;
pub fn Registry.observeRemove(comptime T: type, ctx: *anyopaque, callback: fn(*anyopaque, u64) void) void;
```

**Tasks initialization:**
```zig
pub fn attachToECS(self: *Engine, registry: *Registry) void {
    registry.observeAdd(Storage, self, onStorageAdded);
    registry.observeAdd(Worker, self, onWorkerAdded);
    // ...
}
```

**Pros:**
- Clean API matching the RFC proposal
- Tasks doesn't need to import engine types
- Components remain pure data

**Cons:**
- Requires modifying both ECS adapters
- Both zig_ecs and zflecs have different underlying callback systems
- More complex implementation

### Option C: User Data on Game

Engine stores arbitrary user data that components can access:

```zig
// In engine
pub const Game = struct {
    user_data: ?*anyopaque = null,

    pub fn setUserData(ptr: *anyopaque) void { ... }
    pub fn getUserData(comptime T: type) ?*T { ... }
};

// In game initialization
game.setUserData(&task_engine);

// In component callback
const task_eng = payload.getGame(Game).getUserData(TaskEngine);
```

**Pros:**
- Simple to implement
- Flexible for other use cases

**Cons:**
- Doesn't solve the wrapper component problem
- Still need game-side component definitions

## Recommendation

**Option A (Type-Erased Interface)** is the most practical path forward because:

1. **No engine changes required** - Can be implemented entirely in labelle-tasks
2. **Incremental migration** - Games can adopt new pattern gradually
3. **Preserves type safety** - Generic Item type is preserved in components
4. **Single source of truth** - Component IS the task state

## Implementation Steps

1. **Phase 1: Define interface in tasks**
   - Add `EngineInterface` with vtable
   - Implement `interface()` method on `Engine` type
   - Add `setEngineInterface()` module function

2. **Phase 2: Export components from tasks**
   - Move Storage, Worker, Workstation, DanglingItem to tasks
   - Add onAdd/onRemove callbacks using interface
   - Export via `tasks.Storage(Item)`, etc.

3. **Phase 3: Update bakery-game**
   - Remove wrapper components
   - Use tasks components directly in prefabs
   - Call `tasks.setEngineInterface(engine.interface())` on init

4. **Phase 4: Test and validate**
   - Verify all callbacks fire correctly
   - Measure boilerplate reduction
   - Document migration guide

## Dependencies

Tasks needs to import engine for:
- `ComponentPayload` type
- `entityFromU64()` function
- `Game` type (to access registry)
- `Registry` type (to get component data)

This creates a compile-time dependency on engine, which is acceptable since tasks is designed as an engine plugin.

## Open Questions

1. Should tasks components support game extensions (additional fields)?
   - Current answer: Use composition with separate game components

2. How to handle standalone vs workstation-owned storages?
   - Keep the `standalone` flag or use different component types

3. Should hooks also be type-erased for consistency?
   - Current hook system works well, may not need changes
