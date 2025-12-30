//! Test root - aggregates all test specs
const zspec = @import("zspec");

pub const engine_spec = @import("engine_spec.zig");

test {
    zspec.runAll(@This());
}
