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

/// Creates component types parameterized by the game's item type.
///
/// Example:
/// ```zig
/// const ItemType = enum { wheat, carrot, flour };
/// const C = labelle_tasks.Components(ItemType);
///
/// // Storage accepting specific items
/// .TaskStorage = .{ .accepts = C.ItemSet.initMany(&.{ .wheat, .carrot }) },
///
/// // Storage accepting all items (default)
/// .TaskStorage = .{},
/// ```
pub fn Components(comptime ItemType: type) type {
    return struct {
        /// Set type for combining multiple item types.
        pub const ItemSet = std.EnumSet(ItemType);

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

        /// Marks an entity as a storage location.
        pub const TaskStorage = struct {
            /// Set of item types this storage accepts. Defaults to all items.
            accepts: ItemSet = ItemSet.initFull(),

            /// Check if this storage accepts the given item type.
            pub fn canAccept(self: TaskStorage, item_type: ItemType) bool {
                return self.accepts.contains(item_type);
            }
        };

        /// Marks an entity as an item that can be stored or carried.
        pub const TaskItem = struct {
            /// The type of this item.
            item_type: ItemType,
        };

        /// Configures a transport route between two storages.
        pub const TaskTransport = struct {
            /// Priority for transport task assignment (0-15, higher = more important).
            priority: u4 = 5,
        };
    };
}
