// Predefined workstation types for common use cases
//
// Games can import these directly instead of defining their own.
// For custom workstation layouts, use TaskWorkstation(eis, iis, ios, eos).

const workstation = @import("workstation.zig");
pub const TaskWorkstation = workstation.TaskWorkstation;

// ============================================================================
// Bakery Workstations
// ============================================================================

/// Simple oven: 1 flour → 1 bread
/// - 1 EIS (flour source)
/// - 2 IIS (2 flour needed per bread)
/// - 1 IOS (bread output)
/// - 1 EOS (bread storage)
pub const OvenWorkstation = TaskWorkstation(1, 2, 1, 1);

/// Mixer: flour + water → dough
/// - 2 EIS (flour, water sources)
/// - 2 IIS (flour, water inputs)
/// - 1 IOS (dough output)
/// - 1 EOS (dough storage)
pub const MixerWorkstation = TaskWorkstation(2, 2, 1, 1);

/// Advanced cake oven: flour + eggs + sugar → cake
/// - 3 EIS (flour, eggs, sugar sources)
/// - 3 IIS (flour, eggs, sugar inputs)
/// - 1 IOS (cake output)
/// - 1 EOS (cake storage)
pub const CakeOvenWorkstation = TaskWorkstation(3, 3, 1, 1);

// ============================================================================
// Producer Workstations (no inputs)
// ============================================================================

/// Well: produces water (no inputs)
/// - 0 EIS
/// - 0 IIS
/// - 1 IOS (water output)
/// - 1 EOS (water storage)
pub const WellWorkstation = TaskWorkstation(0, 0, 1, 1);

/// Farm field: produces wheat (no inputs)
/// - 0 EIS
/// - 0 IIS
/// - 1 IOS (wheat output)
/// - 1 EOS (wheat storage)
pub const FarmFieldWorkstation = TaskWorkstation(0, 0, 1, 1);

// ============================================================================
// Crafting Workstations
// ============================================================================

/// Simple crafting table: 1 input → 1 output
pub const SimpleCraftingWorkstation = TaskWorkstation(1, 1, 1, 1);

/// Dual-input crafting: 2 inputs → 1 output
pub const DualCraftingWorkstation = TaskWorkstation(2, 2, 1, 1);

/// Triple-input crafting: 3 inputs → 1 output
pub const TripleCraftingWorkstation = TaskWorkstation(3, 3, 1, 1);

// ============================================================================
// Multi-output Workstations
// ============================================================================

/// Sawmill: 1 log → 2 planks
/// - 1 EIS (log source)
/// - 1 IIS (log input)
/// - 2 IOS (plank outputs)
/// - 2 EOS (plank storage)
pub const SawmillWorkstation = TaskWorkstation(1, 1, 2, 2);

/// Butcher: 1 animal → meat + hide
/// - 1 EIS (animal source)
/// - 1 IIS (animal input)
/// - 2 IOS (meat, hide outputs)
/// - 2 EOS (meat, hide storage)
pub const ButcherWorkstation = TaskWorkstation(1, 1, 2, 2);

const std = @import("std");

test "OvenWorkstation layout" {
    const oven = OvenWorkstation{};
    try std.testing.expectEqual(1, OvenWorkstation.EIS_COUNT);
    try std.testing.expectEqual(2, OvenWorkstation.IIS_COUNT);
    try std.testing.expectEqual(1, OvenWorkstation.IOS_COUNT);
    try std.testing.expectEqual(1, OvenWorkstation.EOS_COUNT);
    try std.testing.expectEqual(false, oven.isProducer());
}

test "WellWorkstation is producer" {
    const well = WellWorkstation{};
    try std.testing.expectEqual(true, well.isProducer());
}

test "SawmillWorkstation multi-output" {
    try std.testing.expectEqual(2, SawmillWorkstation.IOS_COUNT);
    try std.testing.expectEqual(2, SawmillWorkstation.EOS_COUNT);
}
