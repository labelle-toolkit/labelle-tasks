//! Coordination ECS components for labelle-tasks
//!
//! Pure data components for game-side task state tracking.
//! These are set/removed manually by game hooks (no auto-registration callbacks).
//! Exported via bind() so games don't need to define their own.
//!
//! These components enable ECS-based save/load by ensuring all task-related
//! state lives in ECS components rather than scattered HashMaps.

/// Tracks which item entity is stored in a storage slot.
/// Set on storage entities when an item is placed, removed when picked up or consumed.
/// Replaces game-side `storage_items` HashMaps.
pub const StoredItem = struct {
    item_entity: u64,
};

/// Tracks which item entity a worker is currently carrying.
/// Set on worker entities when picking up an item, removed on delivery or consumption.
/// Replaces game-side `worker_carried_items` HashMaps.
pub const CarriedItem = struct {
    item_entity: u64,
};

/// Tracks which workstation a worker is currently assigned to.
/// Set on worker entities when assigned by the task engine, removed on worker_released.
/// Replaces game-side `worker_workstation` HashMaps.
pub const AssignedWorkstation = struct {
    workstation_id: u64,
};

/// Tracks an in-flight EOS→EIS transport assignment.
/// Set on worker entities when transport is assigned, removed on delivery completion.
/// Replaces game-side `worker_transport_from/to` and `pending_transports` HashMaps.
pub const TransportTask = struct {
    from_storage: u64,
    to_storage: u64,
};

/// Tracks the storage a worker is walking to for a store action.
/// Set on worker entities when store_started fires, removed when store completes.
/// Replaces game-side `worker_store_target` HashMaps.
pub const StoreTarget = struct {
    storage_id: u64,
};

/// Tracks the storage a worker is walking to for a pickup action.
/// Set on worker entities when pickup_started fires, removed when pickup completes.
/// Replaces game-side `worker_pickup_storage` HashMaps.
pub const PickupSource = struct {
    storage_id: u64,
};

/// Tracks the target storage for a dangling item delivery.
/// Set on worker entities when pickup_dangling_started fires, removed on delivery.
/// Replaces game-side `dangling_item_targets` HashMaps.
pub const DanglingTarget = struct {
    storage_id: u64,
};

/// Marker component indicating a worker is in the arrival phase.
/// Set on worker entities when they arrive at a workstation, removed after processing.
/// Uses padding field because the ECS doesn't support tryGet on zero-sized types.
pub const PendingArrival = struct {
    _padding: u8 = 0,
};
