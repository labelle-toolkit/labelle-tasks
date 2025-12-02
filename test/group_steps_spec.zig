const zspec = @import("zspec");
const expect = zspec.expect;
const tasks = @import("labelle_tasks");

pub const @"GroupSteps" = struct {
    const GS = tasks.GroupSteps;
    const StepDef = tasks.StepDef;
    const StepType = tasks.StepType;

    const kitchen_steps = [_]StepDef{
        .{ .type = .Pickup },
        .{ .type = .Cook },
        .{ .type = .Store },
    };

    pub const @"init" = struct {
        test "starts at index 0" {
            const steps = GS.init(&kitchen_steps);
            try expect.equal(steps.current_index, 0);
        }

        test "stores the provided steps" {
            const steps = GS.init(&kitchen_steps);
            try expect.equal(steps.steps.len, 3);
        }
    };

    pub const @"currentStep" = struct {
        test "returns the first step initially" {
            const steps = GS.init(&kitchen_steps);
            const current = steps.currentStep();
            try expect.equal(current != null, true);
            try expect.equal(current.?.type, StepType.Pickup);
        }

        test "returns null when past the end" {
            var steps = GS.init(&kitchen_steps);
            _ = steps.advance(); // to Cook
            _ = steps.advance(); // to Store
            steps.current_index = 3; // past end
            const current = steps.currentStep();
            try expect.equal(current == null, true);
        }
    };

    pub const @"advance" = struct {
        test "moves to the next step" {
            var steps = GS.init(&kitchen_steps);
            const advanced = steps.advance();
            try expect.equal(advanced, true);
            try expect.equal(steps.current_index, 1);
        }

        test "returns the Cook step after first advance" {
            var steps = GS.init(&kitchen_steps);
            _ = steps.advance();
            const current = steps.currentStep();
            try expect.equal(current.?.type, StepType.Cook);
        }

        test "returns the Store step after second advance" {
            var steps = GS.init(&kitchen_steps);
            _ = steps.advance();
            _ = steps.advance();
            const current = steps.currentStep();
            try expect.equal(current.?.type, StepType.Store);
        }

        test "advances past last step to indicate completion" {
            var steps = GS.init(&kitchen_steps);
            _ = steps.advance(); // to Cook
            _ = steps.advance(); // to Store
            const advanced = steps.advance(); // advance past Store to complete
            try expect.equal(advanced, true);
            try expect.equal(steps.current_index, 3);
        }

        test "returns false when already past the end" {
            var steps = GS.init(&kitchen_steps);
            _ = steps.advance(); // to Cook
            _ = steps.advance(); // to Store
            _ = steps.advance(); // past Store (complete)
            const advanced = steps.advance(); // cannot advance further
            try expect.equal(advanced, false);
            try expect.equal(steps.current_index, 3);
        }
    };

    pub const @"reset" = struct {
        test "sets index back to 0" {
            var steps = GS.init(&kitchen_steps);
            _ = steps.advance();
            _ = steps.advance();
            steps.reset();
            try expect.equal(steps.current_index, 0);
        }

        test "returns to the first step" {
            var steps = GS.init(&kitchen_steps);
            _ = steps.advance();
            _ = steps.advance();
            steps.reset();
            const current = steps.currentStep();
            try expect.equal(current.?.type, StepType.Pickup);
        }
    };

    pub const @"isComplete" = struct {
        test "returns false initially" {
            const steps = GS.init(&kitchen_steps);
            try expect.equal(steps.isComplete(), false);
        }

        test "returns false during execution" {
            var steps = GS.init(&kitchen_steps);
            _ = steps.advance();
            try expect.equal(steps.isComplete(), false);
        }

        test "returns true when index equals steps length" {
            var steps = GS.init(&kitchen_steps);
            steps.current_index = 3;
            try expect.equal(steps.isComplete(), true);
        }
    };
};
