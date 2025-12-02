//! Kitchen Example with zig-ecs
//!
//! Demonstrates the labelle-tasks system with a kitchen workflow using ECS:
//! - Workers pick up ingredients from storage
//! - Workers cook at the stove
//! - Workers store finished meals
//!
//! Each action takes 1 tick. Moving to a location takes 1 tick.

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

const Position = struct {
    x: i32,
    y: i32,

    pub fn distance(self: Position, other: Position) u32 {
        const dx = if (self.x > other.x) self.x - other.x else other.x - self.x;
        const dy = if (self.y > other.y) self.y - other.y else other.y - self.y;
        return @intCast(dx + dy);
    }

    pub fn eql(self: Position, other: Position) bool {
        return self.x == other.x and self.y == other.y;
    }
};

const Name = struct {
    value: []const u8,
};

// Item types
const ItemType = enum {
    Meat,
    Vegetable,
    CookedMeal,
};

// Storage component - marks an entity as a storage location
const Storage = struct {
    priority: Priority,
    accepts: []const ItemType,
};

// Items stored in a storage (component on storage entity)
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
                    // Compact array
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

// Stove component
const Stove = struct {
    in_use: bool = false,
};

// Worker state
const WorkerState = enum {
    Idle,
    MovingToPickup,
    PickingUp,
    MovingToCook,
    Cooking,
    MovingToStore,
    Storing,
};

// Worker component
const Worker = struct {
    state: WorkerState = .Idle,
    target_position: ?Position = null,
    carrying: ?ItemType = null,
};

// Assignment components
const AssignedToGroup = struct {
    group: Entity,
};

const GroupAssignedWorker = struct {
    worker: Entity,
};

// Kitchen task group component
const KitchenGroup = struct {
    status: TaskGroupStatus = .Blocked,
    priority: Priority,
    steps: GroupSteps,
    target_storage: ?Entity = null,

    const kitchen_steps = [_]StepDef{
        .{ .type = .Pickup }, // pickup meat
        .{ .type = .Pickup }, // pickup vegetable
        .{ .type = .Cook }, // cook at stove
        .{ .type = .Store }, // store cooked meal
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
// World / Game Engine
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

    // Find best storage with item, preferring higher priority
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

    // Find best storage that can accept item
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

    pub fn canKitchenUnblock(self: *World) bool {
        const has_meat = self.findStorageWithItem(.Meat) != null;
        const has_veg = self.findStorageWithItem(.Vegetable) != null;
        const has_storage = self.findStorageForItem(.CookedMeal) != null;
        const has_stove = self.findAvailableStove() != null;
        return has_meat and has_veg and has_storage and has_stove;
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
        self.printStatus();
    }

    fn updateBlockedGroups(self: *World) void {
        var view = self.reg.view(.{KitchenGroup}, .{});
        var iter = view.entityIterator();

        while (iter.next()) |entity| {
            const group = self.reg.get(KitchenGroup, entity);
            if (group.status == .Blocked) {
                if (self.canKitchenUnblock()) {
                    group.status = .Queued;
                    self.log("Kitchen group unblocked -> Queued", .{});
                }
            }
        }
    }

    fn assignWorkersToGroups(self: *World) void {
        // Find queued groups without workers
        var group_view = self.reg.view(.{KitchenGroup}, .{GroupAssignedWorker});
        var group_iter = group_view.entityIterator();

        while (group_iter.next()) |group_entity| {
            const group = self.reg.get(KitchenGroup, group_entity);
            if (group.status != .Queued) continue;

            // Find idle worker
            var worker_view = self.reg.view(.{ Worker, Name }, .{AssignedToGroup});
            var worker_iter = worker_view.entityIterator();

            while (worker_iter.next()) |worker_entity| {
                const worker = self.reg.get(Worker, worker_entity);
                const worker_name = self.reg.get(Name, worker_entity);
                if (worker.state == .Idle) {
                    // Assign worker to group
                    self.reg.add(worker_entity, AssignedToGroup{ .group = group_entity });
                    self.reg.add(group_entity, GroupAssignedWorker{ .worker = worker_entity });
                    group.status = .Active;
                    self.log("{s} assigned to kitchen group", .{worker_name.value});
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

                    // Release stove
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
                    const storage = self.reg.get(Storage, storage_entity);
                    const storage_name = self.reg.get(Name, storage_entity);
                    if (worker.carrying) |item_type| {
                        if (storage_items.addItem(item_type)) {
                            self.log("{s} stored {s} in {s} (priority: {s})", .{
                                name,
                                @tagName(item_type),
                                storage_name.value,
                                @tagName(storage.priority),
                            });
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

        // Remove assignments
        self.reg.remove(AssignedToGroup, worker_entity);
        self.reg.remove(GroupAssignedWorker, group_entity);
    }

    fn printStatus(self: *World) void {
        std.debug.print("\n--- World Status ---\n", .{});

        std.debug.print("Storages:\n", .{});
        var storage_view = self.reg.view(.{ Storage, StoredItems, Name }, .{});
        var storage_iter = storage_view.entityIterator();
        while (storage_iter.next()) |entity| {
            const storage = self.reg.get(Storage, entity);
            const items = self.reg.get(StoredItems, entity);
            const name = self.reg.get(Name, entity);
            std.debug.print("  {s} (priority: {s}): ", .{ name.value, @tagName(storage.priority) });
            for (items.items[0..items.count]) |maybe_item| {
                if (maybe_item) |item| {
                    std.debug.print("{s} ", .{@tagName(item)});
                }
            }
            std.debug.print("\n", .{});
        }

        std.debug.print("Workers:\n", .{});
        var worker_view = self.reg.view(.{ Worker, Position, Name }, .{});
        var worker_iter = worker_view.entityIterator();
        while (worker_iter.next()) |entity| {
            const worker = self.reg.get(Worker, entity);
            const pos = self.reg.get(Position, entity);
            const name = self.reg.get(Name, entity);
            std.debug.print("  {s} at ({d},{d}) state={s}", .{
                name.value,
                pos.x,
                pos.y,
                @tagName(worker.state),
            });
            if (worker.carrying) |item| {
                std.debug.print(" carrying={s}", .{@tagName(item)});
            }
            std.debug.print("\n", .{});
        }

        std.debug.print("Kitchen Groups:\n", .{});
        var group_view = self.reg.view(.{KitchenGroup}, .{});
        var group_iter = group_view.entityIterator();
        var group_idx: usize = 0;
        while (group_iter.next()) |entity| {
            const group = self.reg.get(KitchenGroup, entity);
            std.debug.print("  Group {d}: status={s} step={d}/{d}\n", .{
                group_idx,
                @tagName(group.status),
                group.steps.current_index,
                group.steps.steps.len,
            });
            group_idx += 1;
        }
        std.debug.print("-------------------\n\n", .{});
    }
};

// ============================================================================
// Main
// ============================================================================

pub fn main() !void {
    std.debug.print("\n========================================\n", .{});
    std.debug.print("  KITCHEN EXAMPLE - labelle-tasks + ECS \n", .{});
    std.debug.print("========================================\n\n", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var world = try World.init(allocator);
    defer world.deinit();

    // Setup world layout:
    //
    //   [Pantry]     [Stove]     [MealStorage-High]
    //   (0,0)        (5,0)       (10,0)
    //
    //   [Fridge]     [Worker]    [MealStorage-Low]
    //   (0,5)        (5,5)       (10,5)
    //

    const raw_items = [_]ItemType{ .Meat, .Vegetable };
    const meal_items = [_]ItemType{.CookedMeal};

    const pantry = world.createStorage("Pantry", .{ .x = 0, .y = 0 }, .Normal, &raw_items);
    const fridge = world.createStorage("Fridge", .{ .x = 0, .y = 5 }, .High, &raw_items);
    const meal_storage_high = world.createStorage("Meal Storage (High)", .{ .x = 10, .y = 0 }, .High, &meal_items);
    const meal_storage_low = world.createStorage("Meal Storage (Low)", .{ .x = 10, .y = 5 }, .Low, &meal_items);

    // Add items to storages
    const fridge_items = world.reg.get(StoredItems, fridge);
    _ = fridge_items.addItem(.Meat);
    _ = fridge_items.addItem(.Vegetable);

    const pantry_items = world.reg.get(StoredItems, pantry);
    _ = pantry_items.addItem(.Meat);
    _ = pantry_items.addItem(.Vegetable);
    _ = pantry_items.addItem(.Meat);
    _ = pantry_items.addItem(.Vegetable);

    // Add stove
    _ = world.createStove("Stove", .{ .x = 5, .y = 0 });

    // Add worker
    const chef = world.createWorker("Chef Bob", .{ .x = 5, .y = 5 });

    // Add kitchen task group
    const kitchen_group = world.createKitchenGroup(.Normal);

    // ========================================================================
    // Initial State Assertions
    // ========================================================================
    std.debug.print("Verifying initial state...\n", .{});

    // Verify storage priorities
    const fridge_storage = world.reg.get(Storage, fridge);
    const pantry_storage = world.reg.get(Storage, pantry);
    std.debug.assert(fridge_storage.priority == .High);
    std.debug.assert(pantry_storage.priority == .Normal);
    std.debug.assert(@intFromEnum(fridge_storage.priority) > @intFromEnum(pantry_storage.priority));

    // Verify initial item counts
    std.debug.assert(fridge_items.count == 2);
    std.debug.assert(pantry_items.count == 4);
    std.debug.assert(world.reg.get(StoredItems, meal_storage_high).count == 0);
    std.debug.assert(world.reg.get(StoredItems, meal_storage_low).count == 0);

    // Verify worker initial state
    const chef_worker = world.reg.get(Worker, chef);
    std.debug.assert(chef_worker.state == .Idle);
    std.debug.assert(chef_worker.carrying == null);

    // Verify group initial state (should start Blocked)
    const group = world.reg.get(KitchenGroup, kitchen_group);
    std.debug.assert(group.status == .Blocked);
    std.debug.assert(group.steps.current_index == 0);

    std.debug.print("Initial state verified!\n\n", .{});

    std.debug.print("Running simulation...\n", .{});
    std.debug.print("- Fridge (High priority) has Meat and Vegetable\n", .{});
    std.debug.print("- Pantry (Normal priority) has Meat, Vegetable, Meat, Vegetable\n", .{});
    std.debug.print("- Worker should pick from Fridge first (higher priority)\n", .{});
    std.debug.print("- Worker should store in Meal Storage (High) first\n\n", .{});

    // ========================================================================
    // Run Simulation
    // ========================================================================
    var cycle_completed = false;
    var max_ticks: u32 = 50;

    while (max_ticks > 0) : (max_ticks -= 1) {
        world.runTick();

        // Check if cycle complete
        const current_group = world.reg.get(KitchenGroup, kitchen_group);
        const current_worker = world.reg.get(Worker, chef);

        if (current_group.status == .Blocked and current_worker.state == .Idle and world.tick > 1) {
            std.debug.print("\n=== Cycle complete at tick {d}! ===\n\n", .{world.tick});
            cycle_completed = true;
            break;
        }
    }

    // ========================================================================
    // Final State Assertions
    // ========================================================================
    std.debug.print("Verifying final state...\n", .{});

    // Assert cycle completed
    std.debug.assert(cycle_completed);

    // Assert Fridge was depleted (high priority source was used)
    const final_fridge_items = world.reg.get(StoredItems, fridge);
    std.debug.assert(final_fridge_items.count == 0);
    std.debug.print("  [PASS] Fridge (High priority) was depleted first\n", .{});

    // Assert Pantry still has items (lower priority, not touched)
    const final_pantry_items = world.reg.get(StoredItems, pantry);
    std.debug.assert(final_pantry_items.count == 4);
    std.debug.print("  [PASS] Pantry (Normal priority) was not touched\n", .{});

    // Assert meal was stored in high priority storage
    const final_meal_high = world.reg.get(StoredItems, meal_storage_high);
    std.debug.assert(final_meal_high.count == 1);
    std.debug.assert(final_meal_high.hasItem(.CookedMeal));
    std.debug.print("  [PASS] Meal stored in Meal Storage (High priority)\n", .{});

    // Assert low priority meal storage is still empty
    const final_meal_low = world.reg.get(StoredItems, meal_storage_low);
    std.debug.assert(final_meal_low.count == 0);
    std.debug.print("  [PASS] Meal Storage (Low priority) was not used\n", .{});

    // Assert worker is back to idle with no items
    const final_worker = world.reg.get(Worker, chef);
    std.debug.assert(final_worker.state == .Idle);
    std.debug.assert(final_worker.carrying == null);
    std.debug.print("  [PASS] Worker is idle with no items\n", .{});

    // Assert group is back to Blocked and reset
    const final_group = world.reg.get(KitchenGroup, kitchen_group);
    std.debug.assert(final_group.status == .Blocked);
    std.debug.assert(final_group.steps.current_index == 0);
    std.debug.print("  [PASS] Kitchen group reset to Blocked, step 0\n", .{});

    // Assert worker is no longer assigned to group
    std.debug.assert(!world.reg.has(AssignedToGroup, chef));
    std.debug.assert(!world.reg.has(GroupAssignedWorker, kitchen_group));
    std.debug.print("  [PASS] Worker unassigned from group\n", .{});

    std.debug.print("\n========================================\n", .{});
    std.debug.print("    ALL ASSERTIONS PASSED!              \n", .{});
    std.debug.print("========================================\n", .{});
}
