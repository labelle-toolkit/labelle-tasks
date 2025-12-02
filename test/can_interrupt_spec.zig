const zspec = @import("zspec");
const expect = zspec.expect;
const tasks = @import("labelle_tasks");

pub const @"canInterrupt" = struct {
    const ci = tasks.canInterrupt;

    pub const @"with None interrupt level" = struct {
        test "can be interrupted by Low priority" {
            try expect.equal(ci(.None, .Low), true);
        }

        test "can be interrupted by Normal priority" {
            try expect.equal(ci(.None, .Normal), true);
        }

        test "can be interrupted by High priority" {
            try expect.equal(ci(.None, .High), true);
        }

        test "can be interrupted by Critical priority" {
            try expect.equal(ci(.None, .Critical), true);
        }
    };

    pub const @"with Low interrupt level" = struct {
        test "cannot be interrupted by Low priority" {
            try expect.equal(ci(.Low, .Low), false);
        }

        test "cannot be interrupted by Normal priority" {
            try expect.equal(ci(.Low, .Normal), false);
        }

        test "can be interrupted by High priority" {
            try expect.equal(ci(.Low, .High), true);
        }

        test "can be interrupted by Critical priority" {
            try expect.equal(ci(.Low, .Critical), true);
        }
    };

    pub const @"with High interrupt level" = struct {
        test "cannot be interrupted by Low priority" {
            try expect.equal(ci(.High, .Low), false);
        }

        test "cannot be interrupted by Normal priority" {
            try expect.equal(ci(.High, .Normal), false);
        }

        test "cannot be interrupted by High priority" {
            try expect.equal(ci(.High, .High), false);
        }

        test "can be interrupted by Critical priority" {
            try expect.equal(ci(.High, .Critical), true);
        }
    };

    pub const @"with Atomic interrupt level" = struct {
        test "cannot be interrupted by Low priority" {
            try expect.equal(ci(.Atomic, .Low), false);
        }

        test "cannot be interrupted by Normal priority" {
            try expect.equal(ci(.Atomic, .Normal), false);
        }

        test "cannot be interrupted by High priority" {
            try expect.equal(ci(.Atomic, .High), false);
        }

        test "cannot be interrupted by Critical priority" {
            try expect.equal(ci(.Atomic, .Critical), false);
        }
    };
};
