//! Kitchen Simulator - Demonstrates pure state machine task engine
//!
//! This example shows how to use the task engine to orchestrate
//! a simple kitchen simulation with workstations and workers.

const std = @import("std");
const tasks = @import("labelle_tasks");

// === Item Types ===

const Item = enum {
    RawDough,
    Topping,
    Pizza,
    DirtyPlate,
    CleanPlate,
};

// === Hook Handlers ===

const KitchenHooks = struct {
    pub fn process_completed(payload: anytype) void {
        std.debug.print("[Kitchen] Process completed at workstation {d}\n", .{payload.workstation_id});
    }

    pub fn cycle_completed(payload: anytype) void {
        std.debug.print("[Kitchen] Cycle {d} completed at workstation {d}\n", .{
            payload.cycles_completed,
            payload.workstation_id,
        });
    }

    pub fn worker_assigned(payload: anytype) void {
        std.debug.print("[Kitchen] Worker {d} assigned to workstation {d}\n", .{
            payload.worker_id,
            payload.workstation_id,
        });
    }

    pub fn pickup_started(payload: anytype) void {
        std.debug.print("[Kitchen] Worker {d} picking up from storage {d}\n", .{
            payload.worker_id,
            payload.storage_id,
        });
    }
};

// === Main ===

pub fn main() !void {
    std.debug.print("Kitchen Simulator - Pure State Machine Demo\n", .{});
    std.debug.print("============================================\n\n", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create the task engine
    var engine = tasks.Engine(u32, Item, KitchenHooks).init(allocator, .{}, null);
    defer engine.deinit();

    // Register storages
    // Oven workstation storages
    try engine.addStorage(1, .RawDough); // EIS - raw dough pantry
    try engine.addStorage(2, .Topping); // EIS - topping storage
    try engine.addStorage(3, null); // IIS - oven input 1
    try engine.addStorage(4, null); // IIS - oven input 2
    try engine.addStorage(5, null); // IOS - oven output
    try engine.addStorage(6, null); // EOS - pizza shelf

    std.debug.print("Registered 6 storages\n", .{});

    // Register oven workstation
    try engine.addWorkstation(100, .{
        .eis = &.{ 1, 2 },
        .iis = &.{ 3, 4 },
        .ios = &.{5},
        .eos = &.{6},
    });

    std.debug.print("Registered oven workstation (id=100)\n", .{});
    std.debug.print("  Status: {s}\n\n", .{@tagName(engine.getWorkstationStatus(100).?)});

    // Register a worker
    try engine.addWorker(10);
    std.debug.print("Registered worker (id=10)\n", .{});
    std.debug.print("  State: {s}\n\n", .{@tagName(engine.getWorkerState(10).?)});

    // Simulate: worker becomes available
    std.debug.print("--- Simulating worker availability ---\n", .{});
    _ = engine.workerAvailable(10);
    std.debug.print("Worker state: {s}\n", .{@tagName(engine.getWorkerState(10).?)});
    std.debug.print("Workstation status: {s}\n\n", .{@tagName(engine.getWorkstationStatus(100).?)});

    // Simulate: worker completes pickup
    std.debug.print("--- Simulating pickup completion ---\n", .{});
    _ = engine.pickupCompleted(10);

    // Check storage states
    std.debug.print("\nStorage states:\n", .{});
    for ([_]u32{ 1, 2, 3, 4, 5, 6 }) |id| {
        const has_item = engine.getStorageHasItem(id).?;
        const item = engine.getStorageItemType(id);
        if (item) |it| {
            std.debug.print("  Storage {d}: has_item={}, item={s}\n", .{ id, has_item, @tagName(it) });
        } else {
            std.debug.print("  Storage {d}: has_item={}, item=null\n", .{ id, has_item });
        }
    }

    std.debug.print("\nKitchen simulator complete.\n", .{});
}
