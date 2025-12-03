//! Logging infrastructure for labelle-tasks
//!
//! Provides scoped logging using Zig's standard library logging facilities.
//! Users can configure log levels at compile-time via std.options or
//! use the default log level.
//!
//! Example usage:
//! ```zig
//! // In your build.zig or root file, override the log level:
//! pub const std_options: std.Options = .{
//!     .log_level = .debug,
//!     .log_scope_levels = &.{
//!         .{ .scope = .labelle_tasks_engine, .level = .info },
//!         .{ .scope = .labelle_tasks_storage, .level = .warn },
//!     },
//! };
//! ```

const std = @import("std");

/// Log scopes for different subsystems
pub const Scope = enum {
    engine,
    storage,
};

/// Engine logger - for task orchestration, worker assignments, workstation state changes
pub const engine = std.log.scoped(.labelle_tasks_engine);

/// Storage logger - for item additions, removals, and transfers
pub const storage = std.log.scoped(.labelle_tasks_storage);

/// Format a game ID for logging. Returns a formatted string representation.
/// For integer types, returns the integer value. For other types, returns a hash.
pub fn fmtGameId(comptime GameId: type, id: GameId) u64 {
    return switch (@typeInfo(GameId)) {
        .int => @intCast(id),
        .pointer => @intFromPtr(id),
        else => std.hash.Wyhash.hash(0, std.mem.asBytes(&id)),
    };
}

/// Format an item for logging. Returns the enum tag name if available.
pub fn fmtItem(comptime Item: type, item: Item) []const u8 {
    return switch (@typeInfo(Item)) {
        .@"enum" => @tagName(item),
        else => "<item>",
    };
}
