const workstation = @import("workstation.zig");

pub const Priority = workstation.Priority;

/// Storage role in the workstation workflow
pub const StorageRole = enum {
    /// External Input Storage - source of raw materials
    eis,
    /// Internal Input Storage - recipe inputs
    iis,
    /// Internal Output Storage - recipe outputs
    ios,
    /// External Output Storage - finished products
    eos,
};

/// Storage component for items in the task system.
/// Each storage entity holds exactly one item (single-item model).
pub const TaskStorage = struct {
    /// Priority for storage selection (higher = preferred)
    priority: Priority = .Normal,

    /// Whether the storage contains an item
    has_item: bool = false,

    // === Methods ===

    /// Check if storage is empty
    pub fn isEmpty(self: *const TaskStorage) bool {
        return !self.has_item;
    }

    /// Check if storage is full
    pub fn isFull(self: *const TaskStorage) bool {
        return self.has_item;
    }

    /// Check if storage can accept an item
    pub fn canAccept(self: *const TaskStorage) bool {
        return !self.has_item;
    }

    /// Check if storage can provide an item
    pub fn canProvide(self: *const TaskStorage) bool {
        return self.has_item;
    }

    /// Add an item to storage, returns true if successful
    pub fn add(self: *TaskStorage) bool {
        if (self.has_item) return false;
        self.has_item = true;
        return true;
    }

    /// Remove an item from storage, returns true if successful
    pub fn remove(self: *TaskStorage) bool {
        if (!self.has_item) return false;
        self.has_item = false;
        return true;
    }
};

/// Component to mark which role a storage plays in its parent workstation.
/// Added alongside TaskStorage when storage is part of a workstation.
pub const TaskStorageRole = struct {
    role: StorageRole,
};

const std = @import("std");

test "TaskStorage defaults" {
    const s = TaskStorage{};

    try std.testing.expectEqual(Priority.Normal, s.priority);
    try std.testing.expectEqual(false, s.has_item);
    try std.testing.expectEqual(true, s.isEmpty());
    try std.testing.expectEqual(false, s.isFull());
}

test "TaskStorage add/remove" {
    var s = TaskStorage{};

    try std.testing.expectEqual(true, s.canAccept());
    try std.testing.expectEqual(false, s.canProvide());

    try std.testing.expectEqual(true, s.add());
    try std.testing.expectEqual(true, s.has_item);
    try std.testing.expectEqual(false, s.canAccept());
    try std.testing.expectEqual(true, s.canProvide());

    // Can't add when full
    try std.testing.expectEqual(false, s.add());

    try std.testing.expectEqual(true, s.remove());
    try std.testing.expectEqual(false, s.has_item);

    // Can't remove when empty
    try std.testing.expectEqual(false, s.remove());
}

test "TaskStorageRole" {
    const eis_role = TaskStorageRole{ .role = .eis };
    const iis_role = TaskStorageRole{ .role = .iis };

    try std.testing.expectEqual(StorageRole.eis, eis_role.role);
    try std.testing.expectEqual(StorageRole.iis, iis_role.role);
}
