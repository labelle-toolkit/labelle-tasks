const std = @import("std");
const zspec = @import("zspec");
const expect = zspec.expect;
const tasks = @import("labelle_tasks");

const StepType = tasks.StepType;
const StepDef = tasks.StepDef;
const Priority = tasks.Priority;

// ============================================================================
// Test Callbacks
// ============================================================================

var g_step_started_calls: u32 = 0;
var g_step_completed_calls: u32 = 0;
var g_worker_released_calls: u32 = 0;
var g_should_continue_result: bool = false;
var g_last_step_type: ?StepType = null;

fn resetCallbacks() void {
    g_step_started_calls = 0;
    g_step_completed_calls = 0;
    g_worker_released_calls = 0;
    g_should_continue_result = false;
    g_last_step_type = null;
}

fn testFindBestWorker(
    workstation_id: u32,
    step: StepType,
    available_workers: []const u32,
) ?u32 {
    _ = workstation_id;
    _ = step;
    if (available_workers.len > 0) {
        return available_workers[0];
    }
    return null;
}

fn testOnStepStarted(
    worker_id: u32,
    workstation_id: u32,
    step: StepDef,
) void {
    _ = worker_id;
    _ = workstation_id;
    g_step_started_calls += 1;
    g_last_step_type = step.type;
}

fn testOnStepCompleted(
    worker_id: u32,
    workstation_id: u32,
    step: StepDef,
) void {
    _ = worker_id;
    _ = workstation_id;
    _ = step;
    g_step_completed_calls += 1;
}

fn testOnWorkerReleased(
    worker_id: u32,
    workstation_id: u32,
) void {
    _ = worker_id;
    _ = workstation_id;
    g_worker_released_calls += 1;
}

fn testShouldContinue(
    workstation_id: u32,
    worker_id: u32,
    cycles_completed: u32,
) bool {
    _ = workstation_id;
    _ = worker_id;
    _ = cycles_completed;
    return g_should_continue_result;
}

// ============================================================================
// Engine Tests
// ============================================================================

pub const @"Engine" = struct {
    pub const @"init and deinit" = struct {
        test "creates engine without error" {
            var engine = tasks.Engine(u32).init(std.testing.allocator);
            defer engine.deinit();
        }
    };

    pub const @"addWorker" = struct {
        test "adds a worker" {
            var engine = tasks.Engine(u32).init(std.testing.allocator);
            defer engine.deinit();

            _ = engine.addWorker(1, .{});
            // Worker was added successfully if we can get its state
            const state = engine.getWorkerState(1);
            try expect.notEqual(state, null);
        }

        test "worker starts as Idle" {
            var engine = tasks.Engine(u32).init(std.testing.allocator);
            defer engine.deinit();

            _ = engine.addWorker(1, .{});
            const state = engine.getWorkerState(1);
            try expect.equal(state.?, .Idle);
        }
    };

    pub const @"addWorkstation" = struct {
        test "adds a workstation" {
            var engine = tasks.Engine(u32).init(std.testing.allocator);
            defer engine.deinit();

            const steps = [_]StepDef{.{ .type = .Pickup }};
            _ = engine.addWorkstation(100, .{ .steps = &steps });
            // Workstation was added successfully if we can get its status
            const status = engine.getWorkstationStatus(100);
            try expect.notEqual(status, null);
        }

        test "workstation starts as Blocked" {
            var engine = tasks.Engine(u32).init(std.testing.allocator);
            defer engine.deinit();

            const steps = [_]StepDef{.{ .type = .Pickup }};
            _ = engine.addWorkstation(100, .{ .steps = &steps });
            const status = engine.getWorkstationStatus(100);
            try expect.equal(status.?, .Blocked);
        }
    };

    pub const @"notifyResourcesAvailable" = struct {
        test "assigns idle worker to workstation" {
            resetCallbacks();
            var engine = tasks.Engine(u32).init(std.testing.allocator);
            defer engine.deinit();

            engine.setFindBestWorker(testFindBestWorker);
            engine.setOnStepStarted(testOnStepStarted);

            _ = engine.addWorker(1, .{});

            const steps = [_]StepDef{.{ .type = .Pickup }};
            _ = engine.addWorkstation(100, .{ .steps = &steps });

            engine.notifyResourcesAvailable(100);

            try expect.equal(g_step_started_calls, 1);
            try expect.equal(g_last_step_type.?, .Pickup);
            try expect.equal(engine.getWorkerState(1).?, .Working);
            try expect.equal(engine.getWorkstationStatus(100).?, .Active);
        }

        test "transitions to Queued when no worker available" {
            resetCallbacks();
            var engine = tasks.Engine(u32).init(std.testing.allocator);
            defer engine.deinit();

            const steps = [_]StepDef{.{ .type = .Pickup }};
            _ = engine.addWorkstation(100, .{ .steps = &steps });

            engine.notifyResourcesAvailable(100);

            try expect.equal(g_step_started_calls, 0);
            try expect.equal(engine.getWorkstationStatus(100).?, .Queued);
        }
    };

    pub const @"notifyStepComplete" = struct {
        test "advances to next step" {
            resetCallbacks();
            var engine = tasks.Engine(u32).init(std.testing.allocator);
            defer engine.deinit();

            engine.setFindBestWorker(testFindBestWorker);
            engine.setOnStepStarted(testOnStepStarted);
            engine.setOnStepCompleted(testOnStepCompleted);

            _ = engine.addWorker(1, .{});

            const steps = [_]StepDef{
                .{ .type = .Pickup },
                .{ .type = .Cook },
            };
            _ = engine.addWorkstation(100, .{ .steps = &steps });

            engine.notifyResourcesAvailable(100);
            try expect.equal(g_step_started_calls, 1);

            engine.notifyStepComplete(1);
            try expect.equal(g_step_started_calls, 2);
            try expect.equal(g_step_completed_calls, 1);
            try expect.equal(g_last_step_type.?, .Cook);
        }

        test "releases worker when cycle complete" {
            resetCallbacks();
            var engine = tasks.Engine(u32).init(std.testing.allocator);
            defer engine.deinit();

            engine.setFindBestWorker(testFindBestWorker);
            engine.setOnStepStarted(testOnStepStarted);
            engine.setOnStepCompleted(testOnStepCompleted);
            engine.setOnWorkerReleased(testOnWorkerReleased);
            engine.setShouldContinue(testShouldContinue);

            _ = engine.addWorker(1, .{});

            const steps = [_]StepDef{.{ .type = .Pickup }};
            _ = engine.addWorkstation(100, .{ .steps = &steps });

            engine.notifyResourcesAvailable(100);
            engine.notifyStepComplete(1);

            try expect.equal(g_worker_released_calls, 1);
            try expect.equal(engine.getWorkerState(1).?, .Idle);
            try expect.equal(engine.getWorkstationStatus(100).?, .Blocked);
        }
    };

    pub const @"shouldContinue" = struct {
        test "keeps worker assigned when true" {
            resetCallbacks();
            g_should_continue_result = true;
            var engine = tasks.Engine(u32).init(std.testing.allocator);
            defer engine.deinit();

            engine.setFindBestWorker(testFindBestWorker);
            engine.setOnStepStarted(testOnStepStarted);
            engine.setOnStepCompleted(testOnStepCompleted);
            engine.setOnWorkerReleased(testOnWorkerReleased);
            engine.setShouldContinue(testShouldContinue);

            _ = engine.addWorker(1, .{});

            const steps = [_]StepDef{.{ .type = .Pickup }};
            _ = engine.addWorkstation(100, .{ .steps = &steps });

            engine.notifyResourcesAvailable(100);
            engine.notifyStepComplete(1);

            try expect.equal(g_worker_released_calls, 0);
            try expect.equal(engine.getAssignedWorker(100).?, 1);
            try expect.equal(engine.getWorkstationStatus(100).?, .Blocked);
        }
    };

    pub const @"abandonWork" = struct {
        test "preserves step progress" {
            resetCallbacks();
            var engine = tasks.Engine(u32).init(std.testing.allocator);
            defer engine.deinit();

            engine.setFindBestWorker(testFindBestWorker);
            engine.setOnStepStarted(testOnStepStarted);
            engine.setOnStepCompleted(testOnStepCompleted);

            _ = engine.addWorker(1, .{});

            const steps = [_]StepDef{
                .{ .type = .Pickup },
                .{ .type = .Cook },
                .{ .type = .Store },
            };
            _ = engine.addWorkstation(100, .{ .steps = &steps });

            // Start and complete first step
            engine.notifyResourcesAvailable(100);
            engine.notifyStepComplete(1);
            try expect.equal(engine.getCurrentStep(100).?, 1);

            // Abandon work
            engine.abandonWork(1);

            // Step should be preserved
            try expect.equal(engine.getCurrentStep(100).?, 1);
            try expect.equal(engine.getWorkerState(1).?, .Idle);
            try expect.equal(engine.getAssignedWorker(100), null);
        }
    };

    pub const @"priority" = struct {
        test "assigns to higher priority workstation when released" {
            resetCallbacks();
            var engine = tasks.Engine(u32).init(std.testing.allocator);
            defer engine.deinit();

            engine.setFindBestWorker(testFindBestWorker);
            engine.setOnStepStarted(testOnStepStarted);
            engine.setOnWorkerReleased(testOnWorkerReleased);
            engine.setShouldContinue(testShouldContinue);

            _ = engine.addWorker(1, .{});

            const steps = [_]StepDef{.{ .type = .Pickup }};

            // Add low priority first, then high
            _ = engine.addWorkstation(100, .{ .steps = &steps, .priority = .Low });
            _ = engine.addWorkstation(101, .{ .steps = &steps, .priority = .High });

            // Signal low priority first - worker gets assigned there
            engine.notifyResourcesAvailable(100);
            try expect.equal(engine.getAssignedWorker(100).?, 1);

            // Complete low priority work
            engine.notifyStepComplete(1);

            // Now signal high priority
            engine.notifyResourcesAvailable(101);

            // Worker should be assigned to high priority (it was queued)
            try expect.equal(engine.getAssignedWorker(101).?, 1);
        }
    };

    pub const @"getCyclesCompleted" = struct {
        test "tracks completed cycles" {
            resetCallbacks();
            var engine = tasks.Engine(u32).init(std.testing.allocator);
            defer engine.deinit();

            engine.setFindBestWorker(testFindBestWorker);
            engine.setOnStepStarted(testOnStepStarted);
            engine.setShouldContinue(testShouldContinue);

            _ = engine.addWorker(1, .{});

            const steps = [_]StepDef{.{ .type = .Pickup }};
            _ = engine.addWorkstation(100, .{ .steps = &steps });

            try expect.equal(engine.getCyclesCompleted(100), 0);

            engine.notifyResourcesAvailable(100);
            engine.notifyStepComplete(1);

            try expect.equal(engine.getCyclesCompleted(100), 1);
        }
    };
};
