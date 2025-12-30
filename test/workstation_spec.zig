const zspec = @import("zspec");
const expect = zspec.expect;
const tasks = @import("labelle_tasks");

pub const @"TaskWorkstation" = struct {
    pub const @"creation" = struct {
        test "stores EIS, IIS, IOS, EOS counts as comptime constants" {
            const Kitchen = tasks.TaskWorkstation(2, 3, 1, 1);

            try expect.equal(Kitchen.EIS_COUNT, 2);
            try expect.equal(Kitchen.IIS_COUNT, 3);
            try expect.equal(Kitchen.IOS_COUNT, 1);
            try expect.equal(Kitchen.EOS_COUNT, 1);
        }

        test "creates storage arrays of correct sizes" {
            const Kitchen = tasks.TaskWorkstation(2, 3, 1, 1);
            const kitchen = Kitchen{};

            try expect.equal(kitchen.eis.len, 2);
            try expect.equal(kitchen.iis.len, 3);
            try expect.equal(kitchen.ios.len, 1);
            try expect.equal(kitchen.eos.len, 1);
        }

        test "allows zero-sized storage arrays" {
            const Well = tasks.TaskWorkstation(0, 0, 1, 1);

            try expect.equal(Well.EIS_COUNT, 0);
            try expect.equal(Well.IIS_COUNT, 0);
        }
    };

    pub const @"isProducer" = struct {
        test "returns true when EIS and IIS are both zero" {
            const Well = tasks.TaskWorkstation(0, 0, 1, 1);
            const well = Well{};

            try expect.equal(well.isProducer(), true);
        }

        test "returns false when EIS is non-zero" {
            const Kitchen = tasks.TaskWorkstation(1, 0, 1, 1);
            const kitchen = Kitchen{};

            try expect.equal(kitchen.isProducer(), false);
        }

        test "returns false when IIS is non-zero" {
            const Mixer = tasks.TaskWorkstation(0, 2, 1, 1);
            const mixer = Mixer{};

            try expect.equal(mixer.isProducer(), false);
        }
    };

    pub const @"totalStorages" = struct {
        test "returns sum of all storage counts" {
            const Kitchen = tasks.TaskWorkstation(2, 3, 1, 2);
            const kitchen = Kitchen{};

            try expect.equal(kitchen.totalStorages(), 8);
        }

        test "returns correct count for producer" {
            const Well = tasks.TaskWorkstation(0, 0, 1, 1);
            const well = Well{};

            try expect.equal(well.totalStorages(), 2);
        }
    };

    pub const @"storage configuration" = struct {
        test "supports inline Position configuration" {
            const Kitchen = tasks.TaskWorkstation(1, 1, 1, 1);
            const kitchen = Kitchen{
                .eis = .{.{ .components = .{
                    .Position = .{ .x = -60, .y = 30 },
                } }},
                .iis = .{.{}},
                .ios = .{.{}},
                .eos = .{.{}},
            };

            try expect.equal(kitchen.eis[0].components.Position.x, -60);
            try expect.equal(kitchen.eis[0].components.Position.y, 30);
        }

        test "supports inline TaskStorage configuration" {
            const Kitchen = tasks.TaskWorkstation(1, 1, 1, 1);
            const kitchen = Kitchen{
                .eis = .{.{ .components = .{
                    .TaskStorage = .{ .priority = .High, .has_item = true },
                } }},
                .iis = .{.{}},
                .ios = .{.{}},
                .eos = .{.{}},
            };

            try expect.equal(kitchen.eis[0].components.TaskStorage.priority, .High);
            try expect.equal(kitchen.eis[0].components.TaskStorage.has_item, true);
        }
    };
};

pub const @"Entity" = struct {
    pub const @"invalid entity" = struct {
        test "has maximum u64 id" {
            const inv = tasks.Entity.invalid;
            try expect.equal(inv.id, @import("std").math.maxInt(u64));
        }

        test "isValid returns false for invalid entity" {
            const inv = tasks.Entity.invalid;
            try expect.equal(inv.isValid(), false);
        }
    };

    pub const @"valid entities" = struct {
        test "isValid returns true for normal entities" {
            const entity = tasks.Entity{ .id = 42 };
            try expect.equal(entity.isValid(), true);
        }

        test "eql compares entity ids" {
            const a = tasks.Entity{ .id = 1 };
            const b = tasks.Entity{ .id = 1 };
            const c = tasks.Entity{ .id = 2 };

            try expect.equal(a.eql(b), true);
            try expect.equal(a.eql(c), false);
        }
    };
};

pub const @"Priority" = struct {
    test "has four levels" {
        const priorities = [_]tasks.Priority{ .Low, .Normal, .High, .Critical };
        try expect.equal(priorities.len, 4);
    }

    test "toInt returns increasing values" {
        try expect.equal(tasks.Priority.Low.toInt(), 0);
        try expect.equal(tasks.Priority.Normal.toInt(), 1);
        try expect.equal(tasks.Priority.High.toInt(), 2);
        try expect.equal(tasks.Priority.Critical.toInt(), 3);
    }
};

pub const @"WorkstationStatus" = struct {
    test "has three states" {
        const statuses = [_]tasks.WorkstationStatus{ .Blocked, .Queued, .Active };
        try expect.equal(statuses.len, 3);
    }
};

pub const @"StepType" = struct {
    test "has three steps" {
        const steps = [_]tasks.StepType{ .Pickup, .Process, .Store };
        try expect.equal(steps.len, 3);
    }
};
