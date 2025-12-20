//! labelle-tasks: Task orchestration engine for Zig games
//!
//! A self-contained task orchestration engine with storage management.
//! Games interact via:
//! - Creating storages (EIS, IIS, IOS, EOS) as separate entities
//! - Creating workstations that reference storages
//! - Providing callbacks for game-specific logic (movement, animations)
//! - Notifying the engine of game events (pickup complete, store complete)
//!
//! Example:
//! ```zig
//! const Item = enum { Vegetable, Meat, Meal };
//! var engine = tasks.Engine(u32, Item).init(allocator);
//! defer engine.deinit();
//!
//! // Create storages
//! _ = engine.addStorage(EIS_ID, .{ .slots = &.{
//!     .{ .item = .Vegetable, .capacity = 10 },
//! }});
//!
//! // Create workstation referencing storages
//! _ = engine.addWorkstation(KITCHEN_ID, .{
//!     .eis = EIS_ID,
//!     .iis = IIS_ID,
//!     .ios = IOS_ID,
//!     .eos = EOS_ID,
//!     .process_duration = 40,
//! });
//!
//! // Add items and engine automatically manages state
//! _ = engine.addToStorage(EIS_ID, .Vegetable, 5);
//! ```
//!
//! ## Logging
//!
//! The engine uses Zig's standard library scoped logging. Configure log levels
//! in your root file:
//!
//! ```zig
//! pub const std_options: std.Options = .{
//!     .log_level = .debug,
//!     .log_scope_levels = &.{
//!         .{ .scope = .labelle_tasks_engine, .level = .info },
//!         .{ .scope = .labelle_tasks_storage, .level = .warn },
//!     },
//! };
//! ```

const std = @import("std");

// ============================================================================
// Engine API
// ============================================================================

pub const Engine = @import("engine.zig").Engine;

// ============================================================================
// Logging
// ============================================================================

pub const log = @import("log.zig");

// ============================================================================
// Common Types
// ============================================================================

pub const Priority = enum {
    Low,
    Normal,
    High,
    Critical,
};

pub const StepType = @import("engine.zig").StepType;

// ============================================================================
// ECS Components (for plugin integration)
// ============================================================================

/// Components that can be used with labelle-engine's ComponentRegistryMulti.
/// These types can be declared in .zon prefab/scene files.
pub const Components = struct {
    /// Item category bitmask constants.
    /// Use these values for TaskStorage.accepts and TaskItem.category.
    /// Combine with bitwise OR: `category_1 | category_2`
    ///
    /// Example:
    /// ```zig
    /// const C = Components.ItemCategory;
    /// .TaskStorage = .{ .accepts = C.category_1 | C.category_2 },
    /// .TaskItem = .{ .category = C.category_1 },
    /// ```
    pub const ItemCategory = struct {
        pub const category_1: u16 = 1 << 0;
        pub const category_2: u16 = 1 << 1;
        pub const category_3: u16 = 1 << 2;
        pub const category_4: u16 = 1 << 3;
        pub const category_5: u16 = 1 << 4;
        pub const category_6: u16 = 1 << 5;
        pub const category_7: u16 = 1 << 6;
        pub const category_8: u16 = 1 << 7;
        pub const category_9: u16 = 1 << 8;
        pub const category_10: u16 = 1 << 9;
        pub const category_11: u16 = 1 << 10;
        pub const category_12: u16 = 1 << 11;
        pub const category_13: u16 = 1 << 12;
        pub const category_14: u16 = 1 << 13;
        pub const category_15: u16 = 1 << 14;
        pub const category_16: u16 = 1 << 15;
        pub const all: u16 = 0xFFFF;
    };

    /// Marks an entity as a worker that can perform tasks.
    pub const TaskWorker = struct {
        /// Worker priority for task assignment (0-15, higher = more important).
        priority: u4 = 5,
    };

    /// Configures an entity as a workstation that processes items.
    pub const TaskWorkstation = struct {
        /// Duration in ticks for the processing step.
        process_duration: u32 = 0,
        /// Workstation priority for worker assignment (0-15, higher = more important).
        priority: u4 = 5,
    };

    /// Marks an entity as a storage location that can hold items of specified categories.
    pub const TaskStorage = struct {
        /// Bitmask of item categories this storage accepts.
        accepts: u16 = ItemCategory.all,
    };

    /// Marks an entity as an item that can be stored or carried.
    pub const TaskItem = struct {
        /// Category bitmask for this item (matched against storage accepts).
        category: u16 = ItemCategory.category_1,
    };

    /// Configures a transport route between two storages.
    pub const TaskTransport = struct {
        /// Priority for transport task assignment (0-15, higher = more important).
        priority: u4 = 5,
    };
};
