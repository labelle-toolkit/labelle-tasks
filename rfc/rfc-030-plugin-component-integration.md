# RFC 030: Plugin Component Integration

## Status
Implemented (Partial)

## Summary

This RFC addresses the excessive boilerplate required to integrate labelle-tasks components into a game. Currently, games need to create multiple wrapper files just to re-export parameterized component types from the plugin.

## Problem Statement

### Current State

To use labelle-tasks in a game, the following boilerplate is required:

```
bakery-game/
├── components/
│   ├── items.zig           # ItemType enum (game-specific)
│   ├── storage.zig         # 5 lines - re-exports labelle_tasks.Storage(ItemType)
│   ├── worker.zig          # 5 lines - re-exports labelle_tasks.Worker(ItemType)
│   ├── dangling_item.zig   # 5 lines - re-exports labelle_tasks.DanglingItem(ItemType)
│   └── workstation.zig     # 5 lines - re-exports labelle_tasks.Workstation(ItemType)
├── lib/
│   └── task_state.zig      # Game hooks + Context
└── hooks/
    └── task_hooks.zig      # Init/deinit hooks
```

Each wrapper file is nearly identical:
```zig
const labelle_tasks = @import("labelle-tasks");
const items = @import("items.zig");
pub const Storage = labelle_tasks.Storage(items.ItemType);
```

### Root Causes

1. **Generator limitation**: The generator scans `components/` and assumes each `.zig` file exports a type matching its PascalCase name. It doesn't understand:
   - Re-exports from other modules
   - Parameterized types from plugins
   - Type aliases

2. **Circular dependency**: Plugin components need game-specific types (ItemType), but ItemType lives in `components/items.zig` which the generator also scans.

3. **Failed attempt with ComponentRegistryMulti**: We tried using `project.labelle`'s `.components` field:
   ```zig
   .plugins = .{
       .{
           .name = "labelle-tasks",
           .components = "Components(main_module.Items)",
       },
   },
   ```
   This failed with comptime resolution errors in `ComponentRegistryMulti` - the inline for loop couldn't resolve the plugin's component types at compile time.

## Proposed Solutions

### Option 1: `types/` Folder Convention

Add a `types/` folder for type definitions that aren't ECS components:

```
bakery-game/
├── types/
│   └── items.zig           # ItemType enum
├── components/
│   └── (component files only)
├── lib/
│   └── task_state.zig      # Context, hooks
```

**Benefits:**
- Clear separation between types and components
- Generator only scans `components/`, not `types/`
- Plugin can reference `types/items.zig` for parameterization

**Drawbacks:**
- Still need wrapper files in `components/` for labelle-tasks types
- Another folder to manage

### Option 2: Plugin Component Declaration in `project.labelle`

Extend `project.labelle` to declare plugin components explicitly:

```zig
.plugins = .{
    .{
        .name = "labelle-tasks",
        .path = "../../labelle-tasks",
        .component_types = .{
            .{ .name = "Storage", .type = "Storage", .param = "types.items.ItemType" },
            .{ .name = "Worker", .type = "Worker", .param = "types.items.ItemType" },
            .{ .name = "DanglingItem", .type = "DanglingItem", .param = "types.items.ItemType" },
            .{ .name = "Workstation", .type = "Workstation", .param = "types.items.ItemType" },
        },
    },
},
```

The generator would produce:
```zig
pub const Storage = labelle_tasks.Storage(types.items.ItemType);
pub const Worker = labelle_tasks.Worker(types.items.ItemType);
// etc.
```

**Benefits:**
- No wrapper files needed
- Explicit and type-safe
- Generator handles all the wiring

**Drawbacks:**
- Verbose configuration
- Need to update project.labelle when adding new component types

### Option 3: Plugin Initialization System

Create a formal plugin initialization system where plugins can hook into game startup:

```zig
// In labelle-tasks
pub const Plugin = struct {
    pub const components = .{
        .Storage = Storage,
        .Worker = Worker,
        .DanglingItem = DanglingItem,
        .Workstation = Workstation,
    };

    pub fn init(comptime ItemType: type) type {
        return struct {
            pub const Storage = labelle_tasks.Storage(ItemType);
            pub const Worker = labelle_tasks.Worker(ItemType);
            // etc.
        };
    }
};
```

Game declares:
```zig
// project.labelle
.plugins = .{
    .{
        .name = "labelle-tasks",
        .init = "Plugin.init(types.items.ItemType)",
    },
},
```

**Benefits:**
- Plugin controls its own initialization
- Clean separation of concerns
- Extensible for future plugin needs

**Drawbacks:**
- More complex plugin API
- Requires generator changes

### Option 4: lib/ Folder with Explicit Component Registration

Formalize the `lib/` folder pattern and add explicit component registration:

```zig
// lib/task_components.zig
const labelle_tasks = @import("labelle-tasks");
const items = @import("../types/items.zig");

pub const Components = struct {
    pub const Storage = labelle_tasks.Storage(items.ItemType);
    pub const Worker = labelle_tasks.Worker(items.ItemType);
    pub const DanglingItem = labelle_tasks.DanglingItem(items.ItemType);
    pub const Workstation = labelle_tasks.Workstation(items.ItemType);
};
```

```zig
// project.labelle
.lib_components = .{
    "lib/task_components.Components",
},
```

**Benefits:**
- Single file for all plugin components
- Explicit about what's being registered
- Keeps `components/` clean for game-specific components

**Drawbacks:**
- New config field
- Manual registration

### Option 5: Convention-Based Component Inclusion

Use a naming convention to include/exclude files from component scanning:

```
components/
├── _types/              # Prefixed with _ = not scanned
│   └── items.zig
├── _plugins/            # Plugin re-exports
│   └── tasks.zig        # All labelle-tasks re-exports
└── player.zig           # Normal component
```

Or use a `.labelle-ignore` pattern:
```
# .labelle-ignore
components/items.zig
```

**Benefits:**
- Familiar pattern (like .gitignore)
- No new config fields
- Flexible

**Drawbacks:**
- Magic naming conventions
- Easy to forget

## Recommendation

**Implemented: Merge task state into hooks file**

The simplest approach was adopted: merge `task_state.zig` directly into `hooks/task_hooks.zig`. This eliminates the `lib/` folder and keeps all task-related code in one place.

For component wrappers, the options remain open for future improvement:
- Option 2 (plugin component declaration) is the most promising
- Option 3 (plugin initialization system) offers the most flexibility

**Deferred: types/ folder and lib_components**

The original recommendation of `types/` folder + `lib_components` config was not implemented because:
1. The simpler hooks-based approach worked
2. Component wrappers, while verbose, are straightforward and understood
3. Generator changes would be required for the more advanced options

## Additional Consideration: Hook Organization

Currently, the generator scans `hooks/` for `.zig` files but does not support subfolders. Plugin-related hooks could benefit from subfolder organization:

```
hooks/
├── game_hooks.zig              # General game hooks
└── labelle-tasks/              # Plugin-specific hooks
    └── init.zig                # Task engine init/deinit
```

Or using a naming convention:
```
hooks/
├── game_hooks.zig
└── labelle_tasks_init.zig      # Plugin prefix in filename
```

### Generator Changes Needed

To support subfolders, `scanFolderWithExtension` would need to:
1. Recursively scan subdirectories
2. Generate imports with correct relative paths:
   ```zig
   const labelle_tasks_init_hooks = @import("hooks/labelle-tasks/init.zig");
   ```

This would allow cleaner organization where each plugin's hooks are grouped together, making it easier to:
- See which hooks belong to which plugin
- Remove a plugin's hooks by deleting one folder
- Keep game-specific hooks separate from plugin hooks

## Open Questions

1. Should `types/` be scanned for anything (e.g., auto-imports)?
2. Should plugins be able to declare required type parameters in their config?
3. How does this interact with the existing `.components` field on plugins?
4. Should `lib/` initialization happen before or during `game_init`?
5. Should `hooks/` support subfolders for plugin organization?

## Implementation Notes

After exploration, a simpler approach was adopted that eliminates the `lib/` folder entirely:

### Current Structure (Implemented)

```
bakery-game/
├── components/
│   ├── items.zig           # ItemType enum (game-specific)
│   ├── storage.zig         # 5 lines - re-exports labelle_tasks.Storage(ItemType)
│   ├── worker.zig          # 5 lines - re-exports labelle_tasks.Worker(ItemType)
│   ├── dangling_item.zig   # 5 lines - re-exports labelle_tasks.DanglingItem(ItemType)
│   └── workstation.zig     # 5 lines - re-exports labelle_tasks.Workstation(ItemType)
└── hooks/
    └── task_hooks.zig      # Context + GameHooks + engine hooks (init/deinit/scene_load)
```

### Key Insight

The `lib/task_state.zig` file was unnecessary complexity. Its contents were merged directly into `hooks/task_hooks.zig`:

```zig
// hooks/task_hooks.zig - Contains everything:
const tasks = @import("labelle-tasks");
const items = @import("../components/items.zig");

// Type definitions
pub const ItemType = items.ItemType;
pub const GameId = u64;

// Game-specific hooks (merged with LoggingHooks)
const GameHooks = struct {
    pub fn store_started(payload: anytype) void { ... }
    pub fn pickup_dangling_started(payload: anytype) void { ... }
    pub fn item_delivered(payload: anytype) void { ... }
};

pub const BakeryTaskHooks = tasks.MergeHooks(GameHooks, tasks.LoggingHooks);
pub const Context = tasks.TaskEngineContext(GameId, ItemType, BakeryTaskHooks);

// Re-exports for scripts
pub const MovementAction = Context.MovementAction;
pub const PendingMovement = Context.PendingMovement;

// Engine hooks
pub fn game_init(payload: engine.HookPayload) void { ... }
pub fn scene_load(payload: engine.HookPayload) void { ... }
pub fn game_deinit(payload: engine.HookPayload) void { ... }
```

### Remaining Boilerplate

Component wrapper files are still required because:
1. The generator scans `components/` and expects PascalCase type exports
2. `ComponentRegistryMulti` failed with comptime resolution errors when trying to include plugin components via `.components` field
3. The generator doesn't support parameterized type re-exports

### Future Improvements

The component wrapper problem could be solved by:
- Option 2 (plugin component declaration in project.labelle)
- Option 3 (plugin initialization system)
- Generator improvements to understand re-exports

For now, 4 small wrapper files is acceptable complexity.

## References

- RFC 028: Direct ECS Access
- RFC 031: TaskEngineContext (Issue #31)
- Issue #172: Module collision with plugins
