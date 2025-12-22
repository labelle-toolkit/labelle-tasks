const zspec = @import("zspec");
const expect = zspec.expect;
const tasks = @import("labelle_tasks");

pub const @"Priority" = struct {
    const Pri = tasks.Components.Priority;
    pub const @"enum values" = struct {
        test "has four levels" {
            const priorities = [_]Pri{ .Low, .Normal, .High, .Critical };
            try expect.equal(priorities.len, 4);
        }

        test "Low is less than Normal" {
            try expect.equal(@intFromEnum(Pri.Low) < @intFromEnum(Pri.Normal), true);
        }

        test "Normal is less than High" {
            try expect.equal(@intFromEnum(Pri.Normal) < @intFromEnum(Pri.High), true);
        }

        test "High is less than Critical" {
            try expect.equal(@intFromEnum(Pri.High) < @intFromEnum(Pri.Critical), true);
        }

        test "Critical is the highest priority" {
            try expect.equal(@intFromEnum(Pri.Critical) > @intFromEnum(Pri.High), true);
        }
    };
};
