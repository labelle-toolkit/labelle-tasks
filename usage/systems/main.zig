//! ECS Systems Example
//!
//! Demonstrates the built-in ECS systems provided by labelle-tasks:
//! - BlockedToQueuedSystem: Transitions groups from Blocked to Queued
//! - WorkerAssignmentSystem: Assigns idle workers to queued groups
//! - GroupCompletionSystem: Handles group completion and worker release
//!
//! This example shows a simplified kitchen workflow using the systems
//! instead of manual state management.

const std = @import("std");
const ecs = @import("ecs");
const tasks = @import("labelle_tasks");

const Priority = tasks.Priority;
const TaskGroupStatus = tasks.TaskGroupStatus;
const StepType = tasks.StepType;
const StepDef = tasks.StepDef;
const GroupSteps = tasks.GroupSteps;

const Registry = ecs.Registry;
const Entity = ecs.Entity;

// ============================================================================
// Components
// ============================================================================

const Name = struct {
    value: []const u8,
};

const WorkerState = enum {
    Idle,
    Working,
};

const Worker = struct {
    state: WorkerState = .Idle,
    cycles_completed: u32 = 0,
    max_cycles: u32 = 2, // Worker will do 2 cycles then stop
};

const AssignedToGroup = struct {
    group: Entity,
};

const GroupAssignedWorker = struct {
    worker: Entity,
};

const KitchenGroup = struct {
    status: TaskGroupStatus = .Blocked,
    priority: Priority,
    steps: GroupSteps,

    const kitchen_steps = [_]StepDef{
        .{ .type = .Pickup },
        .{ .type = .Cook },
        .{ .type = .Store },
    };

    pub fn init(priority: Priority) KitchenGroup {
        return .{
            .status = .Blocked,
            .priority = priority,
            .steps = GroupSteps.init(&kitchen_steps),
        };
    }
};

// Resource tracking (simplified)
const Resources = struct {
    ingredients_available: bool = true,
    stove_available: bool = true,
    storage_available: bool = true,
};

// ============================================================================
// System Configuration
// ============================================================================

var g_resources: Resources = .{};
var g_tick: u32 = 0;

const SystemConfig = struct {
    pub const GroupComponent = KitchenGroup;
    pub const WorkerComponent = Worker;
    pub const AssignedComponent = AssignedToGroup;
    pub const GroupAssignedComponent = GroupAssignedWorker;

    pub fn canUnblock(reg: *Registry, entity: Entity) bool {
        _ = reg;
        _ = entity;
        // Check if resources are available
        return g_resources.ingredients_available and
            g_resources.stove_available and
            g_resources.storage_available;
    }

    pub fn isWorkerIdle(reg: *Registry, entity: Entity) bool {
        const worker = reg.get(Worker, entity);
        return worker.state == .Idle;
    }

    pub fn onAssigned(reg: *Registry, worker_entity: Entity, group_entity: Entity) void {
        const worker = reg.get(Worker, worker_entity);
        const worker_name = reg.get(Name, worker_entity);
        _ = group_entity;

        worker.state = .Working;
        std.debug.print("[Tick {d:3}] {s} assigned to kitchen group\n", .{ g_tick, worker_name.value });
    }

    pub fn shouldContinue(reg: *Registry, worker_entity: Entity, group_entity: Entity) bool {
        const worker = reg.get(Worker, worker_entity);
        _ = group_entity;

        // Worker continues if they haven't reached max cycles
        return worker.cycles_completed < worker.max_cycles;
    }

    pub fn setWorkerIdle(reg: *Registry, worker_entity: Entity) void {
        const worker = reg.get(Worker, worker_entity);
        worker.state = .Idle;
    }

    pub fn onReleased(reg: *Registry, worker_entity: Entity, group_entity: Entity) void {
        const worker_name = reg.get(Name, worker_entity);
        _ = group_entity;

        std.debug.print("[Tick {d:3}] {s} released from group (finished all cycles)\n", .{ g_tick, worker_name.value });
    }
};

// Instantiate the systems with our config
const BlockedSystem = tasks.BlockedToQueuedSystem(SystemConfig);
const AssignmentSystem = tasks.WorkerAssignmentSystem(SystemConfig);
const CompletionSystem = tasks.GroupCompletionSystem(SystemConfig);

// ============================================================================
// Step Processing (user-defined work logic)
// ============================================================================

fn processActiveGroups(reg: *Registry) void {
    var view = reg.view(.{ KitchenGroup, GroupAssignedWorker }, .{});
    var iter = view.entityIterator();

    while (iter.next()) |group_entity| {
        const group = reg.get(KitchenGroup, group_entity);
        if (group.status != .Active) continue;

        const assigned = reg.get(GroupAssignedWorker, group_entity);
        const worker = reg.get(Worker, assigned.worker);
        const worker_name = reg.get(Name, assigned.worker);

        // Process current step
        if (group.steps.currentStep()) |step| {
            std.debug.print("[Tick {d:3}] {s} performing: {s}\n", .{
                g_tick,
                worker_name.value,
                @tagName(step.type),
            });

            // Advance to next step
            _ = group.steps.advance();

            // Check if this completed a cycle
            if (group.steps.isComplete()) {
                worker.cycles_completed += 1;
                std.debug.print("[Tick {d:3}] {s} completed cycle {d}/{d}\n", .{
                    g_tick,
                    worker_name.value,
                    worker.cycles_completed,
                    worker.max_cycles,
                });
            }
        }
    }
}

// ============================================================================
// Main
// ============================================================================

pub fn main() !void {
    std.debug.print("\n", .{});
    std.debug.print("========================================\n", .{});
    std.debug.print("  ECS SYSTEMS EXAMPLE                   \n", .{});
    std.debug.print("========================================\n\n", .{});

    std.debug.print("This example demonstrates the built-in ECS systems:\n", .{});
    std.debug.print("- BlockedToQueuedSystem\n", .{});
    std.debug.print("- WorkerAssignmentSystem\n", .{});
    std.debug.print("- GroupCompletionSystem\n\n", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var reg = Registry.init(allocator);
    defer reg.deinit();

    // Create a worker
    const chef = reg.create();
    reg.add(chef, Name{ .value = "Chef Mario" });
    reg.add(chef, Worker{ .max_cycles = 2 });

    // Create a kitchen group
    const group = reg.create();
    reg.add(group, KitchenGroup.init(.Normal));

    std.debug.print("Setup:\n", .{});
    std.debug.print("- Chef Mario (max 2 cycles)\n", .{});
    std.debug.print("- Kitchen group (3 steps: Pickup -> Cook -> Store)\n\n", .{});

    // Run simulation
    const max_ticks = 15;
    while (g_tick < max_ticks) {
        g_tick += 1;

        // Run the systems in order
        BlockedSystem.run(&reg);
        AssignmentSystem.run(&reg);
        processActiveGroups(&reg);
        CompletionSystem.run(&reg);

        // Check if done
        const worker = reg.get(Worker, chef);
        if (worker.state == .Idle and worker.cycles_completed >= worker.max_cycles) {
            std.debug.print("\n[Tick {d:3}] Simulation complete!\n", .{g_tick});
            break;
        }
    }

    // Final assertions
    std.debug.print("\n--- Assertions ---\n", .{});

    const final_worker = reg.get(Worker, chef);
    const final_group = reg.get(KitchenGroup, group);

    std.debug.print("Worker cycles completed: {d}\n", .{final_worker.cycles_completed});
    std.debug.assert(final_worker.cycles_completed == 2);
    std.debug.print("[PASS] Worker completed 2 cycles\n", .{});

    std.debug.assert(final_worker.state == .Idle);
    std.debug.print("[PASS] Worker is idle after completion\n", .{});

    std.debug.assert(final_group.status == .Blocked);
    std.debug.print("[PASS] Group is blocked (waiting for next worker)\n", .{});

    // Worker should be unassigned
    const has_assignment = reg.tryGet(AssignedToGroup, chef) != null;
    std.debug.assert(!has_assignment);
    std.debug.print("[PASS] Worker is unassigned\n", .{});

    std.debug.print("\n========================================\n", .{});
    std.debug.print("    ALL ASSERTIONS PASSED!              \n", .{});
    std.debug.print("========================================\n", .{});
}
