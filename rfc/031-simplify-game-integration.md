# RFC 031: Simplify Game Integration

## Summary

Reduce boilerplate in games using labelle-tasks by moving common patterns into the library itself.

## Problem

Currently, games like bakery-game need a `task_state.zig` file with ~300 lines of boilerplate:

```zig
// Current game code requirements:
1. Custom vtable wrapping for ensureContext
2. Global game_registry/game_ptr management
3. BakeryTaskHooks struct with all hook handlers
4. Movement queue for deferred worker movement
5. Init/deinit/getEngine wrappers
```

This pattern must be duplicated in every game using labelle-tasks.

## Analysis: Which Library Should Own What?

### Option A: Keep in labelle-tasks only

**Pros:**
- No labelle-engine changes needed
- Games can use labelle-tasks standalone

**Cons:**
- labelle-tasks needs labelle-engine dependency (already added for RFC #28)
- Hook receivers are game-specific

**What could move:**
- `ensureContext` pattern could be default behavior
- Movement queue could be a reusable struct

### Option B: Split between labelle-tasks and labelle-engine

**Pros:**
- Clean separation of concerns
- Engine handles ECS integration, tasks handles workflow

**Cons:**
- More complex dependency graph
- Tighter coupling between libraries

**Possible split:**
- labelle-engine: `TaskIntegration` component that auto-wires context
- labelle-tasks: Generic hook dispatcher with game callbacks

### Option C: Add labelle-tasks-engine bridge library

**Pros:**
- Keeps core libraries minimal
- Games only import what they need

**Cons:**
- Another dependency to manage
- More moving parts

## Recommendation

**Option A with improvements to labelle-tasks:**

1. **Auto-context via ComponentPayload** (already implemented in RFC #28)
   - Workstation.onAdd calls `ensureContext(game, registry)` from payload
   - Games implement `ensureContext` in their vtable

2. **Generic movement queue** in labelle-tasks
   ```zig
   pub fn MovementQueue(comptime GameId: type) type { ... }
   ```

3. **Simplified hook wiring**
   ```zig
   // Game just provides a struct with the hooks they care about
   const MyHooks = struct {
       pub fn store_started(payload: anytype) void { ... }
   };
   ```

## Implementation Plan

### Phase 1: Document current patterns
- [x] Analyze bakery-game task_state.zig
- [ ] Document which parts are truly game-specific

### Phase 2: Extract reusable parts
- [ ] MovementQueue generic struct
- [ ] Default ensureContext behavior

### Phase 3: Simplify hook wiring
- [ ] Allow partial hook implementations
- [ ] Provide sensible defaults for common patterns

## Files Involved

- `labelle-tasks/src/components.zig` - ensureContext already called
- `labelle-tasks/src/ecs_bridge.zig` - VTable with ensureContext
- `bakery-game/components/task_state.zig` - Target for simplification

## Open Questions

1. Should movement queuing be part of labelle-tasks or remain game-specific?
2. How much hook customization do games typically need?
3. Should we provide a "batteries included" integration helper?

## Related

- Issue #31: Simplify task_state.zig boilerplate
- RFC #28: Direct ECS Access
- RFC #26: Prefab Integration
