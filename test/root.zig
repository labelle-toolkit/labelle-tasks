//! Test root - aggregates all test specs
const zspec = @import("zspec");

pub const priority_spec = @import("priority_spec.zig");
pub const interrupt_level_spec = @import("interrupt_level_spec.zig");
pub const task_spec = @import("task_spec.zig");
pub const task_group_spec = @import("task_group_spec.zig");
pub const group_steps_spec = @import("group_steps_spec.zig");
pub const can_interrupt_spec = @import("can_interrupt_spec.zig");
pub const systems_spec = @import("systems_spec.zig");

test {
    zspec.runAll(@This());
}
