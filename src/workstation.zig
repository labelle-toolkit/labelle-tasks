const std = @import("std");
const storage = @import("storage.zig");

/// Entity type - matches labelle-engine's Entity
pub const Entity = struct {
    id: u64,

    pub const invalid = Entity{ .id = std.math.maxInt(u64) };

    pub fn isValid(self: Entity) bool {
        return self.id != invalid.id;
    }

    pub fn eql(self: Entity, other: Entity) bool {
        return self.id == other.id;
    }
};

/// Priority levels for workstations and storages
pub const Priority = enum {
    Low,
    Normal,
    High,
    Critical,

    pub fn toInt(self: Priority) u8 {
        return switch (self) {
            .Low => 0,
            .Normal => 1,
            .High => 2,
            .Critical => 3,
        };
    }
};

/// Workstation status in the task pipeline
pub const WorkstationStatus = enum {
    /// Waiting for resources (IIS not full, or EOS full)
    Blocked,
    /// Ready to work, waiting for worker assignment
    Queued,
    /// Worker assigned and working
    Active,
};

/// Current step in the workstation cycle
pub const StepType = enum {
    /// Moving items from EIS to IIS
    Pickup,
    /// Processing items (timer running)
    Process,
    /// Moving items from IOS to EOS
    Store,
};

/// Position component for storage entities
pub const StoragePosition = struct {
    x: f32 = 0,
    y: f32 = 0,
};

/// Components that can be defined on a storage slot
pub const StorageComponents = struct {
    Position: StoragePosition = .{},
    TaskStorage: storage.TaskStorage = .{},
};

/// Storage slot with inline component definitions
pub const StorageSlot = struct {
    components: StorageComponents = .{},
};

/// Generic comptime-sized workstation type.
/// Storage configurations are defined in prefabs, entities created at load time.
pub fn TaskWorkstation(
    comptime eis_count: usize,
    comptime iis_count: usize,
    comptime ios_count: usize,
    comptime eos_count: usize,
) type {
    return struct {
        const Self = @This();

        pub const EIS_COUNT = eis_count;
        pub const IIS_COUNT = iis_count;
        pub const IOS_COUNT = ios_count;
        pub const EOS_COUNT = eos_count;

        /// External Input Storage configurations
        eis: [eis_count]StorageSlot = [_]StorageSlot{.{}} ** eis_count,
        /// Internal Input Storage configurations
        iis: [iis_count]StorageSlot = [_]StorageSlot{.{}} ** iis_count,
        /// Internal Output Storage configurations
        ios: [ios_count]StorageSlot = [_]StorageSlot{.{}} ** ios_count,
        /// External Output Storage configurations
        eos: [eos_count]StorageSlot = [_]StorageSlot{.{}} ** eos_count,

        /// Check if this is a producer workstation (no inputs)
        pub fn isProducer(self: *const Self) bool {
            _ = self;
            return eis_count == 0 and iis_count == 0;
        }

        /// Get total number of storages
        pub fn totalStorages(self: *const Self) usize {
            _ = self;
            return eis_count + iis_count + ios_count + eos_count;
        }
    };
}

/// Common interface for working with any workstation type
pub fn WorkstationInterface(comptime T: type) type {
    return struct {
        pub fn getEis(ws: *const T) []const StorageSlot {
            return &ws.eis;
        }

        pub fn getIis(ws: *const T) []const StorageSlot {
            return &ws.iis;
        }

        pub fn getIos(ws: *const T) []const StorageSlot {
            return &ws.ios;
        }

        pub fn getEos(ws: *const T) []const StorageSlot {
            return &ws.eos;
        }

        pub fn isProducer(_: *const T) bool {
            return T.EIS_COUNT == 0 and T.IIS_COUNT == 0;
        }

        pub fn totalStorages(ws: *const T) usize {
            _ = ws;
            return T.EIS_COUNT + T.IIS_COUNT + T.IOS_COUNT + T.EOS_COUNT;
        }
    };
}

test "TaskWorkstation basic creation" {
    const Kitchen = TaskWorkstation(2, 2, 1, 1);
    const kitchen = Kitchen{};

    try std.testing.expectEqual(2, Kitchen.EIS_COUNT);
    try std.testing.expectEqual(2, Kitchen.IIS_COUNT);
    try std.testing.expectEqual(1, Kitchen.IOS_COUNT);
    try std.testing.expectEqual(1, Kitchen.EOS_COUNT);
    try std.testing.expectEqual(false, kitchen.isProducer());
    try std.testing.expectEqual(6, kitchen.totalStorages());
}

test "TaskWorkstation producer type" {
    const Well = TaskWorkstation(0, 0, 1, 1);
    const well = Well{};

    try std.testing.expectEqual(true, well.isProducer());
    try std.testing.expectEqual(2, well.totalStorages());
}

test "TaskWorkstation storage configuration" {
    const Kitchen = TaskWorkstation(1, 1, 1, 1);
    const kitchen = Kitchen{
        .eis = .{.{ .components = .{
            .Position = .{ .x = -60, .y = 0 },
            .TaskStorage = .{ .priority = .High },
        } }},
        .iis = .{.{}},
        .ios = .{.{}},
        .eos = .{.{ .components = .{
            .Position = .{ .x = 60, .y = 0 },
            .TaskStorage = .{ .has_item = true },
        } }},
    };

    try std.testing.expectEqual(.High, kitchen.eis[0].components.TaskStorage.priority);
    try std.testing.expectEqual(-60, kitchen.eis[0].components.Position.x);
    try std.testing.expectEqual(true, kitchen.eos[0].components.TaskStorage.has_item);
}
