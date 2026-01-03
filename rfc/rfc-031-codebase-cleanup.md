# RFC 031: labelle-tasks Codebase Cleanup

**Issue:** https://github.com/labelle-toolkit/labelle-tasks/issues/32

## Summary

Remove backward compatibility code, unused features, and redundant patterns from labelle-tasks to improve clarity and reduce maintenance burden. This cleanup is based on actual usage patterns observed in bakery-game.

## Motivation

The labelle-tasks codebase has accumulated technical debt through multiple iterations:
- Backward compatibility code for patterns no longer recommended
- Duplicate functions that do the same thing
- ~250 lines of boilerplate that could be simplified
- Unused features that add complexity without benefit

The bakery-game demonstrates the actual integration pattern games should use. Code not exercised by this reference implementation should be scrutinized.

## Current State Analysis

### What bakery-game actually uses:

**Components:**
- `Storage(Item)`, `Worker(Item)`, `DanglingItem(Item)`, `Workstation(Item)`

**Context API:**
- `Context.init()`, `Context.deinit()`
- `Context.pickupCompleted()`, `Context.storeCompleted()`, `Context.danglingPickupCompleted()`
- `Context.getEngine()`, `Context.evaluateDanglingItems()`

**Hook implementations (3 of 14 available):**
- `store_started` - Sets MovementTarget component
- `pickup_dangling_started` - Sets MovementTarget component
- `item_delivered` - Positions item in storage

**NOT used by bakery-game:**
- `transport_started`, `transport_completed` hooks
- `process_started`, `cycle_completed` hooks (logged but not implemented)
- `worker_assigned`, `worker_released` hooks
- `workstation_blocked`, `workstation_queued`, `workstation_activated` hooks
- Custom worker selection callback
- Custom distance function
- Priority system
- `hooks` namespace backward compat
- `EngineWithHooks` alias
- `Components()` duplicate of `bind()`

## Proposed Changes

### Phase 1: Safe Removals (No Risk)

#### 1.1 Remove `EngineWithHooks` alias

```zig
// REMOVE from root.zig (line 546-548)
pub fn EngineWithHooks(comptime GameId: type, comptime Item: type, comptime Hooks: type) type {
    return Engine(GameId, Item, Hooks);
}
```

**Rationale:** Zero added value, just use `Engine` directly.

#### 1.2 Remove duplicate `Components()` function

```zig
// REMOVE from root.zig (lines 275-282)
pub fn Components(comptime Item: type) type {
    return struct {
        pub const Storage = storage_comp.Storage(Item);
        pub const Worker = worker_comp.Worker(Item);
        pub const DanglingItem = dangling_comp.DanglingItem(Item);
        pub const Workstation = workstation_comp.Workstation(Item);
    };
}
```

**Rationale:** Identical to `bind()`. Keep `bind()` as it matches labelle plugin convention.

#### 1.3 Remove `hooks` namespace backward compat

```zig
// REMOVE from root.zig (lines 116-161)
pub const hooks = struct {
    pub const TaskHookPayload = hooks_mod.TaskHookPayload;
    pub const GameHookPayload = hooks_mod.GameHookPayload;
    pub const HookDispatcher = hooks_mod.HookDispatcher;

    pub fn MergeTasksHooks(comptime PrimaryHooks: type, comptime _: type) type {
        return PrimaryHooks; // Does nothing useful
    }

    pub fn HookPayload(comptime GameId: type, comptime Item: type) type {
        return TaskHookPayload(GameId, Item);
    }
};
```

**Rationale:**
- `MergeTasksHooks` returns first argument unchanged (broken)
- No games use `labelle_tasks.hooks.*` pattern
- Direct imports are cleaner: `const TaskHookPayload = labelle_tasks.TaskHookPayload;`

### Phase 2: Remove Unused Features

#### 2.1 Remove Priority system

```zig
// REMOVE from types.zig
pub const Priority = enum(u8) {
    Low = 0,
    Normal = 1,
    High = 2,
    Critical = 3,
};

// REMOVE priority field from WorkstationData in state.zig
priority: Priority = .Normal,

// REMOVE from WorkstationConfig in engine.zig
priority: Priority = .Normal,
```

**Rationale:** Never consulted in any logic. Workstations are processed in hashmap iteration order regardless of priority.

#### 2.2 ~~Remove transport hooks~~ KEEP

**Decision:** Keep all 14 hooks. They will be used by future game implementations.

#### 2.3 Remove Movement Queue from TaskEngineContext

```zig
// REMOVE from context.zig (lines 243-289)
pub const MovementAction = enum { ... };
pub const PendingMovement = struct { ... };
var pending_movements: std.ArrayListUnmanaged(PendingMovement) = .{};
pub fn queueMovement(...) void { ... }
pub fn takePendingMovements() []PendingMovement { ... }
pub fn freePendingMovements(slice: []PendingMovement) void { ... }
fn clearMovementQueue() void { ... }
```

**Rationale:** Replaced by component-based `MovementTarget` approach. The queue pattern required polling; components are reactive.

### Phase 3: Simplify Boilerplate

#### 3.1 Simplify `MergeHooks` in logging_hooks.zig

Current implementation has 114 lines manually repeating every hook. Replace with comptime generation:

```zig
pub fn MergeHooks(comptime Primary: type, comptime Fallback: type) type {
    return struct {
        inline fn dispatch(comptime hook_name: []const u8, payload: anytype) void {
            if (@hasDecl(Primary, hook_name)) {
                @field(Primary, hook_name)(payload);
            } else if (@hasDecl(Fallback, hook_name)) {
                @field(Fallback, hook_name)(payload);
            }
        }

        // Generate all hook functions at comptime
        pub usingnamespace GenerateHookFunctions(@This(), Primary, Fallback);
    };
}
```

**Savings:** ~70 lines of boilerplate removed.

#### 3.2 Simplify hook wrappers in `createEngineHooks`

Current: 99 lines of identical wrapper functions, one per hook.

Refactor to use comptime iteration:

```zig
fn WrappedHooks(comptime GameHooks: type) type {
    return struct {
        // Generate wrappers for all hooks that exist in GameHooks
        pub usingnamespace GenerateEnrichedWrappers(GameHooks);
    };
}
```

**Savings:** ~80 lines of boilerplate removed.

#### 3.3 Simplify EnrichedPayload

Current approach conditionally includes every possible field. Instead, define a single enriched struct:

```zig
pub fn EnrichedPayload(comptime Original: type) type {
    return struct {
        original: Original,
        registry: ?*Registry,
        game: ?*Game,

        pub fn get(self: @This(), comptime field: []const u8) @TypeOf(@field(Original, field)) {
            return @field(self.original, field);
        }
    };
}
```

**Benefits:** Clearer intent, simpler implementation, same functionality.

### Phase 4: Clarify Public API

#### 4.1 Update root.zig exports

After cleanup, the public API should be:

```zig
// Core types
pub const Engine = engine_mod.Engine;
pub const TaskHookPayload = hooks_mod.TaskHookPayload;
pub const GameHookPayload = hooks_mod.GameHookPayload;

// Enums
pub const WorkerState = types.WorkerState;
pub const WorkstationStatus = types.WorkstationStatus;
pub const StepType = types.StepType;
pub const StorageRole = state_mod.StorageRole;

// Integration helpers
pub const TaskEngineContext = context_mod.TaskEngineContext;
pub const createEngineHooks = // simplified version

// ECS components (plugin pattern)
pub const bind = // component bundle
pub const Storage = storage_comp.Storage;
pub const Worker = worker_comp.Worker;
pub const DanglingItem = dangling_comp.DanglingItem;
pub const Workstation = workstation_comp.Workstation;

// Optional utilities
pub const LoggingHooks = logging_hooks.LoggingHooks;
pub const MergeHooks = logging_hooks.MergeHooks;
pub const NoHooks = struct {};
```

**Removed from public API:**
- `EngineWithHooks` (use `Engine`)
- `Components` (use `bind`)
- `hooks` namespace (use direct imports)
- `HookDispatcher` (internal detail)
- `EcsInterface` (internal detail)
- `InterfaceStorage` (internal detail)

## Migration Guide

### For games using old patterns:

```zig
// OLD
const tasks = @import("labelle-tasks");
const HookPayload = tasks.hooks.HookPayload(u64, Item);
const Engine = tasks.EngineWithHooks(u64, Item, MyHooks);

// NEW
const tasks = @import("labelle-tasks");
const TaskHookPayload = tasks.TaskHookPayload;
const Engine = tasks.Engine(u64, Item, MyHooks);
```

### For games using movement queue:

```zig
// OLD (in hooks)
pub fn store_started(payload: anytype) void {
    Context.queueMovement(payload.worker_id, x, y, .store);
}

// In update loop
const movements = Context.takePendingMovements();
defer Context.freePendingMovements(movements);
for (movements) |m| { ... }

// NEW (component-based)
pub fn store_started(payload: anytype) void {
    const registry = payload.registry orelse return;
    const worker = engine.entityFromU64(payload.worker_id);
    registry.set(worker, MovementTarget{ .target_x = x, .target_y = y, .action = .store });
}

// In update loop - query for MovementTarget components
var view = registry.view(.{ MovementTarget, Position });
```

## Impact Assessment

| Change | Lines Removed | Risk | Benefit |
|--------|--------------|------|---------|
| Remove `EngineWithHooks` | 3 | None | Clarity |
| Remove `Components()` | 8 | None | Clarity |
| Remove `hooks` namespace | 45 | Low | Clarity |
| Remove Priority | 15 | Low | Simplicity |
| Remove movement queue | 50 | Medium | Simplicity |
| Simplify MergeHooks | 70 | Medium | Maintainability |
| Simplify hook wrappers | 80 | Medium | Maintainability |
| **Total** | **~270 lines** | | |

## Testing Strategy

1. Ensure bakery-game still passes delivery validation test
2. Run existing unit tests in `test/engine_spec.zig`
3. Verify no compile errors with simplified API
4. Document any behavior changes

## Timeline

- Phase 1: Immediate (safe removals)
- Phase 2: Next iteration (unused features)
- Phase 3: When touching affected code (boilerplate)
- Phase 4: With next major version (API clarification)

## Open Questions

1. Should Priority be kept but documented as "planned feature"?
2. Is the `hooks` namespace used by any other games in the ecosystem?

## References

- RFC 028: Work Completion Model
- RFC 029: Task Engine as Pure State Machine
- RFC 030: Plugin Component Integration
- bakery-game reference implementation
