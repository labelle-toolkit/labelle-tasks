const std = @import("std");

/// TaskHookPayload - Events emitted by task engine to game
/// Game subscribes to these hooks to react to workflow events
pub fn TaskHookPayload(comptime GameId: type, comptime Item: type) type {
    return union(enum) {
        // Step lifecycle
        pickup_started: struct {
            worker_id: GameId,
            storage_id: GameId,
            item: Item,
        },
        process_started: struct {
            workstation_id: GameId,
            worker_id: GameId,
        },
        process_completed: struct {
            workstation_id: GameId,
            worker_id: GameId,
        },
        store_started: struct {
            worker_id: GameId,
            storage_id: GameId,
            item: Item,
        },

        // Worker lifecycle
        worker_assigned: struct {
            worker_id: GameId,
            workstation_id: GameId,
        },
        worker_released: struct {
            worker_id: GameId,
        },

        // Workstation status
        workstation_blocked: struct {
            workstation_id: GameId,
        },
        workstation_queued: struct {
            workstation_id: GameId,
        },
        workstation_activated: struct {
            workstation_id: GameId,
        },

        // Cycle lifecycle
        cycle_completed: struct {
            workstation_id: GameId,
            cycles_completed: u32,
        },

        // Transport lifecycle
        transport_started: struct {
            worker_id: GameId,
            from_storage_id: GameId,
            to_storage_id: GameId,
            item: Item,
        },
        transport_completed: struct {
            worker_id: GameId,
            to_storage_id: GameId,
            item: Item,
        },

        // Dangling item lifecycle
        pickup_dangling_started: struct {
            worker_id: GameId,
            item_id: GameId,
            item_type: Item,
            target_eis_id: GameId,
        },

        // Item delivery (when any item is placed in storage)
        item_delivered: struct {
            worker_id: GameId,
            item_id: GameId,
            item_type: Item,
            storage_id: GameId,
        },

        // Input consumed (when IIS items are consumed during processing)
        input_consumed: struct {
            workstation_id: GameId,
            storage_id: GameId,
            item: Item,
        },
    };
}

/// GameHookPayload - Events sent by game to task engine
/// Game calls engine.handle() with these payloads to notify of state changes
pub fn GameHookPayload(comptime GameId: type, comptime Item: type) type {
    return union(enum) {
        // Storage changes (external - player interaction, spawning, etc.)
        item_added: struct {
            storage_id: GameId,
            item: Item,
        },
        item_removed: struct {
            storage_id: GameId,
        },
        storage_cleared: struct {
            storage_id: GameId,
        },

        // Worker state changes
        worker_available: struct {
            worker_id: GameId,
        },
        worker_unavailable: struct {
            worker_id: GameId,
        },
        worker_removed: struct {
            worker_id: GameId,
        },

        // Workstation state changes
        workstation_enabled: struct {
            workstation_id: GameId,
        },
        workstation_disabled: struct {
            workstation_id: GameId,
        },
        workstation_removed: struct {
            workstation_id: GameId,
        },

        // Step completion (game notifies when done)
        pickup_completed: struct {
            worker_id: GameId,
        },
        work_completed: struct {
            workstation_id: GameId,
        },
        store_completed: struct {
            worker_id: GameId,
        },
    };
}

/// Hook dispatcher that calls comptime hook methods with zero overhead
pub fn HookDispatcher(comptime GameId: type, comptime Item: type, comptime Hooks: type) type {
    return struct {
        const Self = @This();
        const Payload = TaskHookPayload(GameId, Item);

        hooks: Hooks,

        pub fn init(hooks: Hooks) Self {
            return .{ .hooks = hooks };
        }

        pub fn dispatch(self: *Self, payload: Payload) void {
            switch (payload) {
                .pickup_started => |p| self.call("pickup_started", p),
                .process_started => |p| self.call("process_started", p),
                .process_completed => |p| self.call("process_completed", p),
                .store_started => |p| self.call("store_started", p),
                .worker_assigned => |p| self.call("worker_assigned", p),
                .worker_released => |p| self.call("worker_released", p),
                .workstation_blocked => |p| self.call("workstation_blocked", p),
                .workstation_queued => |p| self.call("workstation_queued", p),
                .workstation_activated => |p| self.call("workstation_activated", p),
                .cycle_completed => |p| self.call("cycle_completed", p),
                .transport_started => |p| self.call("transport_started", p),
                .transport_completed => |p| self.call("transport_completed", p),
                .pickup_dangling_started => |p| self.call("pickup_dangling_started", p),
                .item_delivered => |p| self.call("item_delivered", p),
                .input_consumed => |p| self.call("input_consumed", p),
            }
        }

        fn call(self: *Self, comptime hook_name: []const u8, payload: anytype) void {
            if (comptime hasMethod(Hooks, hook_name)) {
                const method = @field(Hooks, hook_name);
                const Method = @TypeOf(method);
                const method_info = @typeInfo(Method).@"fn";

                if (method_info.params.len == 2) {
                    // Method takes self and payload
                    method(&self.hooks, payload);
                } else if (method_info.params.len == 1) {
                    // Static method takes only payload
                    method(payload);
                }
            }
        }

        fn hasMethod(comptime T: type, comptime name: []const u8) bool {
            return @hasDecl(T, name);
        }
    };
}

/// Empty hooks struct for engines that don't need hooks
pub const NoHooks = struct {};
