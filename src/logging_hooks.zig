//! Default logging hooks for task engine events.
//!
//! Games can use LoggingHooks directly for debugging, or compose with custom hooks
//! using MergeHooks to only override specific behaviors.
//!
//! Usage:
//! ```zig
//! // Use logging hooks directly
//! const Context = tasks.TaskEngineContext(u64, Item, tasks.LoggingHooks);
//!
//! // Or merge with custom hooks (custom takes precedence)
//! const MyHooks = struct {
//!     pub fn store_started(payload: anytype) void {
//!         // Custom behavior - this overrides LoggingHooks.store_started
//!     }
//! };
//! const Hooks = tasks.MergeHooks(MyHooks, tasks.LoggingHooks);
//! const Context = tasks.TaskEngineContext(u64, Item, Hooks);
//! ```

const std = @import("std");

/// Default logging implementation for all task engine hooks.
pub const LoggingHooks = struct {
    pub fn process_completed(payload: anytype) void {
        std.log.info("[TaskEngine] process_completed: workstation={d}, worker={d}", .{
            payload.workstation_id,
            payload.worker_id,
        });
    }

    pub fn cycle_completed(payload: anytype) void {
        std.log.info("[TaskEngine] cycle_completed: workstation={d}, cycles={d}", .{
            payload.workstation_id,
            payload.cycles_completed,
        });
    }

    pub fn pickup_started(payload: anytype) void {
        std.log.info("[TaskEngine] pickup_started: worker={d}, storage={d}", .{
            payload.worker_id,
            payload.storage_id,
        });
    }

    pub fn store_started(payload: anytype) void {
        std.log.info("[TaskEngine] store_started: worker={d}, storage={d}", .{
            payload.worker_id,
            payload.storage_id,
        });
    }

    pub fn worker_assigned(payload: anytype) void {
        std.log.info("[TaskEngine] worker_assigned: worker={d}, workstation={d}", .{
            payload.worker_id,
            payload.workstation_id,
        });
    }

    pub fn worker_released(payload: anytype) void {
        std.log.info("[TaskEngine] worker_released: worker={d}", .{
            payload.worker_id,
        });
    }

    pub fn workstation_queued(payload: anytype) void {
        std.log.info("[TaskEngine] workstation_queued: workstation={d}", .{
            payload.workstation_id,
        });
    }

    pub fn workstation_blocked(payload: anytype) void {
        std.log.info("[TaskEngine] workstation_blocked: workstation={d}", .{
            payload.workstation_id,
        });
    }

    pub fn workstation_activated(payload: anytype) void {
        std.log.info("[TaskEngine] workstation_activated: workstation={d}", .{
            payload.workstation_id,
        });
    }

    pub fn pickup_dangling_started(payload: anytype) void {
        std.log.info("[TaskEngine] pickup_dangling_started: worker={d}, item={d}, item_type={}, target_eis={d}", .{
            payload.worker_id,
            payload.item_id,
            payload.item_type,
            payload.target_eis_id,
        });
    }

    pub fn item_delivered(payload: anytype) void {
        std.log.info("[TaskEngine] item_delivered: worker={d}, item={d}, storage={d}", .{
            payload.worker_id,
            payload.item_id,
            payload.storage_id,
        });
    }
};

/// Merges two hook structs, with Primary taking precedence over Fallback.
/// If Primary has a hook, it's used; otherwise Fallback's hook is used.
pub fn MergeHooks(comptime Primary: type, comptime Fallback: type) type {
    return struct {
        const hook_names = [_][]const u8{
            "process_completed",
            "cycle_completed",
            "pickup_started",
            "store_started",
            "worker_assigned",
            "worker_released",
            "workstation_queued",
            "workstation_blocked",
            "workstation_activated",
            "pickup_dangling_started",
            "item_delivered",
        };

        inline fn getHook(comptime name: []const u8) ?*const fn (anytype) void {
            if (@hasDecl(Primary, name)) {
                return &@field(Primary, name);
            } else if (@hasDecl(Fallback, name)) {
                return &@field(Fallback, name);
            }
            return null;
        }

        pub fn process_completed(payload: anytype) void {
            if (@hasDecl(Primary, "process_completed")) {
                Primary.process_completed(payload);
            } else if (@hasDecl(Fallback, "process_completed")) {
                Fallback.process_completed(payload);
            }
        }

        pub fn cycle_completed(payload: anytype) void {
            if (@hasDecl(Primary, "cycle_completed")) {
                Primary.cycle_completed(payload);
            } else if (@hasDecl(Fallback, "cycle_completed")) {
                Fallback.cycle_completed(payload);
            }
        }

        pub fn pickup_started(payload: anytype) void {
            if (@hasDecl(Primary, "pickup_started")) {
                Primary.pickup_started(payload);
            } else if (@hasDecl(Fallback, "pickup_started")) {
                Fallback.pickup_started(payload);
            }
        }

        pub fn store_started(payload: anytype) void {
            if (@hasDecl(Primary, "store_started")) {
                Primary.store_started(payload);
            } else if (@hasDecl(Fallback, "store_started")) {
                Fallback.store_started(payload);
            }
        }

        pub fn worker_assigned(payload: anytype) void {
            if (@hasDecl(Primary, "worker_assigned")) {
                Primary.worker_assigned(payload);
            } else if (@hasDecl(Fallback, "worker_assigned")) {
                Fallback.worker_assigned(payload);
            }
        }

        pub fn worker_released(payload: anytype) void {
            if (@hasDecl(Primary, "worker_released")) {
                Primary.worker_released(payload);
            } else if (@hasDecl(Fallback, "worker_released")) {
                Fallback.worker_released(payload);
            }
        }

        pub fn workstation_queued(payload: anytype) void {
            if (@hasDecl(Primary, "workstation_queued")) {
                Primary.workstation_queued(payload);
            } else if (@hasDecl(Fallback, "workstation_queued")) {
                Fallback.workstation_queued(payload);
            }
        }

        pub fn workstation_blocked(payload: anytype) void {
            if (@hasDecl(Primary, "workstation_blocked")) {
                Primary.workstation_blocked(payload);
            } else if (@hasDecl(Fallback, "workstation_blocked")) {
                Fallback.workstation_blocked(payload);
            }
        }

        pub fn workstation_activated(payload: anytype) void {
            if (@hasDecl(Primary, "workstation_activated")) {
                Primary.workstation_activated(payload);
            } else if (@hasDecl(Fallback, "workstation_activated")) {
                Fallback.workstation_activated(payload);
            }
        }

        pub fn pickup_dangling_started(payload: anytype) void {
            if (@hasDecl(Primary, "pickup_dangling_started")) {
                Primary.pickup_dangling_started(payload);
            } else if (@hasDecl(Fallback, "pickup_dangling_started")) {
                Fallback.pickup_dangling_started(payload);
            }
        }

        pub fn item_delivered(payload: anytype) void {
            if (@hasDecl(Primary, "item_delivered")) {
                Primary.item_delivered(payload);
            } else if (@hasDecl(Fallback, "item_delivered")) {
                Fallback.item_delivered(payload);
            }
        }
    };
}
