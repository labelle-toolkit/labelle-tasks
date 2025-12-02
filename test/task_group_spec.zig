const zspec = @import("zspec");
const expect = zspec.expect;
const tasks = @import("labelle_tasks");

pub const @"TaskGroup" = struct {
    const TG = tasks.TaskGroup;
    const TGStatus = tasks.TaskGroupStatus;
    const Priority = tasks.Priority;
    const InterruptLevel = tasks.InterruptLevel;

    pub const @"init" = struct {
        test "creates a group with Blocked status" {
            const group = TG.init(.Normal);
            try expect.equal(group.status, TGStatus.Blocked);
        }

        test "creates a group with the given priority" {
            const group = TG.init(.Critical);
            try expect.equal(group.priority, Priority.Critical);
        }

        test "creates a group with None interrupt level by default" {
            const group = TG.init(.Normal);
            try expect.equal(group.interrupt_level, InterruptLevel.None);
        }

        test "creates a Low priority group" {
            const group = TG.init(.Low);
            try expect.equal(group.priority, Priority.Low);
        }

        test "creates a High priority group" {
            const group = TG.init(.High);
            try expect.equal(group.priority, Priority.High);
        }
    };

    pub const @"withInterruptLevel" = struct {
        test "sets the interrupt level to Low" {
            const group = TG.init(.Normal).withInterruptLevel(.Low);
            try expect.equal(group.interrupt_level, InterruptLevel.Low);
        }

        test "sets the interrupt level to High" {
            const group = TG.init(.Normal).withInterruptLevel(.High);
            try expect.equal(group.interrupt_level, InterruptLevel.High);
        }

        test "sets the interrupt level to Atomic" {
            const group = TG.init(.Normal).withInterruptLevel(.Atomic);
            try expect.equal(group.interrupt_level, InterruptLevel.Atomic);
        }

        test "preserves the original status" {
            const group = TG.init(.Normal).withInterruptLevel(.High);
            try expect.equal(group.status, TGStatus.Blocked);
        }

        test "preserves the original priority" {
            const group = TG.init(.Critical).withInterruptLevel(.High);
            try expect.equal(group.priority, Priority.Critical);
        }
    };
};
