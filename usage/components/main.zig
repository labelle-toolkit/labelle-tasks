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

/// Helper to test and print storage acceptance for carrot and bread items.
fn testStorage(name: []const u8, storage: Components.TaskStorage, carrot: Components.TaskItem, bread: Components.TaskItem) void {
    std.debug.print("{s}:\n", .{name});
    std.debug.print("  accepts carrot: {}\n", .{storageAccepts(storage, carrot)});
    std.debug.print("  accepts bread:  {}\n\n", .{storageAccepts(storage, bread)});
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

    testStorage("Vegetable Crate", vegetable_crate_prefab, carrot, bread);
    testStorage("Pantry (all food)", pantry_prefab, carrot, bread);
    testStorage("Tool Rack", tool_rack_prefab, carrot, bread);
    testStorage("General Storage", general_storage_prefab, carrot, bread);

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
