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
    pub fn process_started(payload: anytype) void {
        std.log.info("[TaskEngine] process_started: workstation={d}, worker={d}", .{
            payload.workstation_id,
            payload.worker_id,
        });
    }

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
        std.log.info("[TaskEngine] pickup_dangling_started: worker={d}, item={d}, item_type={}, target_storage={d}", .{
            payload.worker_id,
            payload.item_id,
            payload.item_type,
            payload.target_storage_id,
        });
    }

    pub fn item_delivered(payload: anytype) void {
        std.log.info("[TaskEngine] item_delivered: worker={d}, item={d}, storage={d}", .{
            payload.worker_id,
            payload.item_id,
            payload.storage_id,
        });
    }

    pub fn transport_started(payload: anytype) void {
        std.log.info("[TaskEngine] transport_started: worker={d}, from={d}, to={d}, item={}", .{
            payload.worker_id,
            payload.from_storage_id,
            payload.to_storage_id,
            payload.item,
        });
    }

    pub fn transport_completed(payload: anytype) void {
        std.log.info("[TaskEngine] transport_completed: worker={d}, to={d}, item={}", .{
            payload.worker_id,
            payload.to_storage_id,
            payload.item,
        });
    }

    pub fn input_consumed(payload: anytype) void {
        std.log.info("[TaskEngine] input_consumed: workstation={d}, storage={d}, item={}", .{
            payload.workstation_id,
            payload.storage_id,
            payload.item,
        });
    }

    pub fn standalone_item_added(payload: anytype) void {
        std.log.info("[TaskEngine] standalone_item_added: storage={d}, item={}", .{
            payload.storage_id,
            payload.item,
        });
    }

    pub fn standalone_item_removed(payload: anytype) void {
        std.log.info("[TaskEngine] standalone_item_removed: storage={d}", .{
            payload.storage_id,
        });
    }

    pub fn transport_cancelled(payload: anytype) void {
        std.log.info("[TaskEngine] transport_cancelled: worker={d}, from={d}, to={d}, item={?}", .{
            payload.worker_id,
            payload.from_storage_id,
            payload.to_storage_id,
            payload.item,
        });
    }
};

/// Merges two hook structs, with Primary taking precedence over Fallback.
/// If Primary has a hook, it's used; otherwise Fallback's hook is used.
pub fn MergeHooks(comptime Primary: type, comptime Fallback: type) type {
    return struct {
        /// Dispatch to Primary if it has the hook, otherwise Fallback.
        inline fn dispatch(comptime name: []const u8, payload: anytype) void {
            if (@hasDecl(Primary, name)) {
                @field(Primary, name)(payload);
            } else if (@hasDecl(Fallback, name)) {
                @field(Fallback, name)(payload);
            }
        }

        // Hook forwarding - each calls dispatch with its name
        pub fn pickup_started(payload: anytype) void { dispatch("pickup_started", payload); }
        pub fn process_started(payload: anytype) void { dispatch("process_started", payload); }
        pub fn process_completed(payload: anytype) void { dispatch("process_completed", payload); }
        pub fn store_started(payload: anytype) void { dispatch("store_started", payload); }
        pub fn worker_assigned(payload: anytype) void { dispatch("worker_assigned", payload); }
        pub fn worker_released(payload: anytype) void { dispatch("worker_released", payload); }
        pub fn workstation_blocked(payload: anytype) void { dispatch("workstation_blocked", payload); }
        pub fn workstation_queued(payload: anytype) void { dispatch("workstation_queued", payload); }
        pub fn workstation_activated(payload: anytype) void { dispatch("workstation_activated", payload); }
        pub fn cycle_completed(payload: anytype) void { dispatch("cycle_completed", payload); }
        pub fn transport_started(payload: anytype) void { dispatch("transport_started", payload); }
        pub fn transport_completed(payload: anytype) void { dispatch("transport_completed", payload); }
        pub fn pickup_dangling_started(payload: anytype) void { dispatch("pickup_dangling_started", payload); }
        pub fn item_delivered(payload: anytype) void { dispatch("item_delivered", payload); }
        pub fn input_consumed(payload: anytype) void { dispatch("input_consumed", payload); }
        pub fn standalone_item_added(payload: anytype) void { dispatch("standalone_item_added", payload); }
        pub fn standalone_item_removed(payload: anytype) void { dispatch("standalone_item_removed", payload); }
        pub fn transport_cancelled(payload: anytype) void { dispatch("transport_cancelled", payload); }
    };
}
