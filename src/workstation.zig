const std = @import("std");

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

/// Generic comptime-sized workstation type.
/// Storage references are filled by the loader when creating the entity.
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

        /// External Input Storage entities
        eis: [eis_count]Entity = [_]Entity{Entity.invalid} ** eis_count,
        /// Internal Input Storage entities (recipe inputs)
        iis: [iis_count]Entity = [_]Entity{Entity.invalid} ** iis_count,
        /// Internal Output Storage entities (recipe outputs)
        ios: [ios_count]Entity = [_]Entity{Entity.invalid} ** ios_count,
        /// External Output Storage entities
        eos: [eos_count]Entity = [_]Entity{Entity.invalid} ** eos_count,

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

        /// Check if all storage references are valid
        pub fn isFullyBound(self: *const Self) bool {
            for (self.eis) |e| if (!e.isValid()) return false;
            for (self.iis) |e| if (!e.isValid()) return false;
            for (self.ios) |e| if (!e.isValid()) return false;
            for (self.eos) |e| if (!e.isValid()) return false;
            return true;
        }
    };
}

/// Common interface for working with any workstation type
pub fn WorkstationInterface(comptime T: type) type {
    return struct {
        pub fn getEis(ws: *const T) []const Entity {
            return &ws.eis;
        }

        pub fn getIis(ws: *const T) []const Entity {
            return &ws.iis;
        }

        pub fn getIos(ws: *const T) []const Entity {
            return &ws.ios;
        }

        pub fn getEos(ws: *const T) []const Entity {
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
    var kitchen = Kitchen{};

    try std.testing.expectEqual(2, Kitchen.EIS_COUNT);
    try std.testing.expectEqual(2, Kitchen.IIS_COUNT);
    try std.testing.expectEqual(1, Kitchen.IOS_COUNT);
    try std.testing.expectEqual(1, Kitchen.EOS_COUNT);
    try std.testing.expectEqual(false, kitchen.isProducer());
    try std.testing.expectEqual(6, kitchen.totalStorages());
}

test "TaskWorkstation producer type" {
    const Well = TaskWorkstation(0, 0, 1, 1);
    var well = Well{};

    try std.testing.expectEqual(true, well.isProducer());
    try std.testing.expectEqual(2, well.totalStorages());
}

test "TaskWorkstation storage binding" {
    const Kitchen = TaskWorkstation(1, 1, 1, 1);
    var kitchen = Kitchen{};

    try std.testing.expectEqual(false, kitchen.isFullyBound());

    kitchen.eis[0] = Entity{ .id = 1 };
    kitchen.iis[0] = Entity{ .id = 2 };
    kitchen.ios[0] = Entity{ .id = 3 };
    kitchen.eos[0] = Entity{ .id = 4 };

    try std.testing.expectEqual(true, kitchen.isFullyBound());
}
