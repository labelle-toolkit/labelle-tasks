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
