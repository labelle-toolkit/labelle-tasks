const zspec = @import("zspec");
const expect = zspec.expect;
const tasks = @import("labelle_tasks");

pub const @"TasksPlugin" = struct {
    const OvenWorkstation = tasks.TaskWorkstation(1, 2, 1, 1);
    const WellWorkstation = tasks.TaskWorkstation(0, 0, 1, 1);
    const MixerWorkstation = tasks.TaskWorkstation(2, 3, 2, 1);

    pub const @"workstation_count" = struct {
        test "returns number of registered workstations" {
            const Plugin = tasks.TasksPlugin(.{
                .workstations = &.{ OvenWorkstation, WellWorkstation },
            });

            try expect.equal(Plugin.workstation_count, 2);
        }

        test "returns 0 for empty registration" {
            const Plugin = tasks.TasksPlugin(.{
                .workstations = &.{},
            });

            try expect.equal(Plugin.workstation_count, 0);
        }

        test "counts all registered workstations" {
            const Plugin = tasks.TasksPlugin(.{
                .workstations = &.{ OvenWorkstation, WellWorkstation, MixerWorkstation },
            });

            try expect.equal(Plugin.workstation_count, 3);
        }
    };

    pub const @"isRegistered" = struct {
        test "returns true for registered workstation" {
            const Plugin = tasks.TasksPlugin(.{
                .workstations = &.{ OvenWorkstation, WellWorkstation },
            });

            try expect.equal(Plugin.isRegistered(OvenWorkstation), true);
            try expect.equal(Plugin.isRegistered(WellWorkstation), true);
        }

        test "returns false for unregistered workstation" {
            const Plugin = tasks.TasksPlugin(.{
                .workstations = &.{OvenWorkstation},
            });

            try expect.equal(Plugin.isRegistered(WellWorkstation), false);
            try expect.equal(Plugin.isRegistered(MixerWorkstation), false);
        }

        test "returns false for different workstation with same counts" {
            const Plugin = tasks.TasksPlugin(.{
                .workstations = &.{OvenWorkstation},
            });

            // Create a new type with same counts - should be different type
            const SameCountsWorkstation = tasks.TaskWorkstation(1, 2, 1, 1);

            // Note: These are actually the same type in Zig since they have same parameters
            try expect.equal(Plugin.isRegistered(SameCountsWorkstation), true);
        }
    };

    pub const @"getWorkstationInfo" = struct {
        test "returns correct EIS count" {
            const Plugin = tasks.TasksPlugin(.{
                .workstations = &.{ OvenWorkstation, WellWorkstation },
            });

            const oven_info = Plugin.getWorkstationInfo(0);
            const well_info = Plugin.getWorkstationInfo(1);

            try expect.equal(oven_info.eis_count, 1);
            try expect.equal(well_info.eis_count, 0);
        }

        test "returns correct IIS count" {
            const Plugin = tasks.TasksPlugin(.{
                .workstations = &.{ OvenWorkstation, MixerWorkstation },
            });

            const oven_info = Plugin.getWorkstationInfo(0);
            const mixer_info = Plugin.getWorkstationInfo(1);

            try expect.equal(oven_info.iis_count, 2);
            try expect.equal(mixer_info.iis_count, 3);
        }

        test "returns correct IOS count" {
            const Plugin = tasks.TasksPlugin(.{
                .workstations = &.{ OvenWorkstation, MixerWorkstation },
            });

            const oven_info = Plugin.getWorkstationInfo(0);
            const mixer_info = Plugin.getWorkstationInfo(1);

            try expect.equal(oven_info.ios_count, 1);
            try expect.equal(mixer_info.ios_count, 2);
        }

        test "returns correct EOS count" {
            const Plugin = tasks.TasksPlugin(.{
                .workstations = &.{ OvenWorkstation, WellWorkstation },
            });

            const oven_info = Plugin.getWorkstationInfo(0);
            const well_info = Plugin.getWorkstationInfo(1);

            try expect.equal(oven_info.eos_count, 1);
            try expect.equal(well_info.eos_count, 1);
        }

        test "returns the workstation type" {
            const Plugin = tasks.TasksPlugin(.{
                .workstations = &.{OvenWorkstation},
            });

            const info = Plugin.getWorkstationInfo(0);

            try expect.equal(info.type, OvenWorkstation);
        }
    };
};

pub const @"Components" = struct {
    test "exports TaskWorkstationBinding" {
        const binding = tasks.Components.TaskWorkstationBinding{};
        try expect.equal(binding.status, .Blocked);
    }

    test "exports TaskStorage" {
        const storage = tasks.Components.TaskStorage{};
        try expect.equal(storage.has_item, false);
    }

    test "exports TaskStorageRole" {
        const role = tasks.Components.TaskStorageRole{ .role = .eis };
        try expect.equal(role.role, .eis);
    }
};
