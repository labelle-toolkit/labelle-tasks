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
const StepType = tasks.StepType;
const Priority = tasks.Priority;
const WorkerState = tasks.WorkerState;

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

// ============================================================================
// Standard Components Tests
// ============================================================================

pub const @"Worker" = struct {
    pub const @"init" = struct {
        test "defaults to Idle state" {
            const worker = tasks.Worker{};
            try expect.equal(worker.state, WorkerState.Idle);
        }
    };

    pub const @"isIdle" = struct {
        test "returns true when Idle" {
            const worker = tasks.Worker{ .state = .Idle };
            try expect.equal(worker.isIdle(), true);
        }

        test "returns false when Working" {
            const worker = tasks.Worker{ .state = .Working };
            try expect.equal(worker.isIdle(), false);
        }

        test "returns false when Blocked" {
            const worker = tasks.Worker{ .state = .Blocked };
            try expect.equal(worker.isIdle(), false);
        }
    };

    pub const @"isAvailable" = struct {
        test "returns true when Idle" {
            const worker = tasks.Worker{ .state = .Idle };
            try expect.equal(worker.isAvailable(), true);
        }

        test "returns false when Working" {
            const worker = tasks.Worker{ .state = .Working };
            try expect.equal(worker.isAvailable(), false);
        }

        test "returns false when Blocked" {
            const worker = tasks.Worker{ .state = .Blocked };
            try expect.equal(worker.isAvailable(), false);
        }
    };
};

pub const @"WorkerState enum" = struct {
    test "has three states" {
        try expect.equal(@typeInfo(WorkerState).@"enum".fields.len, 3);
    }

    test "includes Idle state" {
        const state: WorkerState = .Idle;
        try expect.equal(state, .Idle);
    }

    test "includes Working state" {
        const state: WorkerState = .Working;
        try expect.equal(state, .Working);
    }

    test "includes Blocked state" {
        const state: WorkerState = .Blocked;
        try expect.equal(state, .Blocked);
    }
};

// ============================================================================
// TaskRunner Tests (fully event-driven)
// ============================================================================

var g_runner_shouldContinue: bool = false;
var g_runner_startStep_calls: u32 = 0;
var g_runner_onReleased_calls: u32 = 0;
var g_runner_last_step_type: ?StepType = null;

fn runnerStartStep(reg: *Registry, worker: Entity, group: Entity, step: StepDef) void {
    _ = reg;
    _ = worker;
    _ = group;
    g_runner_startStep_calls += 1;
    g_runner_last_step_type = step.type;
}

fn runnerShouldContinue(reg: *Registry, worker: Entity, group: Entity) bool {
    _ = reg;
    _ = worker;
    _ = group;
    return g_runner_shouldContinue;
}

fn runnerOnReleased(reg: *Registry, worker: Entity, group: Entity) void {
    _ = reg;
    _ = worker;
    _ = group;
    g_runner_onReleased_calls += 1;
}

fn resetRunnerCallbacks() void {
    g_runner_shouldContinue = false;
    g_runner_startStep_calls = 0;
    g_runner_onReleased_calls = 0;
    g_runner_last_step_type = null;
}

const TestRunner = tasks.TaskRunner(
    TestGroup,
    runnerStartStep,
    runnerShouldContinue,
    runnerOnReleased,
);

pub const @"TaskRunner" = struct {
    pub const @"signalResourcesAvailable" = struct {
        test "triggers Blocked -> Queued -> Active when worker available" {
            resetRunnerCallbacks();
            var reg = Registry.init(std.testing.allocator);
            defer reg.deinit();

            TestRunner.setup(&reg);

            const worker = reg.create();
            reg.add(worker, tasks.Worker{});

            const group = reg.create();
            reg.add(group, TestGroup.init()); // Blocked initially

            // Signal resources available - should assign worker and start step
            TestRunner.signalResourcesAvailable(&reg, group);

            try expect.equal(g_runner_startStep_calls, 1);
            try expect.equal(g_runner_last_step_type.?, .Pickup);

            const worker_comp = reg.get(tasks.Worker, worker);
            try expect.equal(worker_comp.state, .Working);

            const group_comp = reg.get(TestGroup, group);
            try expect.equal(group_comp.status, .Active);
        }

        test "transitions to Queued when no worker available" {
            resetRunnerCallbacks();
            var reg = Registry.init(std.testing.allocator);
            defer reg.deinit();

            TestRunner.setup(&reg);

            // No worker created
            const group = reg.create();
            reg.add(group, TestGroup.init());

            TestRunner.signalResourcesAvailable(&reg, group);

            try expect.equal(g_runner_startStep_calls, 0);

            const group_comp = reg.get(TestGroup, group);
            try expect.equal(group_comp.status, .Queued);
        }

        test "starts first step when worker already assigned (continuing cycle)" {
            resetRunnerCallbacks();
            var reg = Registry.init(std.testing.allocator);
            defer reg.deinit();

            TestRunner.setup(&reg);

            const worker = reg.create();
            reg.add(worker, tasks.Worker{ .state = .Working });

            const group = reg.create();
            reg.add(group, TestGroup.init());

            // Simulate already assigned (continuing from previous cycle)
            reg.add(worker, tasks.AssignedToGroup{ .group = group });
            reg.add(group, tasks.GroupAssignedWorker{ .worker = worker });

            TestRunner.signalResourcesAvailable(&reg, group);

            try expect.equal(g_runner_startStep_calls, 1);

            const group_comp = reg.get(TestGroup, group);
            try expect.equal(group_comp.status, .Active);
        }
    };

    pub const @"signalWorkerIdle" = struct {
        test "assigns idle worker to queued group" {
            resetRunnerCallbacks();
            var reg = Registry.init(std.testing.allocator);
            defer reg.deinit();

            TestRunner.setup(&reg);

            const worker = reg.create();
            reg.add(worker, tasks.Worker{ .state = .Idle });

            const group = reg.create();
            var g = TestGroup.init();
            g.status = .Queued;
            reg.add(group, g);

            // Signal worker became idle - should match with queued group
            TestRunner.signalWorkerIdle(&reg, worker);

            try expect.equal(g_runner_startStep_calls, 1);

            const worker_comp = reg.get(tasks.Worker, worker);
            try expect.equal(worker_comp.state, .Working);
        }

        test "does nothing when no queued groups" {
            resetRunnerCallbacks();
            var reg = Registry.init(std.testing.allocator);
            defer reg.deinit();

            TestRunner.setup(&reg);

            const worker = reg.create();
            reg.add(worker, tasks.Worker{ .state = .Idle });

            // No groups
            TestRunner.signalWorkerIdle(&reg, worker);

            try expect.equal(g_runner_startStep_calls, 0);
        }
    };

    pub const @"completeStep" = struct {
        test "advances to next step" {
            resetRunnerCallbacks();
            var reg = Registry.init(std.testing.allocator);
            defer reg.deinit();

            TestRunner.setup(&reg);

            const worker = reg.create();
            reg.add(worker, tasks.Worker{ .state = .Working });

            const group = reg.create();
            var g = TestGroup.init();
            g.status = .Active;
            reg.add(group, g);

            reg.add(worker, tasks.AssignedToGroup{ .group = group });
            reg.add(group, tasks.GroupAssignedWorker{ .worker = worker });

            // Complete first step
            TestRunner.completeStep(&reg, worker);

            try expect.equal(g_runner_startStep_calls, 1);
            try expect.equal(g_runner_last_step_type.?, .Cook);

            const group_comp = reg.get(TestGroup, group);
            try expect.equal(group_comp.steps.current_index, 1);
        }

        test "handles cycle completion when all steps done" {
            resetRunnerCallbacks();
            var reg = Registry.init(std.testing.allocator);
            defer reg.deinit();

            TestRunner.setup(&reg);

            const worker = reg.create();
            reg.add(worker, tasks.Worker{ .state = .Working });

            const group = reg.create();
            var g = TestGroup.init();
            g.status = .Active;
            g.steps.current_index = 1; // On last step
            reg.add(group, g);

            reg.add(worker, tasks.AssignedToGroup{ .group = group });
            reg.add(group, tasks.GroupAssignedWorker{ .worker = worker });

            // Complete last step - should trigger release
            TestRunner.completeStep(&reg, worker);

            try expect.equal(g_runner_onReleased_calls, 1);

            const worker_comp = reg.get(tasks.Worker, worker);
            try expect.equal(worker_comp.state, .Idle);

            const group_comp = reg.get(TestGroup, group);
            try expect.equal(group_comp.status, .Blocked);
            try expect.equal(group_comp.steps.current_index, 0); // Reset
        }

        test "keeps worker assigned when shouldContinue returns true" {
            resetRunnerCallbacks();
            g_runner_shouldContinue = true;
            var reg = Registry.init(std.testing.allocator);
            defer reg.deinit();

            TestRunner.setup(&reg);

            const worker = reg.create();
            reg.add(worker, tasks.Worker{ .state = .Working });

            const group = reg.create();
            var g = TestGroup.init();
            g.status = .Active;
            g.steps.current_index = 1; // On last step
            reg.add(group, g);

            reg.add(worker, tasks.AssignedToGroup{ .group = group });
            reg.add(group, tasks.GroupAssignedWorker{ .worker = worker });

            TestRunner.completeStep(&reg, worker);

            try expect.equal(g_runner_onReleased_calls, 0);

            // Worker still assigned
            try expect.notEqual(reg.tryGet(tasks.AssignedToGroup, worker), null);
            try expect.notEqual(reg.tryGet(tasks.GroupAssignedWorker, group), null);

            // Group blocked waiting for resources
            const group_comp = reg.get(TestGroup, group);
            try expect.equal(group_comp.status, .Blocked);
        }
    };

    pub const @"full workflow" = struct {
        test "runs complete cycle: resources -> assign -> steps -> release" {
            resetRunnerCallbacks();
            var reg = Registry.init(std.testing.allocator);
            defer reg.deinit();

            TestRunner.setup(&reg);

            const worker = reg.create();
            reg.add(worker, tasks.Worker{});

            const group = reg.create();
            reg.add(group, TestGroup.init());

            // 1. Signal resources available
            TestRunner.signalResourcesAvailable(&reg, group);
            try expect.equal(g_runner_startStep_calls, 1);
            try expect.equal(g_runner_last_step_type.?, .Pickup);

            // 2. Complete Pickup step
            TestRunner.completeStep(&reg, worker);
            try expect.equal(g_runner_startStep_calls, 2);
            try expect.equal(g_runner_last_step_type.?, .Cook);

            // 3. Complete Cook step - cycle done
            TestRunner.completeStep(&reg, worker);
            try expect.equal(g_runner_onReleased_calls, 1);

            // Final state
            const final_worker = reg.get(tasks.Worker, worker);
            try expect.equal(final_worker.state, .Idle);

            const final_group = reg.get(TestGroup, group);
            try expect.equal(final_group.status, .Blocked);

            // Worker unassigned
            try expect.equal(reg.tryGet(tasks.AssignedToGroup, worker), null);
        }

        test "worker released can be assigned to another group" {
            resetRunnerCallbacks();
            var reg = Registry.init(std.testing.allocator);
            defer reg.deinit();

            TestRunner.setup(&reg);

            const worker = reg.create();
            reg.add(worker, tasks.Worker{});

            const group1 = reg.create();
            reg.add(group1, TestGroup.init());

            const group2 = reg.create();
            var g2 = TestGroup.init();
            g2.status = .Queued; // Already queued waiting for worker
            reg.add(group2, g2);

            // Work on group1
            TestRunner.signalResourcesAvailable(&reg, group1);
            TestRunner.completeStep(&reg, worker);
            TestRunner.completeStep(&reg, worker);

            // Worker released - should automatically be assigned to group2
            // (WorkerBecameIdle signal is fired internally)
            try expect.equal(g_runner_startStep_calls, 3); // 2 for group1, 1 for group2

            const worker_comp = reg.get(tasks.Worker, worker);
            try expect.equal(worker_comp.state, .Working);

            const assigned = reg.get(tasks.AssignedToGroup, worker);
            try expect.equal(assigned.group, group2);
        }
    };

    pub const @"tick" = struct {
        test "tick does nothing (fully event-driven)" {
            resetRunnerCallbacks();
            var reg = Registry.init(std.testing.allocator);
            defer reg.deinit();

            TestRunner.setup(&reg);

            const worker = reg.create();
            reg.add(worker, tasks.Worker{});

            const group = reg.create();
            reg.add(group, TestGroup.init());

            // tick() should do nothing - no automatic transitions
            TestRunner.tick(&reg);
            TestRunner.tick(&reg);
            TestRunner.tick(&reg);

            try expect.equal(g_runner_startStep_calls, 0);

            const group_comp = reg.get(TestGroup, group);
            try expect.equal(group_comp.status, .Blocked); // Still blocked
        }
    };

    pub const @"blocked workers" = struct {
        test "does not assign Blocked workers" {
            resetRunnerCallbacks();
            var reg = Registry.init(std.testing.allocator);
            defer reg.deinit();

            TestRunner.setup(&reg);

            const worker = reg.create();
            reg.add(worker, tasks.Worker{ .state = .Blocked });

            const group = reg.create();
            reg.add(group, TestGroup.init());

            TestRunner.signalResourcesAvailable(&reg, group);

            // Worker is blocked, should not be assigned
            try expect.equal(g_runner_startStep_calls, 0);
            try expect.equal(reg.tryGet(tasks.AssignedToGroup, worker), null);

            const group_comp = reg.get(TestGroup, group);
            try expect.equal(group_comp.status, .Queued); // Waiting for worker
        }
    };
};
