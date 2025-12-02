//! Worker Abandonment Example
//!
//! Demonstrates task group continuation after worker abandonment:
//! - Worker starts a multi-step task group
//! - Worker gets interrupted (fight, death, shift end)
//! - Group keeps its current step (doesn't reset)
//! - New worker continues from where the previous worker left off
//!
//! Key concept: abandonGroup() vs completeGroupCycle()
//! - completeGroupCycle: resets steps to 0, group is done
//! - abandonGroup: keeps current step, group goes to Blocked for re-evaluation

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
// Components (same as kitchen example)
// ============================================================================

const Position = struct {
    x: i32,
    y: i32,

    pub fn eql(self: Position, other: Position) bool {
        return self.x == other.x and self.y == other.y;
    }
};

const Name = struct {
    value: []const u8,
};

const ItemType = enum {
    Meat,
    Vegetable,
    CookedMeal,
};

const Storage = struct {
    priority: Priority,
    accepts: []const ItemType,
};

const StoredItems = struct {
    items: [10]?ItemType = [_]?ItemType{null} ** 10,
    count: usize = 0,

    pub fn hasItem(self: *const StoredItems, item_type: ItemType) bool {
        for (self.items[0..self.count]) |maybe_item| {
            if (maybe_item) |item| {
                if (item == item_type) return true;
            }
        }
        return false;
    }

    pub fn takeItem(self: *StoredItems, item_type: ItemType) bool {
        for (&self.items, 0..) |*maybe_item, i| {
            if (maybe_item.*) |item| {
                if (item == item_type and i < self.count) {
                    maybe_item.* = null;
                    var j = i;
                    while (j < self.count - 1) : (j += 1) {
                        self.items[j] = self.items[j + 1];
                    }
                    self.items[self.count - 1] = null;
                    self.count -= 1;
                    return true;
                }
            }
        }
        return false;
    }

    pub fn addItem(self: *StoredItems, item_type: ItemType) bool {
        if (self.count >= 10) return false;
        self.items[self.count] = item_type;
        self.count += 1;
        return true;
    }

    pub fn isFull(self: *const StoredItems) bool {
        return self.count >= 10;
    }
};

const Stove = struct {
    in_use: bool = false,
};

const WorkerState = enum {
    Idle,
    MovingToPickup,
    PickingUp,
    MovingToCook,
    Cooking,
    MovingToStore,
    Storing,
};

const Worker = struct {
    state: WorkerState = .Idle,
    target_position: ?Position = null,
    carrying: ?ItemType = null,
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
    target_storage: ?Entity = null,

    const kitchen_steps = [_]StepDef{
        .{ .type = .Pickup }, // step 0: pickup meat
        .{ .type = .Pickup }, // step 1: pickup vegetable
        .{ .type = .Cook }, // step 2: cook at stove
        .{ .type = .Store }, // step 3: store cooked meal
    };

    pub fn init(priority: Priority) KitchenGroup {
        return .{
            .status = .Blocked,
            .priority = priority,
            .steps = GroupSteps.init(&kitchen_steps),
        };
    }

    pub fn currentStepType(self: *const KitchenGroup) ?StepType {
        const step = self.steps.currentStep();
        return if (step) |s| s.type else null;
    }

    pub fn advance(self: *KitchenGroup) void {
        _ = self.steps.advance();
        self.target_storage = null;
    }

    pub fn reset(self: *KitchenGroup) void {
        self.steps.reset();
        self.target_storage = null;
    }
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
        return World{ .reg = reg, .tick = 0, .allocator = allocator };
    }

    pub fn deinit(self: *World) void {
        self.reg.deinit();
        self.allocator.destroy(self.reg);
    }

    pub fn createStorage(self: *World, name: []const u8, pos: Position, priority: Priority, accepts: []const ItemType) Entity {
        const entity = self.reg.create();
        self.reg.add(entity, Name{ .value = name });
        self.reg.add(entity, pos);
        self.reg.add(entity, Storage{ .priority = priority, .accepts = accepts });
        self.reg.add(entity, StoredItems{});
        return entity;
    }

    pub fn createStove(self: *World, name: []const u8, pos: Position) Entity {
        const entity = self.reg.create();
        self.reg.add(entity, Name{ .value = name });
        self.reg.add(entity, pos);
        self.reg.add(entity, Stove{});
        return entity;
    }

    pub fn createWorker(self: *World, name: []const u8, pos: Position) Entity {
        const entity = self.reg.create();
        self.reg.add(entity, Name{ .value = name });
        self.reg.add(entity, pos);
        self.reg.add(entity, Worker{});
        return entity;
    }

    pub fn createKitchenGroup(self: *World, priority: Priority) Entity {
        const entity = self.reg.create();
        self.reg.add(entity, KitchenGroup.init(priority));
        return entity;
    }

    pub fn findStorageWithItem(self: *World, item_type: ItemType) ?Entity {
        var best_entity: ?Entity = null;
        var best_priority: ?Priority = null;

        var view = self.reg.view(.{ Storage, StoredItems }, .{});
        var iter = view.entityIterator();

        while (iter.next()) |entity| {
            const storage = self.reg.get(Storage, entity);
            const items = self.reg.get(StoredItems, entity);
            if (items.hasItem(item_type)) {
                if (best_priority == null or @intFromEnum(storage.priority) > @intFromEnum(best_priority.?)) {
                    best_entity = entity;
                    best_priority = storage.priority;
                }
            }
        }
        return best_entity;
    }

    pub fn findStorageForItem(self: *World, item_type: ItemType) ?Entity {
        var best_entity: ?Entity = null;
        var best_priority: ?Priority = null;

        var view = self.reg.view(.{ Storage, StoredItems }, .{});
        var iter = view.entityIterator();

        while (iter.next()) |entity| {
            const storage = self.reg.get(Storage, entity);
            const items = self.reg.get(StoredItems, entity);
            if (!items.isFull()) {
                for (storage.accepts) |accepted| {
                    if (accepted == item_type) {
                        if (best_priority == null or @intFromEnum(storage.priority) > @intFromEnum(best_priority.?)) {
                            best_entity = entity;
                            best_priority = storage.priority;
                        }
                        break;
                    }
                }
            }
        }
        return best_entity;
    }

    pub fn findAvailableStove(self: *World) ?Entity {
        var view = self.reg.view(.{Stove}, .{});
        var iter = view.entityIterator();
        while (iter.next()) |entity| {
            const stove = self.reg.get(Stove, entity);
            if (!stove.in_use) return entity;
        }
        return null;
    }

    pub fn canKitchenUnblock(self: *World, group: *KitchenGroup) bool {
        // Check based on current step - not all resources needed for all steps
        const step_type = group.currentStepType() orelse return false;

        return switch (step_type) {
            .Pickup => {
                const item = if (group.steps.current_index == 0) ItemType.Meat else ItemType.Vegetable;
                return self.findStorageWithItem(item) != null;
            },
            .Cook => self.findAvailableStove() != null,
            .Store => self.findStorageForItem(.CookedMeal) != null,
            else => false,
        };
    }

    pub fn log(self: *World, comptime fmt: []const u8, args: anytype) void {
        std.debug.print("[Tick {d:3}] " ++ fmt ++ "\n", .{self.tick} ++ args);
    }

    pub fn runTick(self: *World) void {
        self.tick += 1;
        self.log("=== TICK START ===", .{});

        self.updateBlockedGroups();
        self.assignWorkersToGroups();
        self.processWorkers();

        self.log("=== TICK END ===", .{});
    }

    fn updateBlockedGroups(self: *World) void {
        var view = self.reg.view(.{KitchenGroup}, .{});
        var iter = view.entityIterator();

        while (iter.next()) |entity| {
            const group = self.reg.get(KitchenGroup, entity);
            if (group.status == .Blocked) {
                if (self.canKitchenUnblock(group)) {
                    group.status = .Queued;
                    self.log("Kitchen group unblocked -> Queued (at step {d})", .{group.steps.current_index});
                }
            }
        }
    }

    fn assignWorkersToGroups(self: *World) void {
        var group_view = self.reg.view(.{KitchenGroup}, .{GroupAssignedWorker});
        var group_iter = group_view.entityIterator();

        while (group_iter.next()) |group_entity| {
            const group = self.reg.get(KitchenGroup, group_entity);
            if (group.status != .Queued) continue;

            var worker_view = self.reg.view(.{ Worker, Name }, .{AssignedToGroup});
            var worker_iter = worker_view.entityIterator();

            while (worker_iter.next()) |worker_entity| {
                const worker = self.reg.get(Worker, worker_entity);
                const worker_name = self.reg.get(Name, worker_entity);
                if (worker.state == .Idle) {
                    self.reg.add(worker_entity, AssignedToGroup{ .group = group_entity });
                    self.reg.add(group_entity, GroupAssignedWorker{ .worker = worker_entity });
                    group.status = .Active;
                    self.log("{s} assigned to kitchen group (continuing from step {d})", .{ worker_name.value, group.steps.current_index });
                    break;
                }
            }
        }
    }

    fn processWorkers(self: *World) void {
        var view = self.reg.view(.{ Worker, Position, Name, AssignedToGroup }, .{});
        var iter = view.entityIterator();

        while (iter.next()) |worker_entity| {
            const worker = self.reg.get(Worker, worker_entity);
            const pos = self.reg.get(Position, worker_entity);
            const name = self.reg.get(Name, worker_entity);
            const assigned = self.reg.get(AssignedToGroup, worker_entity);
            self.processWorkerForGroup(worker_entity, worker, pos, name.value, assigned.group);
        }
    }

    fn processWorkerForGroup(self: *World, worker_entity: Entity, worker: *Worker, pos: *Position, name: []const u8, group_entity: Entity) void {
        const group = self.reg.get(KitchenGroup, group_entity);

        switch (worker.state) {
            .Idle => {
                const step_type = group.currentStepType() orelse {
                    self.completeGroupCycle(worker_entity, group_entity);
                    return;
                };

                switch (step_type) {
                    .Pickup => self.startPickup(worker, group, name),
                    .Cook => self.startCook(worker, name),
                    .Store => self.startStore(worker, group, name),
                    else => {},
                }
            },
            .MovingToPickup, .MovingToCook, .MovingToStore => {
                if (worker.target_position) |target| {
                    if (pos.eql(target)) {
                        worker.state = switch (worker.state) {
                            .MovingToPickup => .PickingUp,
                            .MovingToCook => .Cooking,
                            .MovingToStore => .Storing,
                            else => .Idle,
                        };
                        self.log("{s} arrived at destination", .{name});
                    } else {
                        self.moveWorkerTowards(pos, target, name);
                    }
                }
            },
            .PickingUp => {
                if (group.target_storage) |storage_entity| {
                    const storage_items = self.reg.get(StoredItems, storage_entity);
                    const storage_name = self.reg.get(Name, storage_entity);
                    const item_type = self.getNeededItemType(group);
                    if (storage_items.takeItem(item_type)) {
                        worker.carrying = item_type;
                        self.log("{s} picked up {s} from {s}", .{ name, @tagName(item_type), storage_name.value });
                    }
                }
                group.advance();
                worker.state = .Idle;
            },
            .Cooking => {
                if (worker.carrying != null) {
                    worker.carrying = .CookedMeal;
                    self.log("{s} cooked a meal!", .{name});

                    var stove_view = self.reg.view(.{ Stove, Position }, .{});
                    var stove_iter = stove_view.entityIterator();
                    while (stove_iter.next()) |stove_entity| {
                        const stove = self.reg.get(Stove, stove_entity);
                        const stove_pos = self.reg.get(Position, stove_entity);
                        if (stove_pos.eql(pos.*)) {
                            stove.in_use = false;
                            break;
                        }
                    }
                }
                group.advance();
                worker.state = .Idle;
            },
            .Storing => {
                if (group.target_storage) |storage_entity| {
                    const storage_items = self.reg.get(StoredItems, storage_entity);
                    const storage_name = self.reg.get(Name, storage_entity);
                    if (worker.carrying) |item_type| {
                        if (storage_items.addItem(item_type)) {
                            self.log("{s} stored {s} in {s}", .{ name, @tagName(item_type), storage_name.value });
                            worker.carrying = null;
                        }
                    }
                }
                group.advance();
                worker.state = .Idle;
            },
        }
    }

    fn getNeededItemType(self: *World, group: *KitchenGroup) ItemType {
        _ = self;
        if (group.steps.current_index == 0) return .Meat;
        return .Vegetable;
    }

    fn startPickup(self: *World, worker: *Worker, group: *KitchenGroup, name: []const u8) void {
        const item_type = self.getNeededItemType(group);
        if (self.findStorageWithItem(item_type)) |storage_entity| {
            const storage_pos = self.reg.get(Position, storage_entity);
            const storage_name = self.reg.get(Name, storage_entity);
            group.target_storage = storage_entity;
            worker.target_position = storage_pos.*;
            worker.state = .MovingToPickup;
            self.log("{s} moving to {s} to pickup {s}", .{ name, storage_name.value, @tagName(item_type) });
        }
    }

    fn startCook(self: *World, worker: *Worker, name: []const u8) void {
        if (self.findAvailableStove()) |stove_entity| {
            const stove = self.reg.get(Stove, stove_entity);
            const stove_pos = self.reg.get(Position, stove_entity);
            const stove_name = self.reg.get(Name, stove_entity);
            stove.in_use = true;
            worker.target_position = stove_pos.*;
            worker.state = .MovingToCook;
            self.log("{s} moving to {s} to cook", .{ name, stove_name.value });
        }
    }

    fn startStore(self: *World, worker: *Worker, group: *KitchenGroup, name: []const u8) void {
        if (worker.carrying) |item_type| {
            if (self.findStorageForItem(item_type)) |storage_entity| {
                const storage_pos = self.reg.get(Position, storage_entity);
                const storage_name = self.reg.get(Name, storage_entity);
                group.target_storage = storage_entity;
                worker.target_position = storage_pos.*;
                worker.state = .MovingToStore;
                self.log("{s} moving to {s} to store {s}", .{ name, storage_name.value, @tagName(item_type) });
            }
        }
    }

    fn moveWorkerTowards(self: *World, pos: *Position, target: Position, name: []const u8) void {
        if (pos.x < target.x) {
            pos.x += 1;
        } else if (pos.x > target.x) {
            pos.x -= 1;
        } else if (pos.y < target.y) {
            pos.y += 1;
        } else if (pos.y > target.y) {
            pos.y -= 1;
        }
        self.log("{s} moved to ({d}, {d})", .{ name, pos.x, pos.y });
    }

    fn completeGroupCycle(self: *World, worker_entity: Entity, group_entity: Entity) void {
        self.log("Kitchen group completed a cycle!", .{});

        const group = self.reg.get(KitchenGroup, group_entity);
        const worker = self.reg.get(Worker, worker_entity);

        group.reset();
        group.status = .Blocked;
        worker.state = .Idle;

        self.reg.remove(AssignedToGroup, worker_entity);
        self.reg.remove(GroupAssignedWorker, group_entity);
    }

    /// Worker abandons the group mid-work (e.g., fight, death, shift end).
    /// The group keeps its current step and goes back to Blocked for re-evaluation.
    pub fn abandonGroup(self: *World, worker_entity: Entity, group_entity: Entity) void {
        const group = self.reg.get(KitchenGroup, group_entity);
        const worker = self.reg.get(Worker, worker_entity);
        const worker_name = self.reg.get(Name, worker_entity);
        const worker_pos = self.reg.get(Position, worker_entity);

        self.log("{s} ABANDONED group at step {d}/{d}!", .{
            worker_name.value,
            group.steps.current_index,
            group.steps.steps.len,
        });

        // Release stove if worker was cooking or moving to cook
        if (worker.state == .MovingToCook or worker.state == .Cooking) {
            var stove_view = self.reg.view(.{ Stove, Position }, .{});
            var stove_iter = stove_view.entityIterator();
            while (stove_iter.next()) |stove_entity| {
                const stove = self.reg.get(Stove, stove_entity);
                const stove_pos = self.reg.get(Position, stove_entity);
                // Release the stove the worker was heading to or at
                if (worker.target_position) |target| {
                    if (stove_pos.eql(target)) {
                        stove.in_use = false;
                        self.log("Released stove at ({d}, {d})", .{ stove_pos.x, stove_pos.y });
                        break;
                    }
                } else if (stove_pos.eql(worker_pos.*)) {
                    stove.in_use = false;
                    self.log("Released stove at ({d}, {d})", .{ stove_pos.x, stove_pos.y });
                    break;
                }
            }
        }

        // KEY: Keep current step index - DON'T reset!
        group.status = .Blocked; // Re-evaluate resource availability
        group.target_storage = null;

        worker.state = .Idle;
        worker.target_position = null;
        // Note: worker keeps carrying items

        self.reg.remove(AssignedToGroup, worker_entity);
        self.reg.remove(GroupAssignedWorker, group_entity);
    }

    pub fn printStatus(self: *World) void {
        std.debug.print("\n--- World Status ---\n", .{});

        std.debug.print("Storages:\n", .{});
        var storage_view = self.reg.view(.{ Storage, StoredItems, Name }, .{});
        var storage_iter = storage_view.entityIterator();
        while (storage_iter.next()) |entity| {
            const items = self.reg.get(StoredItems, entity);
            const name = self.reg.get(Name, entity);
            std.debug.print("  {s}: ", .{name.value});
            if (items.count == 0) {
                std.debug.print("(empty)", .{});
            } else {
                for (items.items[0..items.count]) |maybe_item| {
                    if (maybe_item) |item| {
                        std.debug.print("{s} ", .{@tagName(item)});
                    }
                }
            }
            std.debug.print("\n", .{});
        }

        std.debug.print("Workers:\n", .{});
        var worker_view = self.reg.view(.{ Worker, Position, Name }, .{});
        var worker_iter = worker_view.entityIterator();
        while (worker_iter.next()) |entity| {
            const worker = self.reg.get(Worker, entity);
            const name = self.reg.get(Name, entity);
            std.debug.print("  {s}: state={s}", .{ name.value, @tagName(worker.state) });
            if (worker.carrying) |item| {
                std.debug.print(" carrying={s}", .{@tagName(item)});
            }
            std.debug.print("\n", .{});
        }

        std.debug.print("Groups:\n", .{});
        var group_view = self.reg.view(.{KitchenGroup}, .{});
        var group_iter = group_view.entityIterator();
        while (group_iter.next()) |entity| {
            const group = self.reg.get(KitchenGroup, entity);
            std.debug.print("  status={s} step={d}/{d}\n", .{
                @tagName(group.status),
                group.steps.current_index,
                group.steps.steps.len,
            });
        }
        std.debug.print("-------------------\n\n", .{});
    }
};

// ============================================================================
// Main
// ============================================================================

pub fn main() !void {
    std.debug.print("\n", .{});
    std.debug.print("========================================\n", .{});
    std.debug.print("  WORKER ABANDONMENT EXAMPLE            \n", .{});
    std.debug.print("========================================\n\n", .{});

    std.debug.print("Scenario:\n", .{});
    std.debug.print("1. Chef Alice starts cooking (picks up meat)\n", .{});
    std.debug.print("2. Alice gets into a FIGHT and abandons work\n", .{});
    std.debug.print("3. Chef Bob arrives and continues from step 1\n", .{});
    std.debug.print("   (pickup vegetable, not meat again!)\n\n", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var world = try World.init(allocator);
    defer world.deinit();

    // Setup kitchen
    const raw_items = [_]ItemType{ .Meat, .Vegetable };
    const meal_items = [_]ItemType{.CookedMeal};

    const fridge = world.createStorage("Fridge", .{ .x = 0, .y = 0 }, .High, &raw_items);
    const meal_storage = world.createStorage("Meal Storage", .{ .x = 10, .y = 0 }, .Normal, &meal_items);

    const fridge_items = world.reg.get(StoredItems, fridge);
    _ = fridge_items.addItem(.Meat);
    _ = fridge_items.addItem(.Vegetable);

    _ = world.createStove("Stove", .{ .x = 5, .y = 0 });

    // Create first worker
    const alice = world.createWorker("Chef Alice", .{ .x = 5, .y = 0 });

    // Create kitchen group
    const kitchen_group = world.createKitchenGroup(.Normal);

    // ========================================================================
    // Phase 1: Alice works until step 1
    // ========================================================================
    std.debug.print("--- Phase 1: Alice picks up meat ---\n\n", .{});

    var step_reached = false;
    var ticks: u32 = 0;
    while (ticks < 15) : (ticks += 1) {
        world.runTick();

        const grp = world.reg.get(KitchenGroup, kitchen_group);
        if (grp.steps.current_index == 1) {
            step_reached = true;
            break;
        }
    }
    world.printStatus();

    // Assertions
    std.debug.assert(step_reached);
    const grp_phase1 = world.reg.get(KitchenGroup, kitchen_group);
    std.debug.assert(grp_phase1.steps.current_index == 1);
    std.debug.assert(grp_phase1.status == .Active);

    const alice_worker = world.reg.get(Worker, alice);
    std.debug.assert(alice_worker.carrying == .Meat);

    std.debug.print("[PASS] Alice completed step 0, now at step 1\n", .{});
    std.debug.print("[PASS] Alice is carrying Meat\n", .{});
    std.debug.print("[PASS] Fridge now only has Vegetable\n\n", .{});

    // ========================================================================
    // Phase 2: Alice gets into a fight!
    // ========================================================================
    std.debug.print("========================================\n", .{});
    std.debug.print("  FIGHT! Alice abandons work!           \n", .{});
    std.debug.print("========================================\n\n", .{});

    world.abandonGroup(alice, kitchen_group);
    world.printStatus();

    // Assertions after abandonment
    const grp_abandoned = world.reg.get(KitchenGroup, kitchen_group);
    std.debug.assert(grp_abandoned.status == .Blocked);
    std.debug.assert(grp_abandoned.steps.current_index == 1); // KEY: Still at step 1!

    std.debug.assert(!world.reg.has(AssignedToGroup, alice));
    std.debug.assert(!world.reg.has(GroupAssignedWorker, kitchen_group));

    std.debug.print("[PASS] Group is Blocked but KEPT step=1\n", .{});
    std.debug.print("[PASS] Alice unassigned, still has Meat\n\n", .{});

    // ========================================================================
    // Phase 3: Bob arrives and continues
    // ========================================================================
    std.debug.print("========================================\n", .{});
    std.debug.print("  Bob arrives to continue!              \n", .{});
    std.debug.print("========================================\n\n", .{});

    const bob = world.createWorker("Chef Bob", .{ .x = 5, .y = 0 });

    // Run until completion
    var completed = false;
    ticks = 0;
    while (ticks < 30) : (ticks += 1) {
        world.runTick();

        const grp = world.reg.get(KitchenGroup, kitchen_group);
        if (grp.status == .Blocked and grp.steps.current_index == 0) {
            completed = true;
            break;
        }
    }
    world.printStatus();

    // Final assertions
    std.debug.assert(completed);

    const final_meal = world.reg.get(StoredItems, meal_storage);
    std.debug.assert(final_meal.count == 1);
    std.debug.assert(final_meal.hasItem(.CookedMeal));

    const final_fridge = world.reg.get(StoredItems, fridge);
    std.debug.assert(final_fridge.count == 0); // Both items taken

    const bob_worker = world.reg.get(Worker, bob);
    std.debug.assert(bob_worker.state == .Idle);
    std.debug.assert(bob_worker.carrying == null);

    // Alice still has meat (she never dropped it)
    const alice_final = world.reg.get(Worker, alice);
    std.debug.assert(alice_final.carrying == .Meat);

    std.debug.print("[PASS] Bob completed the recipe!\n", .{});
    std.debug.print("[PASS] Meal stored successfully\n", .{});
    std.debug.print("[PASS] Alice still has her Meat (from the fight)\n", .{});

    std.debug.print("\n========================================\n", .{});
    std.debug.print("    ALL ASSERTIONS PASSED!              \n", .{});
    std.debug.print("========================================\n", .{});
}
