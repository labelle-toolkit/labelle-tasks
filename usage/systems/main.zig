//! ECS Systems Example
//!
//! Demonstrates the TaskRunner - a batteries-included approach that combines
//! all task systems into a single tick() call.
//!
//! Uses standard components from the library:
//! - tasks.Worker (with Idle/Working/Blocked states)
//! - tasks.AssignedToGroup
//! - tasks.GroupAssignedWorker
//!
//! You only need to provide:
//! - Your GroupComponent (with status and steps)
//! - canUnblock: check if resources are available
//! - processStep: execute the current step
//! - shouldContinue: decide if worker does another cycle

const std = @import("std");
const ecs = @import("ecs");
const tasks = @import("labelle_tasks");

const Priority = tasks.Priority;
const TaskGroupStatus = tasks.TaskGroupStatus;
const StepType = tasks.StepType;
const StepDef = tasks.StepDef;
const GroupSteps = tasks.GroupSteps;
const Worker = tasks.Worker;
const WorkerState = tasks.WorkerState;
const AssignedToGroup = tasks.AssignedToGroup;
const GroupAssignedWorker = tasks.GroupAssignedWorker;

const Registry = ecs.Registry;
const Entity = ecs.Entity;

// ============================================================================
// User Components
// ============================================================================

const Name = struct {
    value: []const u8,
};

// Extra worker data (beyond the standard Worker component)
const ChefData = struct {
    cycles_completed: u32 = 0,
    max_cycles: u32 = 2,
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
// Callbacks
// ============================================================================

var g_resources: Resources = .{};
var g_tick: u32 = 0;

fn canUnblock(reg: *Registry, entity: Entity) bool {
    _ = reg;
    _ = entity;
    return g_resources.ingredients_available and
        g_resources.stove_available and
        g_resources.storage_available;
}

fn processStep(reg: *Registry, worker_entity: Entity, group_entity: Entity, step: StepDef) void {
    const worker_name = reg.get(Name, worker_entity);
    const chef_data = reg.get(ChefData, worker_entity);
    const group = reg.get(KitchenGroup, group_entity);

    std.debug.print("[Tick {d:3}] {s} performing: {s}\n", .{
        g_tick,
        worker_name.value,
        @tagName(step.type),
    });

    // Check if this will complete a cycle (last step)
    if (group.steps.current_index == group.steps.steps.len - 1) {
        chef_data.cycles_completed += 1;
        std.debug.print("[Tick {d:3}] {s} completed cycle {d}/{d}\n", .{
            g_tick,
            worker_name.value,
            chef_data.cycles_completed,
            chef_data.max_cycles,
        });
    }
}

fn shouldContinue(reg: *Registry, worker_entity: Entity, group_entity: Entity) bool {
    _ = group_entity;
    const chef_data = reg.get(ChefData, worker_entity);
    return chef_data.cycles_completed < chef_data.max_cycles;
}

fn onAssigned(reg: *Registry, worker_entity: Entity, group_entity: Entity) void {
    _ = group_entity;
    const worker_name = reg.get(Name, worker_entity);
    std.debug.print("[Tick {d:3}] {s} assigned to kitchen group\n", .{ g_tick, worker_name.value });
}

fn onReleased(reg: *Registry, worker_entity: Entity, group_entity: Entity) void {
    _ = group_entity;
    const worker_name = reg.get(Name, worker_entity);
    std.debug.print("[Tick {d:3}] {s} released from group (finished all cycles)\n", .{ g_tick, worker_name.value });
}

// ============================================================================
// Task Runner
// ============================================================================

const KitchenRunner = tasks.TaskRunner(
    KitchenGroup,
    canUnblock,
    processStep,
    shouldContinue,
    onAssigned,
    onReleased,
);

// ============================================================================
// Main
// ============================================================================

pub fn main() !void {
    std.debug.print("\n", .{});
    std.debug.print("========================================\n", .{});
    std.debug.print("  TASK RUNNER EXAMPLE                   \n", .{});
    std.debug.print("========================================\n\n", .{});

    std.debug.print("This example demonstrates the TaskRunner,\n", .{});
    std.debug.print("which combines all systems into one tick() call.\n\n", .{});

    std.debug.print("Standard components used:\n", .{});
    std.debug.print("- tasks.Worker (Idle/Working/Blocked states)\n", .{});
    std.debug.print("- tasks.AssignedToGroup\n", .{});
    std.debug.print("- tasks.GroupAssignedWorker\n\n", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var reg = Registry.init(allocator);
    defer reg.deinit();

    // Create a worker with standard Worker component + custom ChefData
    const chef = reg.create();
    reg.add(chef, Name{ .value = "Chef Mario" });
    reg.add(chef, Worker{}); // Standard component from library
    reg.add(chef, ChefData{ .max_cycles = 2 }); // Custom data

    // Create a kitchen group
    const group = reg.create();
    reg.add(group, KitchenGroup.init(.Normal));

    std.debug.print("Setup:\n", .{});
    std.debug.print("- Chef Mario (max 2 cycles)\n", .{});
    std.debug.print("- Kitchen group (3 steps: Pickup -> Cook -> Store)\n\n", .{});

    // Run simulation - just call tick()!
    const max_ticks = 15;
    while (g_tick < max_ticks) {
        g_tick += 1;

        // Single call runs all systems in correct order
        KitchenRunner.tick(&reg);

        // Check if done
        const worker = reg.get(Worker, chef);
        const chef_data = reg.get(ChefData, chef);
        if (worker.state == .Idle and chef_data.cycles_completed >= chef_data.max_cycles) {
            std.debug.print("\n[Tick {d:3}] Simulation complete!\n", .{g_tick});
            break;
        }
    }

    // Final assertions
    std.debug.print("\n--- Assertions ---\n", .{});

    const final_worker = reg.get(Worker, chef);
    const final_chef = reg.get(ChefData, chef);
    const final_group = reg.get(KitchenGroup, group);

    std.debug.print("Worker cycles completed: {d}\n", .{final_chef.cycles_completed});
    std.debug.assert(final_chef.cycles_completed == 2);
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
