const zspec = @import("zspec");
const expect = zspec.expect;
const tasks = @import("labelle_tasks");

pub const @"TaskWorkstationBinding" = struct {
    pub const @"defaults" = struct {
        test "process_duration defaults to 0" {
            const binding = tasks.TaskWorkstationBinding{};
            try expect.equal(binding.process_duration, 0);
        }

        test "priority defaults to Normal" {
            const binding = tasks.TaskWorkstationBinding{};
            try expect.equal(binding.priority, .Normal);
        }

        test "status defaults to Blocked" {
            const binding = tasks.TaskWorkstationBinding{};
            try expect.equal(binding.status, .Blocked);
        }

        test "assigned_worker defaults to null" {
            const binding = tasks.TaskWorkstationBinding{};
            try expect.toBeNull(binding.assigned_worker);
        }

        test "current_step defaults to Pickup" {
            const binding = tasks.TaskWorkstationBinding{};
            try expect.equal(binding.current_step, .Pickup);
        }

        test "cycles_completed defaults to 0" {
            const binding = tasks.TaskWorkstationBinding{};
            try expect.equal(binding.cycles_completed, 0);
        }
    };

    pub const @"canAcceptWorker" = struct {
        test "returns true when Queued and no worker" {
            const binding = tasks.TaskWorkstationBinding{ .status = .Queued };
            try expect.equal(binding.canAcceptWorker(), true);
        }

        test "returns false when Blocked" {
            const binding = tasks.TaskWorkstationBinding{ .status = .Blocked };
            try expect.equal(binding.canAcceptWorker(), false);
        }

        test "returns false when Active" {
            const binding = tasks.TaskWorkstationBinding{ .status = .Active };
            try expect.equal(binding.canAcceptWorker(), false);
        }

        test "returns false when worker already assigned" {
            const binding = tasks.TaskWorkstationBinding{
                .status = .Queued,
                .assigned_worker = tasks.Entity{ .id = 1 },
            };
            try expect.equal(binding.canAcceptWorker(), false);
        }
    };

    pub const @"assignWorker" = struct {
        test "sets assigned_worker" {
            var binding = tasks.TaskWorkstationBinding{ .status = .Queued };
            const worker = tasks.Entity{ .id = 42 };

            binding.assignWorker(worker);

            try expect.equal(binding.assigned_worker.?.id, 42);
        }

        test "sets status to Active" {
            var binding = tasks.TaskWorkstationBinding{ .status = .Queued };
            const worker = tasks.Entity{ .id = 42 };

            binding.assignWorker(worker);

            try expect.equal(binding.status, .Active);
        }
    };

    pub const @"releaseWorker" = struct {
        test "returns the assigned worker" {
            var binding = tasks.TaskWorkstationBinding{
                .assigned_worker = tasks.Entity{ .id = 42 },
            };

            const released = binding.releaseWorker();

            try expect.equal(released.?.id, 42);
        }

        test "clears assigned_worker" {
            var binding = tasks.TaskWorkstationBinding{
                .assigned_worker = tasks.Entity{ .id = 42 },
            };

            _ = binding.releaseWorker();

            try expect.toBeNull(binding.assigned_worker);
        }

        test "sets status to Blocked" {
            var binding = tasks.TaskWorkstationBinding{
                .status = .Active,
                .assigned_worker = tasks.Entity{ .id = 42 },
            };

            _ = binding.releaseWorker();

            try expect.equal(binding.status, .Blocked);
        }

        test "returns null when no worker assigned" {
            var binding = tasks.TaskWorkstationBinding{};

            const released = binding.releaseWorker();

            try expect.toBeNull(released);
        }
    };

    pub const @"advanceStep" = struct {
        test "advances from Pickup to Process" {
            var binding = tasks.TaskWorkstationBinding{ .current_step = .Pickup };

            binding.advanceStep();

            try expect.equal(binding.current_step, .Process);
        }

        test "advances from Process to Store" {
            var binding = tasks.TaskWorkstationBinding{ .current_step = .Process };

            binding.advanceStep();

            try expect.equal(binding.current_step, .Store);
        }

        test "advances from Store to Pickup" {
            var binding = tasks.TaskWorkstationBinding{ .current_step = .Store };

            binding.advanceStep();

            try expect.equal(binding.current_step, .Pickup);
        }

        test "increments cycles_completed when completing Store" {
            var binding = tasks.TaskWorkstationBinding{ .current_step = .Store };

            binding.advanceStep();

            try expect.equal(binding.cycles_completed, 1);
        }

        test "does not increment cycles_completed for other steps" {
            var binding = tasks.TaskWorkstationBinding{ .current_step = .Pickup };

            binding.advanceStep();

            try expect.equal(binding.cycles_completed, 0);
        }
    };

    pub const @"tickProcess" = struct {
        test "returns false when not in Process step" {
            var binding = tasks.TaskWorkstationBinding{
                .current_step = .Pickup,
                .process_duration = 1,
            };

            try expect.equal(binding.tickProcess(), false);
        }

        test "increments process_timer" {
            var binding = tasks.TaskWorkstationBinding{
                .current_step = .Process,
                .process_duration = 5,
            };

            _ = binding.tickProcess();

            try expect.equal(binding.process_timer, 1);
        }

        test "returns false when timer not reached duration" {
            var binding = tasks.TaskWorkstationBinding{
                .current_step = .Process,
                .process_duration = 3,
            };

            try expect.equal(binding.tickProcess(), false);
            try expect.equal(binding.tickProcess(), false);
        }

        test "returns true when timer reaches duration" {
            var binding = tasks.TaskWorkstationBinding{
                .current_step = .Process,
                .process_duration = 3,
            };

            _ = binding.tickProcess();
            _ = binding.tickProcess();
            try expect.equal(binding.tickProcess(), true);
        }

        test "resets timer when duration reached" {
            var binding = tasks.TaskWorkstationBinding{
                .current_step = .Process,
                .process_duration = 2,
            };

            _ = binding.tickProcess();
            _ = binding.tickProcess();

            try expect.equal(binding.process_timer, 0);
        }
    };

    pub const @"resetCycle" = struct {
        test "resets process_timer to 0" {
            var binding = tasks.TaskWorkstationBinding{ .process_timer = 5 };

            binding.resetCycle();

            try expect.equal(binding.process_timer, 0);
        }

        test "resets current_step to Pickup" {
            var binding = tasks.TaskWorkstationBinding{ .current_step = .Store };

            binding.resetCycle();

            try expect.equal(binding.current_step, .Pickup);
        }

        test "clears selected_eis" {
            var binding = tasks.TaskWorkstationBinding{
                .selected_eis = tasks.Entity{ .id = 1 },
            };

            binding.resetCycle();

            try expect.toBeNull(binding.selected_eis);
        }

        test "clears selected_eos" {
            var binding = tasks.TaskWorkstationBinding{
                .selected_eos = tasks.Entity{ .id = 1 },
            };

            binding.resetCycle();

            try expect.toBeNull(binding.selected_eos);
        }
    };
};
