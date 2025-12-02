const std = @import("std");
const zspec = @import("zspec");
const expect = zspec.expect;
const tasks = @import("labelle_tasks");
const ecs = @import("ecs");

const Registry = ecs.Registry;
const Entity = ecs.Entity;

const TaskGroupStatus = tasks.TaskGroupStatus;
const GroupSteps = tasks.GroupSteps;
const StepDef = tasks.StepDef;
const Priority = tasks.Priority;

// ============================================================================
// Test Components
// ============================================================================

const TestGroup = struct {
    status: TaskGroupStatus = .Blocked,
    priority: Priority = .Normal,
    steps: GroupSteps,

    const test_steps = [_]StepDef{
        .{ .type = .Pickup },
        .{ .type = .Cook },
    };

    pub fn init() TestGroup {
        return .{
            .status = .Blocked,
            .priority = .Normal,
            .steps = GroupSteps.init(&test_steps),
        };
    }
};

const TestWorker = struct {
    idle: bool = true,
};

const AssignedToGroup = struct {
    group: Entity,
};

const GroupAssignedWorker = struct {
    worker: Entity,
};

// ============================================================================
// Test Callbacks (with tracking)
// ============================================================================

var g_canUnblock_result: bool = true;
var g_canUnblock_calls: u32 = 0;

fn canUnblock(reg: *Registry, entity: Entity) bool {
    _ = reg;
    _ = entity;
    g_canUnblock_calls += 1;
    return g_canUnblock_result;
}

var g_isWorkerIdle_calls: u32 = 0;

fn isWorkerIdle(reg: *Registry, entity: Entity) bool {
    g_isWorkerIdle_calls += 1;
    const worker = reg.get(TestWorker, entity);
    return worker.idle;
}

var g_onAssigned_calls: u32 = 0;
var g_onAssigned_worker: ?Entity = null;
var g_onAssigned_group: ?Entity = null;

fn onAssigned(reg: *Registry, worker_entity: Entity, group_entity: Entity) void {
    _ = reg;
    g_onAssigned_calls += 1;
    g_onAssigned_worker = worker_entity;
    g_onAssigned_group = group_entity;
}

var g_shouldContinue_result: bool = false;
var g_shouldContinue_calls: u32 = 0;

fn shouldContinue(reg: *Registry, worker_entity: Entity, group_entity: Entity) bool {
    _ = reg;
    _ = worker_entity;
    _ = group_entity;
    g_shouldContinue_calls += 1;
    return g_shouldContinue_result;
}

var g_setWorkerIdle_calls: u32 = 0;

fn setWorkerIdle(reg: *Registry, worker_entity: Entity) void {
    g_setWorkerIdle_calls += 1;
    const worker = reg.get(TestWorker, worker_entity);
    worker.idle = true;
}

var g_onReleased_calls: u32 = 0;

fn onReleased(reg: *Registry, worker_entity: Entity, group_entity: Entity) void {
    _ = reg;
    _ = worker_entity;
    _ = group_entity;
    g_onReleased_calls += 1;
}

fn resetCallbacks() void {
    g_canUnblock_result = true;
    g_canUnblock_calls = 0;
    g_isWorkerIdle_calls = 0;
    g_onAssigned_calls = 0;
    g_onAssigned_worker = null;
    g_onAssigned_group = null;
    g_shouldContinue_result = false;
    g_shouldContinue_calls = 0;
    g_setWorkerIdle_calls = 0;
    g_onReleased_calls = 0;
}

// ============================================================================
// System Instantiations
// ============================================================================

const BlockedSystem = tasks.BlockedToQueuedSystem(
    TestGroup,
    GroupAssignedWorker,
    canUnblock,
);

const AssignmentSystem = tasks.WorkerAssignmentSystem(
    TestGroup,
    TestWorker,
    AssignedToGroup,
    GroupAssignedWorker,
    isWorkerIdle,
    onAssigned,
);

const CompletionSystem = tasks.GroupCompletionSystem(
    TestGroup,
    AssignedToGroup,
    GroupAssignedWorker,
    shouldContinue,
    setWorkerIdle,
    onReleased,
);

// ============================================================================
// Tests
// ============================================================================

pub const @"BlockedToQueuedSystem" = struct {
    pub const @"run" = struct {
        test "transitions Blocked group to Queued when canUnblock returns true" {
            resetCallbacks();
            var reg = Registry.init(std.testing.allocator);
            defer reg.deinit();

            const group_entity = reg.create();
            reg.add(group_entity, TestGroup.init());

            BlockedSystem.run(&reg);

            const group = reg.get(TestGroup, group_entity);
            try expect.equal(group.status, .Queued);
            try expect.equal(g_canUnblock_calls, 1);
        }

        test "keeps group Blocked when canUnblock returns false" {
            resetCallbacks();
            g_canUnblock_result = false;
            var reg = Registry.init(std.testing.allocator);
            defer reg.deinit();

            const group_entity = reg.create();
            reg.add(group_entity, TestGroup.init());

            BlockedSystem.run(&reg);

            const group = reg.get(TestGroup, group_entity);
            try expect.equal(group.status, .Blocked);
        }

        test "does not affect Queued groups" {
            resetCallbacks();
            var reg = Registry.init(std.testing.allocator);
            defer reg.deinit();

            const group_entity = reg.create();
            var g = TestGroup.init();
            g.status = .Queued;
            reg.add(group_entity, g);

            BlockedSystem.run(&reg);

            const group = reg.get(TestGroup, group_entity);
            try expect.equal(group.status, .Queued);
            try expect.equal(g_canUnblock_calls, 0);
        }

        test "does not affect Active groups" {
            resetCallbacks();
            var reg = Registry.init(std.testing.allocator);
            defer reg.deinit();

            const group_entity = reg.create();
            var g = TestGroup.init();
            g.status = .Active;
            reg.add(group_entity, g);

            BlockedSystem.run(&reg);

            const group = reg.get(TestGroup, group_entity);
            try expect.equal(group.status, .Active);
            try expect.equal(g_canUnblock_calls, 0);
        }

        test "transitions to Active if worker already assigned" {
            resetCallbacks();
            var reg = Registry.init(std.testing.allocator);
            defer reg.deinit();

            const worker_entity = reg.create();
            reg.add(worker_entity, TestWorker{});

            const group_entity = reg.create();
            reg.add(group_entity, TestGroup.init());
            reg.add(group_entity, GroupAssignedWorker{ .worker = worker_entity });

            BlockedSystem.run(&reg);

            const group = reg.get(TestGroup, group_entity);
            try expect.equal(group.status, .Active);
        }
    };
};

pub const @"WorkerAssignmentSystem" = struct {
    pub const @"run" = struct {
        test "assigns idle worker to queued group" {
            resetCallbacks();
            var reg = Registry.init(std.testing.allocator);
            defer reg.deinit();

            const worker_entity = reg.create();
            reg.add(worker_entity, TestWorker{ .idle = true });

            const group_entity = reg.create();
            var g = TestGroup.init();
            g.status = .Queued;
            reg.add(group_entity, g);

            AssignmentSystem.run(&reg);

            const group = reg.get(TestGroup, group_entity);
            try expect.equal(group.status, .Active);
            try expect.equal(g_onAssigned_calls, 1);
            try expect.equal(g_onAssigned_worker.?, worker_entity);
            try expect.equal(g_onAssigned_group.?, group_entity);

            // Check components were added
            const assigned = reg.get(AssignedToGroup, worker_entity);
            try expect.equal(assigned.group, group_entity);
            const group_assigned = reg.get(GroupAssignedWorker, group_entity);
            try expect.equal(group_assigned.worker, worker_entity);
        }

        test "does not assign busy worker" {
            resetCallbacks();
            var reg = Registry.init(std.testing.allocator);
            defer reg.deinit();

            const worker_entity = reg.create();
            reg.add(worker_entity, TestWorker{ .idle = false });

            const group_entity = reg.create();
            var g = TestGroup.init();
            g.status = .Queued;
            reg.add(group_entity, g);

            AssignmentSystem.run(&reg);

            const group = reg.get(TestGroup, group_entity);
            try expect.equal(group.status, .Queued);
            try expect.equal(g_onAssigned_calls, 0);
        }

        test "does not assign to Blocked groups" {
            resetCallbacks();
            var reg = Registry.init(std.testing.allocator);
            defer reg.deinit();

            const worker_entity = reg.create();
            reg.add(worker_entity, TestWorker{ .idle = true });

            const group_entity = reg.create();
            reg.add(group_entity, TestGroup.init()); // Blocked by default

            AssignmentSystem.run(&reg);

            const group = reg.get(TestGroup, group_entity);
            try expect.equal(group.status, .Blocked);
            try expect.equal(g_onAssigned_calls, 0);
        }

        test "does not assign to groups that already have workers" {
            resetCallbacks();
            var reg = Registry.init(std.testing.allocator);
            defer reg.deinit();

            const worker1 = reg.create();
            reg.add(worker1, TestWorker{ .idle = false });

            const worker2 = reg.create();
            reg.add(worker2, TestWorker{ .idle = true });

            const group_entity = reg.create();
            var g = TestGroup.init();
            g.status = .Queued;
            reg.add(group_entity, g);
            reg.add(group_entity, GroupAssignedWorker{ .worker = worker1 });

            AssignmentSystem.run(&reg);

            // worker2 should not be assigned because group already has worker1
            try expect.equal(g_onAssigned_calls, 0);
            try expect.equal(reg.tryGet(AssignedToGroup, worker2), null);
        }
    };
};

pub const @"GroupCompletionSystem" = struct {
    pub const @"run" = struct {
        test "resets completed group and releases worker when shouldContinue is false" {
            resetCallbacks();
            g_shouldContinue_result = false;
            var reg = Registry.init(std.testing.allocator);
            defer reg.deinit();

            const worker_entity = reg.create();
            reg.add(worker_entity, TestWorker{ .idle = false });

            const group_entity = reg.create();
            var g = TestGroup.init();
            g.status = .Active;
            g.steps.current_index = 2; // Complete (past last step)
            reg.add(group_entity, g);

            reg.add(worker_entity, AssignedToGroup{ .group = group_entity });
            reg.add(group_entity, GroupAssignedWorker{ .worker = worker_entity });

            CompletionSystem.run(&reg);

            const group = reg.get(TestGroup, group_entity);
            try expect.equal(group.status, .Blocked);
            try expect.equal(group.steps.current_index, 0); // Reset
            try expect.equal(g_shouldContinue_calls, 1);
            try expect.equal(g_setWorkerIdle_calls, 1);
            try expect.equal(g_onReleased_calls, 1);

            // Assignment components should be removed
            try expect.equal(reg.tryGet(AssignedToGroup, worker_entity), null);
            try expect.equal(reg.tryGet(GroupAssignedWorker, group_entity), null);
        }

        test "keeps worker assigned when shouldContinue is true" {
            resetCallbacks();
            g_shouldContinue_result = true;
            var reg = Registry.init(std.testing.allocator);
            defer reg.deinit();

            const worker_entity = reg.create();
            reg.add(worker_entity, TestWorker{ .idle = false });

            const group_entity = reg.create();
            var g = TestGroup.init();
            g.status = .Active;
            g.steps.current_index = 2; // Complete
            reg.add(group_entity, g);

            reg.add(worker_entity, AssignedToGroup{ .group = group_entity });
            reg.add(group_entity, GroupAssignedWorker{ .worker = worker_entity });

            CompletionSystem.run(&reg);

            const group = reg.get(TestGroup, group_entity);
            try expect.equal(group.status, .Blocked);
            try expect.equal(group.steps.current_index, 0); // Reset
            try expect.equal(g_shouldContinue_calls, 1);
            try expect.equal(g_setWorkerIdle_calls, 0); // Not called
            try expect.equal(g_onReleased_calls, 0); // Not called

            // Assignment components should still exist
            try expect.notEqual(reg.tryGet(AssignedToGroup, worker_entity), null);
            try expect.notEqual(reg.tryGet(GroupAssignedWorker, group_entity), null);
        }

        test "does not process incomplete groups" {
            resetCallbacks();
            var reg = Registry.init(std.testing.allocator);
            defer reg.deinit();

            const worker_entity = reg.create();
            reg.add(worker_entity, TestWorker{ .idle = false });

            const group_entity = reg.create();
            var g = TestGroup.init();
            g.status = .Active;
            g.steps.current_index = 1; // Not complete (has 2 steps)
            reg.add(group_entity, g);

            reg.add(worker_entity, AssignedToGroup{ .group = group_entity });
            reg.add(group_entity, GroupAssignedWorker{ .worker = worker_entity });

            CompletionSystem.run(&reg);

            const group = reg.get(TestGroup, group_entity);
            try expect.equal(group.status, .Active); // Unchanged
            try expect.equal(group.steps.current_index, 1); // Unchanged
            try expect.equal(g_shouldContinue_calls, 0);
        }

        test "does not process non-Active groups" {
            resetCallbacks();
            var reg = Registry.init(std.testing.allocator);
            defer reg.deinit();

            const worker_entity = reg.create();
            reg.add(worker_entity, TestWorker{ .idle = false });

            const group_entity = reg.create();
            var g = TestGroup.init();
            g.status = .Blocked; // Not Active
            g.steps.current_index = 2; // Complete
            reg.add(group_entity, g);

            reg.add(worker_entity, AssignedToGroup{ .group = group_entity });
            reg.add(group_entity, GroupAssignedWorker{ .worker = worker_entity });

            CompletionSystem.run(&reg);

            const group = reg.get(TestGroup, group_entity);
            try expect.equal(group.status, .Blocked); // Unchanged
            try expect.equal(group.steps.current_index, 2); // Unchanged
            try expect.equal(g_shouldContinue_calls, 0);
        }
    };
};
