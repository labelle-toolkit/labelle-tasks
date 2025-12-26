const std = @import("std");
const zspec = @import("zspec");
const Factory = zspec.Factory;
const tasks = @import("labelle_tasks");

const factory_defs = @import("factories.zon");

// ============================================================================
// Test Types
// ============================================================================

pub const Item = enum { Vegetable, Meat, Meal, Water };
pub const TestEngine = tasks.EngineWithHooks(u32, Item, TestHooks);

// ============================================================================
// Standard Test IDs
// ============================================================================

pub const IDs = struct {
    // Workers
    pub const WORKER_1: u32 = 1;
    pub const WORKER_2: u32 = 2;

    // Workstations
    pub const WORKSTATION_1: u32 = 100;
    pub const WORKSTATION_2: u32 = 200;

    // Kitchen storages (primary)
    pub const EIS_VEG: u32 = 10;
    pub const EIS_VEG_2: u32 = 14;
    pub const EIS_MEAT: u32 = 11;
    pub const IIS_VEG: u32 = 20;
    pub const IIS_MEAT: u32 = 21;
    pub const IOS_MEAL: u32 = 12;
    pub const EOS_MEAL: u32 = 13;

    // Producer storages
    pub const IOS_WATER: u32 = 32;
    pub const EOS_WATER: u32 = 33;

    // Secondary workstation storages
    pub const IOS_WATER_2: u32 = 42;
    pub const EOS_WATER_2: u32 = 43;

    // Transport
    pub const SOURCE: u32 = 50;
    pub const DEST: u32 = 60;
    pub const GARDEN: u32 = 1;
};

// ============================================================================
// Hook Tracking
// ============================================================================

pub var g_pickup_started_calls: u32 = 0;
pub var g_process_started_calls: u32 = 0;
pub var g_process_complete_calls: u32 = 0;
pub var g_store_started_calls: u32 = 0;
pub var g_worker_released_calls: u32 = 0;
pub var g_transport_started_calls: u32 = 0;

pub fn resetHookCounters() void {
    g_pickup_started_calls = 0;
    g_process_started_calls = 0;
    g_process_complete_calls = 0;
    g_store_started_calls = 0;
    g_worker_released_calls = 0;
    g_transport_started_calls = 0;
}

pub const TestHooks = struct {
    pub fn pickup_started(_: tasks.hooks.HookPayload(u32, Item)) void {
        g_pickup_started_calls += 1;
    }

    pub fn process_started(_: tasks.hooks.HookPayload(u32, Item)) void {
        g_process_started_calls += 1;
    }

    pub fn process_completed(_: tasks.hooks.HookPayload(u32, Item)) void {
        g_process_complete_calls += 1;
    }

    pub fn store_started(_: tasks.hooks.HookPayload(u32, Item)) void {
        g_store_started_calls += 1;
    }

    pub fn worker_released(_: tasks.hooks.HookPayload(u32, Item)) void {
        g_worker_released_calls += 1;
    }

    pub fn transport_started(_: tasks.hooks.HookPayload(u32, Item)) void {
        g_transport_started_calls += 1;
    }
};

// ============================================================================
// Worker Callback
// ============================================================================

pub fn testFindBestWorker(
    workstation_id: ?u32,
    available_workers: []const u32,
) ?u32 {
    _ = workstation_id;
    if (available_workers.len > 0) {
        return available_workers[0];
    }
    return null;
}

// ============================================================================
// Engine Setup Helpers
// ============================================================================

/// Creates a test engine with common defaults
pub fn createEngine() TestEngine {
    var eng = TestEngine.init(std.testing.allocator);
    eng.setFindBestWorker(testFindBestWorker);
    return eng;
}

/// Kitchen configuration for recipes that transform inputs to outputs
pub const KitchenConfig = struct {
    eis_id: u32 = IDs.EIS_VEG,
    iis_id: u32 = IDs.IIS_VEG,
    ios_id: u32 = IDs.IOS_MEAL,
    eos_id: u32 = IDs.EOS_MEAL,
    workstation_id: u32 = IDs.WORKSTATION_1,
    process_duration: u32 = 5,
    input_item: Item = .Vegetable,
    output_item: Item = .Meal,
};

pub const KitchenFactory = Factory.defineFrom(KitchenConfig, factory_defs.kitchen);

/// Sets up a kitchen workstation with all storages
pub fn setupKitchen(eng: *TestEngine, config: KitchenConfig) void {
    _ = eng.addStorage(config.eis_id, .{ .item = config.input_item });
    _ = eng.addStorage(config.iis_id, .{ .item = config.input_item });
    _ = eng.addStorage(config.ios_id, .{ .item = config.output_item });
    _ = eng.addStorage(config.eos_id, .{ .item = config.output_item });

    _ = eng.addWorkstation(config.workstation_id, .{
        .eis = &.{config.eis_id},
        .iis = &.{config.iis_id},
        .ios = &.{config.ios_id},
        .eos = &.{config.eos_id},
        .process_duration = config.process_duration,
    });
}

/// Producer configuration for workstations that create outputs without inputs
pub const ProducerConfig = struct {
    ios_id: u32 = IDs.IOS_WATER,
    eos_id: u32 = IDs.EOS_WATER,
    workstation_id: u32 = IDs.WORKSTATION_1,
    process_duration: u32 = 3,
    output_item: Item = .Water,
    priority: tasks.Components.Priority = .Normal,
};

pub const ProducerFactory = Factory.defineFrom(ProducerConfig, factory_defs.producer);

/// Sets up a producer workstation (no inputs required)
pub fn setupProducer(eng: *TestEngine, config: ProducerConfig) void {
    _ = eng.addStorage(config.ios_id, .{ .item = config.output_item });
    _ = eng.addStorage(config.eos_id, .{ .item = config.output_item });

    _ = eng.addWorkstation(config.workstation_id, .{
        .ios = &.{config.ios_id},
        .eos = &.{config.eos_id},
        .process_duration = config.process_duration,
        .priority = config.priority,
    });
}

/// Transport configuration for moving items between storages
pub const TransportConfig = struct {
    from_id: u32 = IDs.SOURCE,
    to_id: u32 = IDs.DEST,
    item: Item = .Meal,
};

pub const TransportFactory = Factory.defineFrom(TransportConfig, factory_defs.transport);

/// Sets up a transport route between two storages
pub fn setupTransport(eng: *TestEngine, config: TransportConfig) void {
    _ = eng.addStorage(config.from_id, .{ .item = config.item });
    _ = eng.addStorage(config.to_id, .{ .item = config.item });

    _ = eng.addTransport(.{
        .from = config.from_id,
        .to = config.to_id,
        .item = config.item,
    });
}
