const zspec = @import("zspec");
const expect = zspec.expect;
const tasks = @import("labelle_tasks");

pub const @"TaskStorage" = struct {
    pub const @"defaults" = struct {
        test "priority defaults to Normal" {
            const storage = tasks.TaskStorage{};
            try expect.equal(storage.priority, .Normal);
        }

        test "has_item defaults to false" {
            const storage = tasks.TaskStorage{};
            try expect.equal(storage.has_item, false);
        }

        test "isEmpty returns true for new storage" {
            const storage = tasks.TaskStorage{};
            try expect.equal(storage.isEmpty(), true);
        }

        test "isFull returns false for new storage" {
            const storage = tasks.TaskStorage{};
            try expect.equal(storage.isFull(), false);
        }
    };

    pub const @"canAccept" = struct {
        test "returns true when empty" {
            const storage = tasks.TaskStorage{};
            try expect.equal(storage.canAccept(), true);
        }

        test "returns false when has item" {
            const storage = tasks.TaskStorage{ .has_item = true };
            try expect.equal(storage.canAccept(), false);
        }
    };

    pub const @"canProvide" = struct {
        test "returns false when empty" {
            const storage = tasks.TaskStorage{};
            try expect.equal(storage.canProvide(), false);
        }

        test "returns true when has item" {
            const storage = tasks.TaskStorage{ .has_item = true };
            try expect.equal(storage.canProvide(), true);
        }
    };

    pub const @"add" = struct {
        test "sets has_item to true" {
            var storage = tasks.TaskStorage{};
            _ = storage.add();
            try expect.equal(storage.has_item, true);
        }

        test "returns true on success" {
            var storage = tasks.TaskStorage{};
            try expect.equal(storage.add(), true);
        }

        test "returns false when already full" {
            var storage = tasks.TaskStorage{ .has_item = true };
            try expect.equal(storage.add(), false);
        }

        test "does not modify state when full" {
            var storage = tasks.TaskStorage{ .has_item = true };
            _ = storage.add();
            try expect.equal(storage.has_item, true);
        }
    };

    pub const @"remove" = struct {
        test "sets has_item to false" {
            var storage = tasks.TaskStorage{ .has_item = true };
            _ = storage.remove();
            try expect.equal(storage.has_item, false);
        }

        test "returns true on success" {
            var storage = tasks.TaskStorage{ .has_item = true };
            try expect.equal(storage.remove(), true);
        }

        test "returns false when already empty" {
            var storage = tasks.TaskStorage{};
            try expect.equal(storage.remove(), false);
        }

        test "does not modify state when empty" {
            var storage = tasks.TaskStorage{};
            _ = storage.remove();
            try expect.equal(storage.has_item, false);
        }
    };
};

pub const @"TaskStorageRole" = struct {
    test "can be set to eis" {
        const role = tasks.TaskStorageRole{ .role = .eis };
        try expect.equal(role.role, .eis);
    }

    test "can be set to iis" {
        const role = tasks.TaskStorageRole{ .role = .iis };
        try expect.equal(role.role, .iis);
    }

    test "can be set to ios" {
        const role = tasks.TaskStorageRole{ .role = .ios };
        try expect.equal(role.role, .ios);
    }

    test "can be set to eos" {
        const role = tasks.TaskStorageRole{ .role = .eos };
        try expect.equal(role.role, .eos);
    }
};

pub const @"StorageRole" = struct {
    test "has four roles" {
        const roles = [_]tasks.StorageRole{ .eis, .iis, .ios, .eos };
        try expect.equal(roles.len, 4);
    }
};
