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
/// Each storage entity holds this component to define its behavior.
pub const TaskStorage = struct {
    /// Priority for storage selection (higher = preferred)
    priority: Priority = .Normal,

    /// Current quantity of items (0 or 1 in single-item model)
    quantity: u8 = 0,

    /// Maximum capacity (default 1 for single-item model)
    capacity: u8 = 1,

    // === Methods ===

    /// Check if storage is empty
    pub fn isEmpty(self: *const TaskStorage) bool {
        return self.quantity == 0;
    }

    /// Check if storage is full
    pub fn isFull(self: *const TaskStorage) bool {
        return self.quantity >= self.capacity;
    }

    /// Check if storage can accept an item
    pub fn canAccept(self: *const TaskStorage) bool {
        return !self.isFull();
    }

    /// Check if storage can provide an item
    pub fn canProvide(self: *const TaskStorage) bool {
        return !self.isEmpty();
    }

    /// Add an item to storage, returns true if successful
    pub fn add(self: *TaskStorage) bool {
        if (self.isFull()) return false;
        self.quantity += 1;
        return true;
    }

    /// Remove an item from storage, returns true if successful
    pub fn remove(self: *TaskStorage) bool {
        if (self.isEmpty()) return false;
        self.quantity -= 1;
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
    const storage = TaskStorage{};

    try std.testing.expectEqual(Priority.Normal, storage.priority);
    try std.testing.expectEqual(0, storage.quantity);
    try std.testing.expectEqual(1, storage.capacity);
    try std.testing.expectEqual(true, storage.isEmpty());
    try std.testing.expectEqual(false, storage.isFull());
}

test "TaskStorage add/remove" {
    var storage = TaskStorage{};

    try std.testing.expectEqual(true, storage.canAccept());
    try std.testing.expectEqual(false, storage.canProvide());

    try std.testing.expectEqual(true, storage.add());
    try std.testing.expectEqual(1, storage.quantity);
    try std.testing.expectEqual(false, storage.canAccept());
    try std.testing.expectEqual(true, storage.canProvide());

    // Can't add when full
    try std.testing.expectEqual(false, storage.add());

    try std.testing.expectEqual(true, storage.remove());
    try std.testing.expectEqual(0, storage.quantity);

    // Can't remove when empty
    try std.testing.expectEqual(false, storage.remove());
}

test "TaskStorage higher capacity" {
    var storage = TaskStorage{ .capacity = 3 };

    try std.testing.expectEqual(true, storage.add());
    try std.testing.expectEqual(true, storage.add());
    try std.testing.expectEqual(true, storage.add());
    try std.testing.expectEqual(false, storage.add());
    try std.testing.expectEqual(3, storage.quantity);
}

test "TaskStorageRole" {
    const eis_role = TaskStorageRole{ .role = .eis };
    const iis_role = TaskStorageRole{ .role = .iis };

    try std.testing.expectEqual(StorageRole.eis, eis_role.role);
    try std.testing.expectEqual(StorageRole.iis, iis_role.role);
}
