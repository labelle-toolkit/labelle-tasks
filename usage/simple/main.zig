//! Simple Task Example
//!
//! Demonstrates the basic labelle-tasks types with zig-ecs:
//! - Task with TaskStatus (Queued -> Active -> Completed)
//! - Priority levels affecting task selection
//! - InterruptLevel for task protection
//!
//! A worker processes tasks from a queue, preferring higher priority tasks.

const std = @import("std");
const ecs = @import("ecs");
const tasks = @import("labelle_tasks");

const Priority = tasks.Priority;
const TaskStatus = tasks.TaskStatus;
const InterruptLevel = tasks.InterruptLevel;
const Task = tasks.Task;
const canInterrupt = tasks.canInterrupt;

const Registry = ecs.Registry;
const Entity = ecs.Entity;

// ============================================================================
// Components
// ============================================================================

const Name = struct {
    value: []const u8,
};

// Task payload - what work needs to be done
const WorkPayload = struct {
    work_type: WorkType,
    ticks_remaining: u8,
};

const WorkType = enum {
    Cleaning,
    Repair,
    Inspection,
    Emergency,
};

// Worker component
const Worker = struct {
    current_task: ?Entity = null,
    is_busy: bool = false,
};

// ============================================================================
// World
// ============================================================================

const World = struct {
    reg: *Registry,
    tick: u32 = 0,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !World {
        const reg = try allocator.create(Registry);
        reg.* = Registry.init(allocator);
        return World{
            .reg = reg,
            .tick = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *World) void {
        self.reg.deinit();
        self.allocator.destroy(self.reg);
    }

    pub fn createTask(self: *World, name: []const u8, priority: Priority, work_type: WorkType, duration: u8) Entity {
        const entity = self.reg.create();
        self.reg.add(entity, Name{ .value = name });
        self.reg.add(entity, Task.init(priority));
        self.reg.add(entity, WorkPayload{ .work_type = work_type, .ticks_remaining = duration });
        return entity;
    }

    pub fn createTaskWithInterrupt(self: *World, name: []const u8, priority: Priority, interrupt_level: InterruptLevel, work_type: WorkType, duration: u8) Entity {
        const entity = self.reg.create();
        self.reg.add(entity, Name{ .value = name });
        self.reg.add(entity, Task.init(priority).withInterruptLevel(interrupt_level));
        self.reg.add(entity, WorkPayload{ .work_type = work_type, .ticks_remaining = duration });
        return entity;
    }

    pub fn createWorker(self: *World, name: []const u8) Entity {
        const entity = self.reg.create();
        self.reg.add(entity, Name{ .value = name });
        self.reg.add(entity, Worker{});
        return entity;
    }

    pub fn log(self: *World, comptime fmt: []const u8, args: anytype) void {
        std.debug.print("[Tick {d:3}] " ++ fmt ++ "\n", .{self.tick} ++ args);
    }

    pub fn runTick(self: *World) void {
        self.tick += 1;
        self.log("--- TICK START ---", .{});

        self.assignTasksToWorkers();
        self.processWorkers();

        self.log("--- TICK END ---", .{});
    }

    fn findHighestPriorityQueuedTask(self: *World) ?Entity {
        var best_entity: ?Entity = null;
        var best_priority: ?Priority = null;

        var view = self.reg.view(.{Task}, .{});
        var iter = view.entityIterator();

        while (iter.next()) |entity| {
            const task = self.reg.get(Task, entity);
            if (task.status == .Queued) {
                if (best_priority == null or @intFromEnum(task.priority) > @intFromEnum(best_priority.?)) {
                    best_entity = entity;
                    best_priority = task.priority;
                }
            }
        }
        return best_entity;
    }

    fn assignTasksToWorkers(self: *World) void {
        var worker_view = self.reg.view(.{Worker}, .{});
        var worker_iter = worker_view.entityIterator();

        while (worker_iter.next()) |worker_entity| {
            const worker = self.reg.get(Worker, worker_entity);
            const worker_name = self.reg.get(Name, worker_entity);

            if (!worker.is_busy) {
                // Find highest priority queued task
                if (self.findHighestPriorityQueuedTask()) |task_entity| {
                    const task = self.reg.get(Task, task_entity);
                    const task_name = self.reg.get(Name, task_entity);

                    task.status = .Active;
                    worker.current_task = task_entity;
                    worker.is_busy = true;

                    self.log("{s} started working on '{s}' (priority: {s})", .{
                        worker_name.value,
                        task_name.value,
                        @tagName(task.priority),
                    });
                }
            } else if (worker.current_task) |current_task_entity| {
                // Check if a higher priority task should interrupt
                const current_task = self.reg.get(Task, current_task_entity);

                if (self.findHighestPriorityQueuedTask()) |new_task_entity| {
                    const new_task = self.reg.get(Task, new_task_entity);

                    // Check if new task has higher priority and can interrupt
                    if (@intFromEnum(new_task.priority) > @intFromEnum(current_task.priority)) {
                        if (canInterrupt(current_task.interrupt_level, new_task.priority)) {
                            const current_name = self.reg.get(Name, current_task_entity);
                            const new_name = self.reg.get(Name, new_task_entity);

                            // Interrupt current task
                            current_task.status = .Queued;
                            self.log("{s} interrupted '{s}' for higher priority '{s}'", .{
                                worker_name.value,
                                current_name.value,
                                new_name.value,
                            });

                            // Start new task
                            new_task.status = .Active;
                            worker.current_task = new_task_entity;
                        } else {
                            const current_name = self.reg.get(Name, current_task_entity);
                            self.log("{s} cannot interrupt '{s}' (protected by {s})", .{
                                worker_name.value,
                                current_name.value,
                                @tagName(current_task.interrupt_level),
                            });
                        }
                    }
                }
            }
        }
    }

    fn processWorkers(self: *World) void {
        var worker_view = self.reg.view(.{Worker}, .{});
        var worker_iter = worker_view.entityIterator();

        while (worker_iter.next()) |worker_entity| {
            const worker = self.reg.get(Worker, worker_entity);
            const worker_name = self.reg.get(Name, worker_entity);

            if (worker.current_task) |task_entity| {
                const task = self.reg.get(Task, task_entity);
                const payload = self.reg.get(WorkPayload, task_entity);
                const task_name = self.reg.get(Name, task_entity);

                if (payload.ticks_remaining > 0) {
                    payload.ticks_remaining -= 1;
                    self.log("{s} working on '{s}' ({d} ticks remaining)", .{
                        worker_name.value,
                        task_name.value,
                        payload.ticks_remaining,
                    });
                }

                if (payload.ticks_remaining == 0) {
                    task.status = .Completed;
                    worker.current_task = null;
                    worker.is_busy = false;
                    self.log("{s} completed '{s}'!", .{ worker_name.value, task_name.value });
                }
            }
        }
    }

    fn countTasksByStatus(self: *World, status: TaskStatus) usize {
        var count: usize = 0;
        var view = self.reg.view(.{Task}, .{});
        var iter = view.entityIterator();
        while (iter.next()) |entity| {
            const task = self.reg.get(Task, entity);
            if (task.status == status) count += 1;
        }
        return count;
    }

    fn printStatus(self: *World) void {
        std.debug.print("\n--- Status ---\n", .{});
        std.debug.print("Tasks: {d} queued, {d} active, {d} completed\n", .{
            self.countTasksByStatus(.Queued),
            self.countTasksByStatus(.Active),
            self.countTasksByStatus(.Completed),
        });

        var task_view = self.reg.view(.{ Task, Name, WorkPayload }, .{});
        var task_iter = task_view.entityIterator();
        while (task_iter.next()) |entity| {
            const task = self.reg.get(Task, entity);
            const name = self.reg.get(Name, entity);
            const payload = self.reg.get(WorkPayload, entity);
            std.debug.print("  [{s}] {s} - {s}, {d} ticks left\n", .{
                @tagName(task.status),
                name.value,
                @tagName(task.priority),
                payload.ticks_remaining,
            });
        }
        std.debug.print("--------------\n\n", .{});
    }
};

// ============================================================================
// Main
// ============================================================================

pub fn main() !void {
    std.debug.print("\n========================================\n", .{});
    std.debug.print("  SIMPLE TASK EXAMPLE - labelle-tasks   \n", .{});
    std.debug.print("========================================\n\n", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var world = try World.init(allocator);
    defer world.deinit();

    // Create worker
    const worker = world.createWorker("Bob");

    // Create tasks with different priorities
    const cleaning_task = world.createTask("Clean floor", .Low, .Cleaning, 3);
    const repair_task = world.createTask("Fix door", .Normal, .Repair, 2);
    const inspection_task = world.createTask("Safety check", .High, .Inspection, 1);

    // ========================================================================
    // Initial Assertions
    // ========================================================================
    std.debug.print("Verifying initial state...\n", .{});

    // All tasks should start as Queued
    std.debug.assert(world.reg.get(Task, cleaning_task).status == .Queued);
    std.debug.assert(world.reg.get(Task, repair_task).status == .Queued);
    std.debug.assert(world.reg.get(Task, inspection_task).status == .Queued);

    // Verify priorities
    std.debug.assert(world.reg.get(Task, cleaning_task).priority == .Low);
    std.debug.assert(world.reg.get(Task, repair_task).priority == .Normal);
    std.debug.assert(world.reg.get(Task, inspection_task).priority == .High);

    // Worker should be idle
    std.debug.assert(!world.reg.get(Worker, worker).is_busy);

    std.debug.print("Initial state verified!\n\n", .{});

    // ========================================================================
    // Run Simulation - Part 1: Priority-based task selection
    // ========================================================================
    std.debug.print("=== Part 1: Priority-based task selection ===\n", .{});
    std.debug.print("Tasks: Clean(Low), Fix(Normal), Safety(High)\n", .{});
    std.debug.print("Worker should pick Safety check first (highest priority)\n\n", .{});

    world.runTick();
    world.printStatus();

    // After tick 1: Safety check (1 tick) completed in same tick, worker now idle
    std.debug.assert(world.reg.get(Task, inspection_task).status == .Completed);
    std.debug.assert(world.reg.get(Task, repair_task).status == .Queued);
    std.debug.assert(world.reg.get(Task, cleaning_task).status == .Queued);
    std.debug.assert(!world.reg.get(Worker, worker).is_busy);
    std.debug.print("[PASS] High priority task completed first\n\n", .{});

    world.runTick();
    world.printStatus();

    // After tick 2: Worker picked Fix door (Normal), working on it
    std.debug.assert(world.reg.get(Task, repair_task).status == .Active);
    std.debug.assert(world.reg.get(Worker, worker).current_task.? == repair_task);
    std.debug.print("[PASS] Now working on Normal priority task\n\n", .{});

    // Run until all tasks complete
    while (world.countTasksByStatus(.Queued) > 0 or world.countTasksByStatus(.Active) > 0) {
        world.runTick();
    }
    world.printStatus();

    // All tasks should be completed
    std.debug.assert(world.reg.get(Task, inspection_task).status == .Completed);
    std.debug.assert(world.reg.get(Task, repair_task).status == .Completed);
    std.debug.assert(world.reg.get(Task, cleaning_task).status == .Completed);
    std.debug.print("[PASS] All tasks completed in priority order\n\n", .{});

    // ========================================================================
    // Run Simulation - Part 2: Task interruption
    // ========================================================================
    std.debug.print("=== Part 2: Task interruption ===\n", .{});

    // Reset world
    world.deinit();
    world = try World.init(allocator);

    const worker2 = world.createWorker("Alice");

    // Create a low priority task that takes a while
    const long_task = world.createTask("Long cleanup", .Low, .Cleaning, 5);

    std.debug.print("Starting with a long Low priority task...\n\n", .{});

    world.runTick();

    // Worker should be working on long task
    std.debug.assert(world.reg.get(Task, long_task).status == .Active);
    std.debug.assert(world.reg.get(Worker, worker2).current_task.? == long_task);
    std.debug.print("[PASS] Worker started on Low priority task\n", .{});

    // Now add a Critical emergency task (1 tick - will complete immediately when run)
    const emergency_task = world.createTask("Emergency!", .Critical, .Emergency, 1);
    std.debug.print("Emergency task added! Should interrupt the cleanup...\n\n", .{});

    world.runTick();
    world.printStatus();

    // Emergency interrupted and completed in same tick, long_task back to queued
    std.debug.assert(world.reg.get(Task, emergency_task).status == .Completed);
    std.debug.assert(world.reg.get(Task, long_task).status == .Queued);
    std.debug.print("[PASS] Critical task interrupted and completed, Low task back to Queued\n\n", .{});

    world.runTick();
    world.printStatus();

    // Long task resumed
    std.debug.assert(world.reg.get(Task, long_task).status == .Active);
    std.debug.assert(world.reg.get(Worker, worker2).current_task.? == long_task);
    std.debug.print("[PASS] Resumed interrupted task after emergency\n\n", .{});

    // ========================================================================
    // Run Simulation - Part 3: Interrupt protection
    // ========================================================================
    std.debug.print("=== Part 3: Interrupt protection (Atomic) ===\n", .{});

    // Reset world
    world.deinit();
    world = try World.init(allocator);

    const worker3 = world.createWorker("Charlie");

    // Create an atomic task that cannot be interrupted
    const atomic_task = world.createTaskWithInterrupt("Critical repair", .Normal, .Atomic, .Repair, 3);

    std.debug.print("Starting Atomic task (cannot be interrupted)...\n\n", .{});

    world.runTick();

    std.debug.assert(world.reg.get(Task, atomic_task).status == .Active);

    // Try to add a Critical task - should NOT interrupt Atomic
    const critical_task = world.createTask("Critical override attempt", .Critical, .Emergency, 1);
    std.debug.print("Trying to interrupt with Critical priority...\n\n", .{});

    world.runTick();
    world.printStatus();

    // Atomic task should still be active, Critical should still be queued
    std.debug.assert(world.reg.get(Task, atomic_task).status == .Active);
    std.debug.assert(world.reg.get(Task, critical_task).status == .Queued);
    std.debug.assert(world.reg.get(Worker, worker3).current_task.? == atomic_task);
    std.debug.print("[PASS] Atomic task was NOT interrupted by Critical priority\n\n", .{});

    // Verify canInterrupt logic
    std.debug.assert(canInterrupt(.None, .Low) == true);
    std.debug.assert(canInterrupt(.None, .Critical) == true);
    std.debug.assert(canInterrupt(.Low, .Normal) == false);
    std.debug.assert(canInterrupt(.Low, .High) == true);
    std.debug.assert(canInterrupt(.High, .High) == false);
    std.debug.assert(canInterrupt(.High, .Critical) == true);
    std.debug.assert(canInterrupt(.Atomic, .Critical) == false);
    std.debug.print("[PASS] canInterrupt logic verified\n\n", .{});

    std.debug.print("========================================\n", .{});
    std.debug.print("    ALL ASSERTIONS PASSED!              \n", .{});
    std.debug.print("========================================\n", .{});
}
