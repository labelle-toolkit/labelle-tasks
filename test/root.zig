//! Test root - aggregates all test specs
const zspec = @import("zspec");

pub const workstation_spec = @import("workstation_spec.zig");
pub const storage_spec = @import("storage_spec.zig");
pub const binding_spec = @import("binding_spec.zig");
pub const plugin_spec = @import("plugin_spec.zig");

test {
    zspec.runAll(@This());
}
