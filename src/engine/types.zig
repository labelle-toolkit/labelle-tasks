//! Shared types for the labelle-tasks engine module.

const root = @import("../root.zig");

/// Re-export Priority from components.
pub const Priority = root.Components.Priority;

/// Step types for workstation workflows.
pub const StepType = enum {
    Pickup, // Transfer EIS -> IIS
    Process, // Transform IIS -> IOS (timed)
    Store, // Transfer IOS -> EOS
};
