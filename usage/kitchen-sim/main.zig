//! Kitchen Simulator - Demonstrates comptime workstation task system
//!
//! This example shows how to define workstation types and register them
//! with the TasksPlugin for a simple kitchen simulation.

const std = @import("std");
const tasks = @import("labelle_tasks");

// === Workstation Types ===
// Each workstation type has fixed storage counts: (EIS, IIS, IOS, EOS)

/// Oven: 1 external input, 2 internal inputs (e.g., dough + topping), 1 output each
pub const OvenWorkstation = tasks.TaskWorkstation(1, 2, 1, 1);

/// Prep table: 2 external inputs, 1 internal input, 1 output each
pub const PrepTableWorkstation = tasks.TaskWorkstation(2, 1, 1, 1);

/// Sink: 1 external input, 1 internal input, 1 output each (for washing)
pub const SinkWorkstation = tasks.TaskWorkstation(1, 1, 1, 1);

// === Plugin Registration ===

pub const KitchenTasks = tasks.TasksPlugin(.{
    .workstations = &.{
        OvenWorkstation,
        PrepTableWorkstation,
        SinkWorkstation,
    },
});

// === Main ===

pub fn main() void {
    std.debug.print("Kitchen Simulator - Comptime Workstation Demo\n", .{});
    std.debug.print("==============================================\n\n", .{});

    // Show registered workstations
    std.debug.print("Registered workstations: {d}\n\n", .{KitchenTasks.workstation_count});

    inline for (0..KitchenTasks.workstation_count) |i| {
        const info = KitchenTasks.getWorkstationInfo(i);
        std.debug.print("Workstation {d}:\n", .{i});
        std.debug.print("  EIS (external input):  {d}\n", .{info.eis_count});
        std.debug.print("  IIS (internal input):  {d}\n", .{info.iis_count});
        std.debug.print("  IOS (internal output): {d}\n", .{info.ios_count});
        std.debug.print("  EOS (external output): {d}\n\n", .{info.eos_count});
    }

    // Demonstrate component types
    std.debug.print("Components available for ECS registration:\n", .{});
    std.debug.print("  - TaskWorkstationBinding\n", .{});
    std.debug.print("  - TaskStorage\n", .{});
    std.debug.print("  - TaskStorageRole\n", .{});

    std.debug.print("\nKitchen simulator placeholder complete.\n", .{});
}
