const zspec = @import("zspec");
const expect = zspec.expect;
const tasks = @import("labelle_tasks");

pub const @"Task" = struct {
    const T = tasks.Task;
    const Priority = tasks.Priority;
    const TaskStatus = tasks.TaskStatus;
    const InterruptLevel = tasks.InterruptLevel;

    pub const @"init" = struct {
        test "creates a task with Queued status" {
            const task = T.init(.Normal);
            try expect.equal(task.status, TaskStatus.Queued);
        }

        test "creates a task with the given priority" {
            const task = T.init(.High);
            try expect.equal(task.priority, Priority.High);
        }

        test "creates a task with None interrupt level by default" {
            const task = T.init(.Normal);
            try expect.equal(task.interrupt_level, InterruptLevel.None);
        }

        test "creates a Low priority task" {
            const task = T.init(.Low);
            try expect.equal(task.priority, Priority.Low);
        }

        test "creates a Critical priority task" {
            const task = T.init(.Critical);
            try expect.equal(task.priority, Priority.Critical);
        }
    };

    pub const @"withInterruptLevel" = struct {
        test "sets the interrupt level to Low" {
            const task = T.init(.Normal).withInterruptLevel(.Low);
            try expect.equal(task.interrupt_level, InterruptLevel.Low);
        }

        test "sets the interrupt level to High" {
            const task = T.init(.Normal).withInterruptLevel(.High);
            try expect.equal(task.interrupt_level, InterruptLevel.High);
        }

        test "sets the interrupt level to Atomic" {
            const task = T.init(.Normal).withInterruptLevel(.Atomic);
            try expect.equal(task.interrupt_level, InterruptLevel.Atomic);
        }

        test "preserves the original status" {
            const task = T.init(.Normal).withInterruptLevel(.High);
            try expect.equal(task.status, TaskStatus.Queued);
        }

        test "preserves the original priority" {
            const task = T.init(.Critical).withInterruptLevel(.High);
            try expect.equal(task.priority, Priority.Critical);
        }
    };
};
