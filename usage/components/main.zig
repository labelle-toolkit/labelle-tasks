//! Components Usage Example
//!
//! Demonstrates how a game using labelle-engine would use labelle-tasks
//! components with its own item type enums.
//!
//! This shows the pattern for:
//! - Defining game-specific item categories
//! - Mapping categories to ItemCategory bitmasks
//! - Configuring storages to accept specific item types
//! - Creating items with their categories

const std = @import("std");
const tasks = @import("labelle_tasks");

const Components = tasks.Components;
const C = Components.ItemCategory;

// ============================================================================
// Game-Specific Item Categories
// ============================================================================

/// Game's item type enum - maps to ItemCategory bitmasks.
pub const ItemType = enum(u16) {
    // Raw materials
    carrot = C.category_1,
    potato = C.category_2,
    wheat = C.category_3,

    // Processed foods
    bread = C.category_4,
    soup = C.category_5,

    // Tools
    hoe = C.category_6,
    axe = C.category_7,

    /// Get the bitmask value for this item type.
    pub fn mask(self: ItemType) u16 {
        return @intFromEnum(self);
    }
};

/// Category groups for storage filtering.
pub const ItemGroup = struct {
    pub const raw_vegetables: u16 = ItemType.carrot.mask() | ItemType.potato.mask();
    pub const grains: u16 = ItemType.wheat.mask();
    pub const raw_food: u16 = raw_vegetables | grains;
    pub const cooked_food: u16 = ItemType.bread.mask() | ItemType.soup.mask();
    pub const all_food: u16 = raw_food | cooked_food;
    pub const tools: u16 = ItemType.hoe.mask() | ItemType.axe.mask();
};

// ============================================================================
// Example: How components would be used in .zon prefab files
// ============================================================================

/// Example prefab for a vegetable crate (accepts only raw vegetables).
const vegetable_crate_prefab = Components.TaskStorage{
    .accepts = ItemGroup.raw_vegetables,
};

/// Example prefab for a food storage (accepts all food).
const pantry_prefab = Components.TaskStorage{
    .accepts = ItemGroup.all_food,
};

/// Example prefab for a tool rack (accepts only tools).
const tool_rack_prefab = Components.TaskStorage{
    .accepts = ItemGroup.tools,
};

/// Example prefab for a general storage (accepts everything).
const general_storage_prefab = Components.TaskStorage{
    .accepts = C.all,
};

/// Example prefab for a carrot item.
const carrot_prefab = Components.TaskItem{
    .category = ItemType.carrot.mask(),
};

/// Example prefab for bread item.
const bread_prefab = Components.TaskItem{
    .category = ItemType.bread.mask(),
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
// Helper: Check if storage accepts item
// ============================================================================

pub fn storageAccepts(storage: Components.TaskStorage, item: Components.TaskItem) bool {
    return (storage.accepts & item.category) != 0;
}

// ============================================================================
// Main: Demonstrate the pattern
// ============================================================================

pub fn main() !void {
    std.debug.print("\n", .{});
    std.debug.print("========================================\n", .{});
    std.debug.print("  COMPONENTS USAGE EXAMPLE              \n", .{});
    std.debug.print("========================================\n\n", .{});

    std.debug.print("This example shows how a game would define\n", .{});
    std.debug.print("item categories and use Components for ECS.\n\n", .{});

    // Test storage acceptance
    std.debug.print("--- Storage Acceptance Tests ---\n\n", .{});

    const carrot = carrot_prefab;
    const bread = bread_prefab;

    // Vegetable crate
    std.debug.print("Vegetable Crate:\n", .{});
    std.debug.print("  accepts carrot: {}\n", .{storageAccepts(vegetable_crate_prefab, carrot)});
    std.debug.print("  accepts bread:  {}\n\n", .{storageAccepts(vegetable_crate_prefab, bread)});

    // Pantry
    std.debug.print("Pantry (all food):\n", .{});
    std.debug.print("  accepts carrot: {}\n", .{storageAccepts(pantry_prefab, carrot)});
    std.debug.print("  accepts bread:  {}\n\n", .{storageAccepts(pantry_prefab, bread)});

    // Tool rack
    std.debug.print("Tool Rack:\n", .{});
    std.debug.print("  accepts carrot: {}\n", .{storageAccepts(tool_rack_prefab, carrot)});
    std.debug.print("  accepts bread:  {}\n\n", .{storageAccepts(tool_rack_prefab, bread)});

    // General storage
    std.debug.print("General Storage:\n", .{});
    std.debug.print("  accepts carrot: {}\n", .{storageAccepts(general_storage_prefab, carrot)});
    std.debug.print("  accepts bread:  {}\n\n", .{storageAccepts(general_storage_prefab, bread)});

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
