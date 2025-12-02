//! Test root - aggregates all test specs
const zspec = @import("zspec");

pub const priority_spec = @import("priority_spec.zig");
pub const engine_spec = @import("engine_spec.zig");

test {
    zspec.runAll(@This());
}
