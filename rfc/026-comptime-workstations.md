# RFC 026: Comptime-Sized Workstation Arrays

**Status**: Draft
**Issue**: [#26](https://github.com/labelle-toolkit/labelle-tasks/issues/26)
**Author**: @alexandrecalvao
**Created**: 2025-12-26

## Summary

Workstations use comptime-sized arrays for storage references, with labelle-tasks managing a registry of workstation types.

## Motivation

Comptime-sized arrays offer:
- Zero runtime allocation
- Exact memory usage
- Compile-time guarantees on storage counts
- Self-contained workstation definitions

## Proposed Design

### 1. Generic Workstation Type

```zig
pub fn TaskWorkstation(
    comptime eis_count: usize,
    comptime iis_count: usize,
    comptime ios_count: usize,
    comptime eos_count: usize,
) type {
    return struct {
        pub const EIS_COUNT = eis_count;
        pub const IIS_COUNT = iis_count;
        pub const IOS_COUNT = ios_count;
        pub const EOS_COUNT = eos_count;

        // Storage entity references (filled by loader)
        eis: [eis_count]Entity = [_]Entity{Entity.invalid} ** eis_count,
        iis: [iis_count]Entity = [_]Entity{Entity.invalid} ** iis_count,
        ios: [ios_count]Entity = [_]Entity{Entity.invalid} ** ios_count,
        eos: [eos_count]Entity = [_]Entity{Entity.invalid} ** eos_count,
    };
}
```

The comptime workstation holds only **storage references**. All configuration and runtime state lives in `TaskWorkstationBinding`.

### 2. Game Defines Workstation Types in Components Folder

The game generates comptime workstation types in its components folder:

```zig
// game/components/workstations.zig
const tasks = @import("labelle-tasks");

pub const KitchenWorkstation = tasks.TaskWorkstation(2, 2, 1, 1);  // 2 EIS, 2 IIS, 1 IOS, 1 EOS
pub const WellWorkstation = tasks.TaskWorkstation(0, 0, 1, 1);     // Producer: no inputs
pub const FarmWorkstation = tasks.TaskWorkstation(1, 1, 3, 3);     // Multiple outputs
pub const OvenWorkstation = tasks.TaskWorkstation(1, 2, 1, 1);     // 1 EIS, 2 IIS (flour + water)
```

These are registered as regular ECS components alongside other game components.

### 3. ECS Component Registration

The game registers each workstation type as a regular ECS component:

```zig
// game/components.zig
const workstations = @import("components/workstations.zig");
const tasks = @import("labelle-tasks");

pub const Components = struct {
    // Game components
    pub const Position = @import("components/position.zig").Position;
    pub const Sprite = @import("components/sprite.zig").Sprite;

    // Workstation types (each is a separate component)
    pub const KitchenWorkstation = workstations.KitchenWorkstation;
    pub const WellWorkstation = workstations.WellWorkstation;
    pub const FarmWorkstation = workstations.FarmWorkstation;
    pub const OvenWorkstation = workstations.OvenWorkstation;

    // Common binding component for queries
    pub const TaskWorkstationBinding = tasks.TaskWorkstationBinding;
    pub const TaskStorage = tasks.TaskStorage;
    pub const TaskStorageRole = tasks.TaskStorageRole;
};
```

No separate registry needed - the ECS handles storage and queries for each component type.

### 4. Prefab Integration

Prefabs use the specific workstation component type directly. Storage entities are defined inline within the component fields (following labelle-engine's entity reference pattern):

```zig
// prefabs/kitchen.zon
.{
    .components = .{
        .Position = .{ .x = 0, .y = 0 },
        .Sprite = .{ .name = "kitchen.png" },
        // Storage references only
        .KitchenWorkstation = .{
            .eis = .{
                .{ .components = .{ .TaskStorage = .{ .priority = .High }, .Position = .{ .x = -20, .y = 0 } } },
                .{ .components = .{ .TaskStorage = .{}, .Position = .{ .x = -20, .y = 10 } } },
            },
            .iis = .{
                .{ .components = .{ .TaskStorage = .{} } },  // Internal, no position needed
                .{ .components = .{ .TaskStorage = .{} } },
            },
            .ios = .{
                .{ .components = .{ .TaskStorage = .{} } },
            },
            .eos = .{
                .{ .components = .{ .TaskStorage = .{ .priority = .High }, .Position = .{ .x = 20, .y = 0 } } },
            },
        },
        // Configuration and runtime state
        .TaskWorkstationBinding = .{ .process_duration = 40, .priority = .High },
    },
}
```

Or using prefab references for reusable storages:

```zig
// prefabs/kitchen.zon
.{
    .components = .{
        .Position = .{ .x = 0, .y = 0 },
        .Sprite = .{ .name = "kitchen.png" },
        .KitchenWorkstation = .{
            .eis = .{
                .{ .prefab = "vegetable_crate", .components = .{ .Position = .{ .x = -20, .y = 0 } } },
                .{ .prefab = "meat_storage", .components = .{ .Position = .{ .x = -20, .y = 10 } } },
            },
            .iis = .{
                .{ .components = .{ .TaskStorage = .{} } },
                .{ .components = .{ .TaskStorage = .{} } },
            },
            .ios = .{
                .{ .components = .{ .TaskStorage = .{} } },
            },
            .eos = .{
                .{ .prefab = "meal_plate", .components = .{ .Position = .{ .x = 20, .y = 0 } } },
            },
        },
        .TaskWorkstationBinding = .{ .process_duration = 40, .priority = .High },
    },
}
```

The loader would:
1. Create workstation entity with `KitchenWorkstation` + `TaskWorkstationBinding` components
2. For each storage field (`eis`, `iis`, `ios`, `eos`), create entities from inline definitions or prefab references
3. Fill the workstation's arrays with the created entity references

### 5. Binding Component (Configuration + Runtime State)

Since each workstation type is a different component, we need a common binding component that holds **configuration and runtime state**:

```zig
// labelle-tasks provides this binding component
pub const TaskWorkstationBinding = struct {
    // Configuration
    process_duration: u32 = 0,
    priority: Priority = .Normal,

    // Runtime state
    status: WorkstationStatus = .Blocked,
    assigned_worker: ?Entity = null,
    process_timer: u32 = 0,
    current_step: StepType = .Pickup,

    // Track which EIS/EOS was selected for current cycle
    selected_eis: ?Entity = null,
    selected_eos: ?Entity = null,
};
```

**Usage pattern:**

Every entity with a workstation component also gets a `TaskWorkstationBinding`:

```zig
// When creating a kitchen workstation entity
registry.addComponent(entity, KitchenWorkstation{ .eis = eis_entities, .iis = iis_entities, ... });
registry.addComponent(entity, TaskWorkstationBinding{ .process_duration = 40, .priority = .High });

// Query ALL workstations regardless of type
var iter = registry.query(TaskWorkstationBinding);
while (iter.next()) |entity, binding| {
    if (binding.status == .Queued) {
        // Found a workstation ready for work
        // Get storage references from the specific component
        if (registry.tryGet(entity, KitchenWorkstation)) |kitchen| {
            // kitchen.eis, kitchen.iis, kitchen.ios, kitchen.eos
        } else if (registry.tryGet(entity, WellWorkstation)) |well| {
            // well.ios, well.eos (producer has no inputs)
        }
    }
}
```

The binding component:
- **Holds configuration** - process_duration, priority
- **Holds runtime state** - status, assigned worker, timers, step tracking
- **Enables uniform queries** - Find all workstations with a single query
- **Storage references** - Retrieved from the specific workstation component

### 6. Common Interface Trait

For code that needs to work with any workstation type:

```zig
pub fn WorkstationInterface(comptime T: type) type {
    return struct {
        pub fn getEis(ws: *const T) []const Entity {
            return &ws.eis;
        }

        pub fn getIis(ws: *const T) []const Entity {
            return &ws.iis;
        }

        pub fn getIos(ws: *const T) []const Entity {
            return &ws.ios;
        }

        pub fn getEos(ws: *const T) []const Entity {
            return &ws.eos;
        }

        pub fn isProducer(ws: *const T) bool {
            return T.EIS_COUNT == 0 and T.IIS_COUNT == 0;
        }

        pub fn totalStorages(ws: *const T) usize {
            _ = ws;
            return T.EIS_COUNT + T.IIS_COUNT + T.IOS_COUNT + T.EOS_COUNT;
        }
    };
}
```

## Trade-offs

### Advantages

1. **Zero runtime allocation** - All storage arrays are fixed-size
2. **Compile-time validation** - Can't accidentally add wrong number of storages
3. **Self-contained** - Workstation component has all its data
4. **No indirection** - Direct array access, no HashMap lookups
5. **Memory predictability** - Exact memory usage known at compile time

### Disadvantages

1. **Multiple component types** - Each workstation variant is a different type (mitigated by `TaskWorkstationBinding`)
2. **Prefab complexity** - Loader must map prefab name to correct type
3. **Less flexible** - Adding a new workstation type requires code changes (acceptable trade-off)
4. **ECS query complexity** - Can't query "all workstations" directly (solved by binding component)
5. **Registration boilerplate** - Must list all types in registry

## Design Decisions

### 1. ECS Query Unification via Binding Component

Each workstation type is registered as a separate ECS component. To query all workstations uniformly, every workstation entity also has a `TaskWorkstationBinding` component.

```zig
// Query all workstations via binding
var iter = registry.query(TaskWorkstationBinding);
while (iter.next()) |entity, binding| {
    if (binding.status == .Queued) {
        // Get actual workstation from specific component
        if (registry.tryGet(entity, KitchenWorkstation)) |kitchen| {
            // ...
        }
    }
}
```

### 2. Workstation Types in Components Folder

The game defines comptime workstation types in its components folder, alongside other ECS components:

```
game/
├── components/
│   ├── workstations.zig    # KitchenWorkstation, WellWorkstation, etc.
│   ├── player.zig
│   └── ...
└── ...
```

This keeps workstation definitions close to other game-specific component definitions and makes them available to the prefab loader.

### 3. No Upgradeable Workstations

Workstations are immutable in their storage configuration. To "upgrade" a workstation:

1. Destroy the old workstation entity (and its child storages)
2. Create a new workstation entity with the upgraded type

```zig
// Upgrading a kitchen
fn upgradeKitchen(entity: Entity) void {
    // Save any state that needs to persist
    const position = registry.get(entity, Position);

    // Destroy old workstation (children are destroyed too)
    registry.destroy(entity);

    // Create upgraded workstation
    const new_entity = prefab_loader.instantiate("kitchen_upgraded", position);
}
```

This is simpler than tracking active/inactive storages and avoids runtime complexity.

### 4. Pure Comptime - No Hybrid

All workstation types are comptime-defined. No dynamic/runtime workstation creation.

**Rationale:**
- Simpler mental model
- Better optimization (no dynamic dispatch)
- Games know their workstation types at compile time
- If a new workstation type is needed, it's a code change (which is fine)

## Next Steps

1. Prototype `TaskWorkstation` generic type with 2-3 workstation variants
2. Test ECS integration with labelle-engine component system
3. Implement prefab loader support for filling storage arrays
4. Implement `TaskWorkstationBinding` sync logic

## References

- [Zig comptime generic patterns](https://ziglang.org/documentation/master/#Generic-Structs)
