//! Event-Driven Task Runner Example
//!
//! Demonstrates the event-driven TaskRunner that uses zig-ecs signals
//! instead of polling for step completion.
//!
//! **Key difference from polling:**
//! - `startStep` is called once when a step begins
//! - Your game logic (timers, movement) calls `completeStep` when done
//! - No iteration over workers every tick to check "are you done yet?"
//!
//! Uses standard components from the library:
//! - tasks.Worker (with Idle/Working/Blocked states)
//! - tasks.AssignedToGroup
//! - tasks.GroupAssignedWorker
//! - tasks.StepComplete (marker component for signaling)

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
// Simulation State
// ============================================================================

var g_resources: Resources = .{};
var g_tick: u32 = 0;

// Track pending work (in real game, this would be timers/movement system)
var g_worker_with_pending_step: ?Entity = null;
var g_step_ticks_remaining: u32 = 0;

// ============================================================================
// Callbacks
// ============================================================================

fn canUnblock(reg: *Registry, entity: Entity) bool {
    _ = reg;
    _ = entity;
    return g_resources.ingredients_available and
        g_resources.stove_available and
        g_resources.storage_available;
}

/// Called once when a step BEGINS (not every tick!)
/// In a real game, this would start a timer, movement, or animation.
fn startStep(reg: *Registry, worker_entity: Entity, group_entity: Entity, step: StepDef) void {
    const worker_name = reg.get(Name, worker_entity);
    const chef_data = reg.get(ChefData, worker_entity);
    const group = reg.get(KitchenGroup, group_entity);

    std.debug.print("[Tick {d:3}] {s} STARTING: {s}\n", .{
        g_tick,
        worker_name.value,
        @tagName(step.type),
    });

    // Simulate work taking time (in real game: start timer/movement)
    g_worker_with_pending_step = worker_entity;
    g_step_ticks_remaining = switch (step.type) {
        .Pickup => 1, // 1 tick to pickup
        .Cook => 2, // 2 ticks to cook
        .Store => 1, // 1 tick to store
        else => 1,
    };

    // Check if this is the last step (will complete a cycle)
    if (group.steps.current_index == group.steps.steps.len - 1) {
        chef_data.cycles_completed += 1;
    }
}

fn shouldContinue(reg: *Registry, worker_entity: Entity, group_entity: Entity) bool {
    _ = group_entity;
    const chef_data = reg.get(ChefData, worker_entity);
    return chef_data.cycles_completed < chef_data.max_cycles;
}

fn onReleased(reg: *Registry, worker_entity: Entity, group_entity: Entity) void {
    _ = group_entity;
    const worker_name = reg.get(Name, worker_entity);
    const chef_data = reg.get(ChefData, worker_entity);
    std.debug.print("[Tick {d:3}] {s} released (completed {d} cycles)\n", .{
        g_tick,
        worker_name.value,
        chef_data.cycles_completed,
    });
}

// ============================================================================
// Task Runner
// ============================================================================

const KitchenRunner = tasks.TaskRunner(
    KitchenGroup,
    canUnblock,
    startStep,
    shouldContinue,
    onReleased,
);

// ============================================================================
// Simulated Game Systems
// ============================================================================

/// Simulates timers/movement completing.
/// In a real game, your timer system or movement system would call completeStep.
fn simulateWorkCompletion(reg: *Registry) void {
    if (g_worker_with_pending_step) |worker| {
        if (g_step_ticks_remaining > 0) {
            g_step_ticks_remaining -= 1;
            if (g_step_ticks_remaining == 0) {
                const worker_name = reg.get(Name, worker);
                std.debug.print("[Tick {d:3}] {s} FINISHED step\n", .{ g_tick, worker_name.value });

                // Signal completion via the event system
                // Note: completeStep triggers startStep for next step, which may set
                // g_worker_with_pending_step again. Only clear if no more steps.
                KitchenRunner.completeStep(reg, worker);

                // If startStep wasn't called (no more steps), clear the pending worker
                if (g_step_ticks_remaining == 0) {
                    g_worker_with_pending_step = null;
                }
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
    std.debug.print("  EVENT-DRIVEN TASK RUNNER EXAMPLE      \n", .{});
    std.debug.print("========================================\n\n", .{});

    std.debug.print("This example demonstrates EVENT-DRIVEN step completion:\n", .{});
    std.debug.print("- startStep() called ONCE when step begins\n", .{});
    std.debug.print("- completeStep() called when work is done\n", .{});
    std.debug.print("- NO polling every tick!\n\n", .{});

    std.debug.print("Step durations: Pickup=1, Cook=2, Store=1\n\n", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var reg = Registry.init(allocator);
    defer reg.deinit();

    // IMPORTANT: Set up event handlers before creating entities
    KitchenRunner.setup(&reg);

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

    // Run simulation
    const max_ticks = 30;
    while (g_tick < max_ticks) {
        g_tick += 1;

        // 1. Run task systems (no step polling!)
        KitchenRunner.tick(&reg);

        // 2. Simulate work completion (timer/movement system)
        simulateWorkCompletion(&reg);

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
