//! Core types for the task engine

/// Worker state in the task engine
pub const WorkerState = enum {
    Idle, // Available for assignment
    Working, // Assigned to workstation
    Unavailable, // Temporarily unavailable (eating, sleeping, etc.)
};

/// Workstation status
pub const WorkstationStatus = enum {
    Blocked, // Missing inputs or outputs full
    Queued, // Ready for worker assignment
    Active, // Worker assigned and working
};

/// Step in the workstation workflow
pub const StepType = enum {
    Pickup, // Worker picking up from EIS to IIS
    Process, // Worker processing at workstation
    Store, // Worker storing from IOS to EOS
};

/// Priority for ordering
pub const Priority = enum(u8) {
    Low = 0,
    Normal = 1,
    High = 2,
    Critical = 3,
};

/// Target type for worker movement
pub const TargetType = enum {
    workstation,
    storage,
    dangling_item,
};
