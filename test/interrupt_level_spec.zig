const zspec = @import("zspec");
const expect = zspec.expect;
const tasks = @import("labelle_tasks");

pub const @"InterruptLevel" = struct {
    const IL = tasks.InterruptLevel;

    pub const @"enum values" = struct {
        test "has four levels" {
            const levels = [_]IL{ .None, .Low, .High, .Atomic };
            try expect.equal(levels.len, 4);
        }

        test "None allows all interrupts" {
            // None is the default, most interruptible level
            try expect.equal(@intFromEnum(IL.None), 0);
        }

        test "Atomic is the highest protection level" {
            try expect.equal(@intFromEnum(IL.Atomic) > @intFromEnum(IL.High), true);
        }
    };
};
