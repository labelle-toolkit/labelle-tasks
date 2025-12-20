//! Components Usage Example
//!
//! Demonstrates how a game using labelle-engine would use labelle-tasks
//! components with its own item type enum.
//!
//! This shows the pattern for:
//! - Defining game-specific item types
//! - Creating Components parameterized by the item type
//! - Configuring storages to accept specific item types (single or multiple)
//! - Creating items with their type

const std = @import("std");
const tasks = @import("labelle_tasks");

// ============================================================================
// Game-Specific Item Type
// ============================================================================

/// Game's item type enum - passed to Components() to create typed components.
pub const ItemType = enum {
    // Raw materials
    carrot,
    potato,
    wheat,

    // Processed foods
    bread,
    soup,

    // Tools
    hoe,
    axe,
};

// Create components parameterized by our item type
const Components = tasks.Components(ItemType);
const ItemSet = Components.ItemSet;

// ============================================================================
// Example: How components would be used in prefabs
// ============================================================================

/// Example prefab for a wheat-only storage.
const wheat_silo_prefab = Components.TaskStorage{
    .accepts = ItemSet.initOne(.wheat),
};

/// Example prefab for a vegetable storage (accepts multiple types).
const vegetable_crate_prefab = Components.TaskStorage{
    .accepts = ItemSet.initMany(&.{ .carrot, .potato }),
};

/// Example prefab for a general storage (accepts everything - default).
const general_storage_prefab = Components.TaskStorage{};

/// Example prefab for a carrot item.
const carrot_prefab = Components.TaskItem{
    .item_type = .carrot,
};

/// Example prefab for wheat item.
const wheat_prefab = Components.TaskItem{
    .item_type = .wheat,
};

/// Example prefab for a farm worker.
const farmer_prefab = Components.TaskWorker{
    .priority = 7, // high priority
};

/// Example prefab for a kitchen workstation.
const kitchen_prefab = Components.TaskWorkstation{
    .process_duration = 60, // 60 ticks to cook
    .priority = 5,
};

// ============================================================================
// Helper to test and print storage acceptance
// ============================================================================

fn testStorage(name: []const u8, storage: Components.TaskStorage, carrot: Components.TaskItem, wheat: Components.TaskItem) void {
    std.debug.print("{s}:\n", .{name});
    std.debug.print("  accepts carrot: {}\n", .{storage.canAccept(carrot.item_type)});
    std.debug.print("  accepts wheat:  {}\n\n", .{storage.canAccept(wheat.item_type)});
}

// ============================================================================
// Main: Demonstrate the pattern
// ============================================================================

pub fn main() !void {
    std.debug.print("\n", .{});
    std.debug.print("========================================\n", .{});
    std.debug.print("  COMPONENTS USAGE EXAMPLE              \n", .{});
    std.debug.print("========================================\n\n", .{});

    std.debug.print("This example shows how a game defines\n", .{});
    std.debug.print("its ItemType enum and uses Components.\n\n", .{});

    // Test storage acceptance
    std.debug.print("--- Storage Acceptance Tests ---\n\n", .{});

    testStorage("Wheat Silo (wheat only)", wheat_silo_prefab, carrot_prefab, wheat_prefab);
    testStorage("Vegetable Crate (carrot, potato)", vegetable_crate_prefab, carrot_prefab, wheat_prefab);
    testStorage("General Storage (accepts all)", general_storage_prefab, carrot_prefab, wheat_prefab);

    // Show component values
    std.debug.print("--- Component Values ---\n\n", .{});

    std.debug.print("Farmer:  priority = {}\n", .{farmer_prefab.priority});
    std.debug.print("Kitchen: process_duration = {}, priority = {}\n", .{
        kitchen_prefab.process_duration,
        kitchen_prefab.priority,
    });

    std.debug.print("\n========================================\n", .{});
    std.debug.print("  EXAMPLE COMPLETE                      \n", .{});
    std.debug.print("========================================\n", .{});
}
