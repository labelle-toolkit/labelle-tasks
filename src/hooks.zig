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

/// Recording hooks struct for testing.
/// Records all dispatched hook events for later assertion.
/// Use with Engine as the TaskHooks parameter.
///
/// Usage:
/// ```zig
/// var recorder = RecordingHooks(u32, Item){};
/// var engine = Engine(u32, Item, RecordingHooks(u32, Item)).init(allocator, recorder, null);
/// defer engine.deinit();
///
/// // ... trigger events ...
///
/// try recorder.expectNext(&engine.dispatcher, .pickup_started);
/// ```
pub fn RecordingHooks(comptime GameId: type, comptime Item: type) type {
    const Payload = TaskHookPayload(GameId, Item);

    return struct {
        const Self = @This();

        events: std.ArrayListUnmanaged(Payload) = .{},
        allocator: ?std.mem.Allocator = null,
        next_idx: usize = 0,

        /// Initialize with an allocator. Must be called before use.
        pub fn init(self: *Self, allocator: std.mem.Allocator) void {
            self.allocator = allocator;
        }

        pub fn deinit(self: *Self) void {
            if (self.allocator) |alloc| {
                self.events.deinit(alloc);
                self.* = .{};
            }
        }

        /// Get the number of recorded events
        pub fn count(self: *const Self) usize {
            return self.events.items.len;
        }

        /// Get event at index
        pub fn get(self: *const Self, index: usize) Payload {
            return self.events.items[index];
        }

        /// Clear all recorded events and reset index
        pub fn clear(self: *Self) void {
            self.events.clearRetainingCapacity();
            self.next_idx = 0;
        }

        /// Assert the next event matches the expected tag (O(1), non-destructive)
        pub fn expectNext(self: *Self, comptime expected_tag: std.meta.Tag(Payload)) !std.meta.TagPayload(Payload, expected_tag) {
            if (self.next_idx >= self.events.items.len) {
                std.debug.print("Expected {s} event but no more events recorded\n", .{@tagName(expected_tag)});
                return error.NoEventsRecorded;
            }
            const event = self.events.items[self.next_idx];
            self.next_idx += 1;
            if (event != expected_tag) {
                std.debug.print("Expected {s} but got {s}\n", .{ @tagName(expected_tag), @tagName(event) });
                return error.UnexpectedEvent;
            }
            return @field(event, @tagName(expected_tag));
        }

        /// Assert no more events remain after the current index
        pub fn expectEmpty(self: *const Self) !void {
            const remaining = self.events.items.len - self.next_idx;
            if (remaining != 0) {
                std.debug.print("Expected no more events but {} remain (next: {s})\n", .{
                    remaining,
                    @tagName(self.events.items[self.next_idx]),
                });
                return error.UnexpectedEvents;
            }
        }

        fn record(self: *Self, payload: Payload) void {
            const alloc = self.allocator orelse @panic("RecordingHooks not initialized. Call init() with an allocator.");
            self.events.append(alloc, payload) catch @panic("RecordingHooks: failed to record event (out of memory).");
        }

        // Hook methods - record the full payload union
        pub fn pickup_started(self: *Self, payload: anytype) void { self.record(.{ .pickup_started = payload }); }
        pub fn process_started(self: *Self, payload: anytype) void { self.record(.{ .process_started = payload }); }
        pub fn process_completed(self: *Self, payload: anytype) void { self.record(.{ .process_completed = payload }); }
        pub fn store_started(self: *Self, payload: anytype) void { self.record(.{ .store_started = payload }); }
        pub fn worker_assigned(self: *Self, payload: anytype) void { self.record(.{ .worker_assigned = payload }); }
        pub fn worker_released(self: *Self, payload: anytype) void { self.record(.{ .worker_released = payload }); }
        pub fn workstation_blocked(self: *Self, payload: anytype) void { self.record(.{ .workstation_blocked = payload }); }
        pub fn workstation_queued(self: *Self, payload: anytype) void { self.record(.{ .workstation_queued = payload }); }
        pub fn workstation_activated(self: *Self, payload: anytype) void { self.record(.{ .workstation_activated = payload }); }
        pub fn cycle_completed(self: *Self, payload: anytype) void { self.record(.{ .cycle_completed = payload }); }
        pub fn transport_started(self: *Self, payload: anytype) void { self.record(.{ .transport_started = payload }); }
        pub fn transport_completed(self: *Self, payload: anytype) void { self.record(.{ .transport_completed = payload }); }
        pub fn pickup_dangling_started(self: *Self, payload: anytype) void { self.record(.{ .pickup_dangling_started = payload }); }
        pub fn item_delivered(self: *Self, payload: anytype) void { self.record(.{ .item_delivered = payload }); }
        pub fn input_consumed(self: *Self, payload: anytype) void { self.record(.{ .input_consumed = payload }); }
    };
}
