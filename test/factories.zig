//! Test factories for labelle-tasks
//!
//! Provides consistent test data using zspec Factory pattern.

const zspec = @import("zspec");
const Factory = zspec.Factory;
const tasks = @import("labelle_tasks");

const factory_defs = @import("factories.zon");

// ============================================================================
// Standard Workstation Types
// ============================================================================

/// Oven: 1 EIS, 2 IIS, 1 IOS, 1 EOS
pub const OvenWorkstation = tasks.TaskWorkstation(
    factory_defs.oven.eis_count,
    factory_defs.oven.iis_count,
    factory_defs.oven.ios_count,
    factory_defs.oven.eos_count,
);

/// Well (producer): 0 EIS, 0 IIS, 1 IOS, 1 EOS
pub const WellWorkstation = tasks.TaskWorkstation(
    factory_defs.well.eis_count,
    factory_defs.well.iis_count,
    factory_defs.well.ios_count,
    factory_defs.well.eos_count,
);

/// Mixer: 2 EIS, 3 IIS, 2 IOS, 1 EOS
pub const MixerWorkstation = tasks.TaskWorkstation(
    factory_defs.mixer.eis_count,
    factory_defs.mixer.iis_count,
    factory_defs.mixer.ios_count,
    factory_defs.mixer.eos_count,
);

// ============================================================================
// Standard Test IDs
// ============================================================================

pub const IDs = struct {
    // Workers
    pub const WORKER_1: u64 = 1;
    pub const WORKER_2: u64 = 2;

    // Workstations
    pub const OVEN: u64 = 100;
    pub const WELL: u64 = 101;
    pub const MIXER: u64 = 102;
};

// ============================================================================
// Binding Factory
// ============================================================================

pub const BindingConfig = struct {
    process_duration: u32 = factory_defs.default_binding.process_duration,
    priority: tasks.Priority = factory_defs.default_binding.priority,
};

pub const BindingFactory = Factory.defineFrom(BindingConfig, factory_defs.default_binding);

/// Create a TaskWorkstationBinding with factory defaults
pub fn createBinding(config: BindingConfig) tasks.TaskWorkstationBinding {
    return .{
        .process_duration = config.process_duration,
        .priority = config.priority,
    };
}

/// Create a fast processing binding
pub fn createFastBinding() tasks.TaskWorkstationBinding {
    return .{
        .process_duration = factory_defs.fast_binding.process_duration,
        .priority = factory_defs.fast_binding.priority,
    };
}

// ============================================================================
// Storage Factory
// ============================================================================

pub const StorageConfig = struct {
    priority: tasks.Priority = factory_defs.empty_storage.priority,
    has_item: bool = factory_defs.empty_storage.has_item,
};

pub const StorageFactory = Factory.defineFrom(StorageConfig, factory_defs.empty_storage);

/// Create a TaskStorage with factory defaults
pub fn createStorage(config: StorageConfig) tasks.TaskStorage {
    return .{
        .priority = config.priority,
        .has_item = config.has_item,
    };
}

/// Create an empty storage
pub fn createEmptyStorage() tasks.TaskStorage {
    return .{
        .priority = factory_defs.empty_storage.priority,
        .has_item = factory_defs.empty_storage.has_item,
    };
}

/// Create a full storage
pub fn createFullStorage() tasks.TaskStorage {
    return .{
        .priority = factory_defs.full_storage.priority,
        .has_item = factory_defs.full_storage.has_item,
    };
}

/// Create a high priority storage
pub fn createHighPriorityStorage() tasks.TaskStorage {
    return .{
        .priority = factory_defs.high_priority_storage.priority,
        .has_item = factory_defs.high_priority_storage.has_item,
    };
}

// ============================================================================
// Entity Factory
// ============================================================================

/// Create a valid entity with given id
pub fn createEntity(id: u64) tasks.Entity {
    return .{ .id = id };
}

/// Create a worker entity
pub fn createWorker(id: u64) tasks.Entity {
    return .{ .id = id };
}
