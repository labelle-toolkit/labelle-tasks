const std = @import("std");
const tasks = @import("labelle_tasks");

// ============================================================================
// Game Constants
// ============================================================================

const TICK_MS = 100; // 100ms per tick (10 ticks per second)
const TICKS_PER_SECOND = 1000 / TICK_MS;

// Walk times in seconds
const WALK_TO_GARDEN_SECS = 2;
const WALK_TO_BUTCHER_SECS = 3;
const WALK_TO_CONDENSER_SECS = 1;
const WALK_TO_EIS_SECS = 1;
const COOK_TIME_SECS = 4;
const CONDENSE_TIME_SECS = 3;
const INTERRUPT_DURATION_SECS = 4;

// Convert to ticks
const WALK_TO_GARDEN = WALK_TO_GARDEN_SECS * TICKS_PER_SECOND;
const WALK_TO_BUTCHER = WALK_TO_BUTCHER_SECS * TICKS_PER_SECOND;
const WALK_TO_CONDENSER = WALK_TO_CONDENSER_SECS * TICKS_PER_SECOND;
const WALK_TO_EIS = WALK_TO_EIS_SECS * TICKS_PER_SECOND;
const COOK_TIME = COOK_TIME_SECS * TICKS_PER_SECOND;
const CONDENSE_TIME = CONDENSE_TIME_SECS * TICKS_PER_SECOND;
const INTERRUPT_DURATION = INTERRUPT_DURATION_SECS * TICKS_PER_SECOND;

// Entity IDs
const CHEF_ID: u32 = 1;
const KITCHEN_WORKSTATION_ID: u32 = 12;
const CONDENSER_WORKSTATION_ID: u32 = 13;

// Storage IDs
const GARDEN_STORAGE_ID: u32 = 100;
const BUTCHER_STORAGE_ID: u32 = 101;
const CONDENSER_IOS_ID: u32 = 106;
const CONDENSER_EOS_ID: u32 = 107;
const KITCHEN_EIS_ID: u32 = 102;
const KITCHEN_IIS_ID: u32 = 103;
const KITCHEN_IOS_ID: u32 = 104;
const KITCHEN_EOS_ID: u32 = 105;

// ============================================================================
// Game Types
// ============================================================================

const Location = enum {
    Kitchen,
    Garden,
    Butcher,
    Condenser,
    WalkingToGarden,
    WalkingFromGarden,
    WalkingToButcher,
    WalkingFromButcher,
    WalkingToCondenser,
    WalkingFromCondenser,
    WalkingToEIS,
    WalkingToIIS,
    AtWorkstation,
    AtCondenser,
};

const ChefState = enum {
    Idle,
    Walking,
    Working,
    Interrupted,
};

const Item = enum {
    Vegetable,
    Meat,
    Water,
    Meal,
};

// Forward declaration for hook handlers (need access to g_state)
const KitchenHooks = struct {
    pub fn pickup_started(payload: tasks.hooks.HookPayload(u32, Item)) void {
        const info = payload.pickup_started;
        if (info.workstation_id == KITCHEN_WORKSTATION_ID) {
            // Walk to EIS to pickup ingredients
            g_state.chef_state = .Walking;
            g_state.chef_location = .WalkingToEIS;
            g_state.chef_timer = WALK_TO_EIS;
            g_state.last_event = "Chef walking to EIS for ingredients";
        }
    }

    pub fn process_started(payload: tasks.hooks.HookPayload(u32, Item)) void {
        const info = payload.process_started;
        if (info.workstation_id == KITCHEN_WORKSTATION_ID) {
            // Start cooking
            g_state.chef_state = .Working;
            g_state.chef_location = .AtWorkstation;
            g_state.last_event = "Chef started cooking";
        } else if (info.workstation_id == CONDENSER_WORKSTATION_ID) {
            // Start condensing water
            g_state.chef_state = .Working;
            g_state.chef_location = .AtCondenser;
            g_state.last_event = "Chef started condensing water";
        }
    }

    pub fn process_completed(payload: tasks.hooks.HookPayload(u32, Item)) void {
        const info = payload.process_completed;
        if (info.workstation_id == KITCHEN_WORKSTATION_ID) {
            g_state.last_event = "Cooking complete! Meal ready in IOS";
        } else if (info.workstation_id == CONDENSER_WORKSTATION_ID) {
            g_state.last_event = "Condensing complete! Water ready";
        }
    }

    pub fn store_started(payload: tasks.hooks.HookPayload(u32, Item)) void {
        const info = payload.store_started;
        if (info.workstation_id == KITCHEN_WORKSTATION_ID) {
            // Take meal from IOS
            g_state.chef_carrying = .Meal;
            // Walk to EOS to drop it
            g_state.chef_state = .Walking;
            g_state.chef_location = .WalkingToEIS; // Reuse for simplicity
            g_state.chef_timer = WALK_TO_EIS;
            g_state.last_event = "Chef moving meal to storage";
        } else if (info.workstation_id == CONDENSER_WORKSTATION_ID) {
            // Take water from condenser IOS and store to condenser EOS
            g_state.chef_carrying = .Water;
            g_state.doing_condenser_store = true;
            // Walk to condenser EOS
            g_state.chef_state = .Walking;
            g_state.chef_location = .WalkingFromCondenser;
            g_state.chef_timer = WALK_TO_CONDENSER;
            g_state.last_event = "Chef collecting water from condenser";
        }
    }

    pub fn transport_started(payload: tasks.hooks.HookPayload(u32, Item)) void {
        const info = payload.transport_started;
        if (info.from_storage_id == GARDEN_STORAGE_ID) {
            g_state.chef_state = .Walking;
            g_state.chef_location = .WalkingToGarden;
            g_state.chef_timer = WALK_TO_GARDEN;
            g_state.chef_carrying = info.item;
            g_state.last_event = "Chef walking to garden";
        } else if (info.from_storage_id == BUTCHER_STORAGE_ID) {
            g_state.chef_state = .Walking;
            g_state.chef_location = .WalkingToButcher;
            g_state.chef_timer = WALK_TO_BUTCHER;
            g_state.chef_carrying = info.item;
            g_state.last_event = "Chef walking to butcher";
        } else if (info.from_storage_id == CONDENSER_EOS_ID) {
            g_state.chef_state = .Walking;
            g_state.chef_location = .WalkingToCondenser;
            g_state.chef_timer = WALK_TO_CONDENSER;
            g_state.chef_carrying = info.item;
            g_state.last_event = "Chef walking to condenser";
        }
    }

    pub fn worker_released(_: tasks.hooks.HookPayload(u32, Item)) void {
        g_state.chef_state = .Idle;
        g_state.chef_location = .Kitchen;
        g_state.last_event = "Chef released from workstation";
    }
};

const Dispatcher = tasks.hooks.HookDispatcher(u32, Item, KitchenHooks);
const GameEngine = tasks.Engine(u32, Item, Dispatcher);

// ============================================================================
// Game State
// ============================================================================

const GameState = struct {
    // Chef state
    chef_state: ChefState = .Idle,
    chef_location: Location = .Kitchen,
    chef_timer: u32 = 0,
    chef_carrying: ?Item = null,

    // Track condenser store vs transport
    doing_condenser_store: bool = false, // True when storing condenser output

    // Time tracking
    total_ticks: u64 = 0,

    // Event messages
    last_event: []const u8 = "",

    // Engine reference
    engine: *GameEngine,

    fn canStartCooking(self: *const GameState) bool {
        const eis_veg = self.engine.getStorageQuantity(KITCHEN_EIS_ID, .Vegetable);
        const eis_meat = self.engine.getStorageQuantity(KITCHEN_EIS_ID, .Meat);
        const eis_water = self.engine.getStorageQuantity(KITCHEN_EIS_ID, .Water);
        // Recipe needs 1 of each ingredient
        return eis_veg >= 1 and eis_meat >= 1 and eis_water >= 1;
    }

    fn ticksToSecs(ticks: u32) f32 {
        return @as(f32, @floatFromInt(ticks)) / @as(f32, @floatFromInt(TICKS_PER_SECOND));
    }
};

// ============================================================================
// Global State (for callbacks)
// ============================================================================

var g_state: *GameState = undefined;

// ============================================================================
// Engine Callbacks (only findBestWorker needed)
// ============================================================================

fn findBestWorker(
    workstation_id: ?u32,
    available_workers: []const u32,
) ?u32 {
    _ = workstation_id;
    // Only one chef, return them if available
    for (available_workers) |worker| {
        if (worker == CHEF_ID) return worker;
    }
    return null;
}

// ============================================================================
// Game Logic
// ============================================================================

fn updateGame(state: *GameState) void {
    state.total_ticks += 1;

    // Update engine timers
    state.engine.update();

    // Handle interrupted state
    if (state.chef_state == .Interrupted) {
        if (state.chef_timer > 0) {
            state.chef_timer -= 1;
        } else {
            // Recovery from interrupt
            state.chef_state = .Idle;
            state.chef_location = .Kitchen;
            state.engine.notifyWorkerIdle(CHEF_ID);
            state.last_event = "Chef recovered from interruption";
        }
        return;
    }

    // Handle walking/working timers
    if (state.chef_timer > 0) {
        state.chef_timer -= 1;
        if (state.chef_timer == 0) {
            handleTimerComplete(state);
        }
        return;
    }

}

fn handleTimerComplete(state: *GameState) void {
    switch (state.chef_location) {
        .WalkingToGarden => {
            state.chef_location = .Garden;
            // Pick up the vegetable (engine already reserved it)
            state.chef_location = .WalkingFromGarden;
            state.chef_timer = WALK_TO_GARDEN;
            state.last_event = "Chef picked vegetable, returning";
        },
        .WalkingFromGarden => {
            state.chef_location = .Kitchen;
            state.chef_carrying = null;
            state.last_event = "Chef stored vegetable in EIS";
            state.engine.notifyTransportComplete(CHEF_ID);
        },
        .WalkingToButcher => {
            state.chef_location = .Butcher;
            // Pick up the meat (engine already reserved it)
            state.chef_location = .WalkingFromButcher;
            state.chef_timer = WALK_TO_BUTCHER;
            state.last_event = "Chef picked meat, returning";
        },
        .WalkingFromButcher => {
            state.chef_location = .Kitchen;
            state.chef_carrying = null;
            state.last_event = "Chef stored meat in EIS";
            state.engine.notifyTransportComplete(CHEF_ID);
        },
        .WalkingToCondenser => {
            // Transport: picking up water from condenser EOS
            state.chef_location = .Condenser;
            // Pick up the water
            state.chef_location = .WalkingFromCondenser;
            state.chef_timer = WALK_TO_CONDENSER;
            state.last_event = "Chef picked water from condenser";
        },
        .WalkingFromCondenser => {
            state.chef_location = .Kitchen;
            state.chef_carrying = null;
            if (state.doing_condenser_store) {
                // This was a store step - water moved IOS to EOS
                state.doing_condenser_store = false;
                state.last_event = "Chef stored water in condenser EOS";
                state.engine.notifyStoreComplete(CHEF_ID);
            } else {
                // This was a transport - water moved from condenser EOS to kitchen EIS
                state.last_event = "Chef stored water in kitchen EIS";
                state.engine.notifyTransportComplete(CHEF_ID);
            }
        },
        .WalkingToEIS => {
            // Pickup from EIS or drop to EOS
            if (state.chef_carrying == .Meal) {
                // Dropping meal to EOS - engine handles the transfer
                state.chef_carrying = null;
                state.chef_location = .Kitchen;
                state.last_event = "Chef stored meal in EOS";
                state.engine.notifyStoreComplete(CHEF_ID);
            } else {
                // Picking up ingredients - engine handles EIS -> IIS transfer
                state.chef_carrying = .Vegetable; // Represents carrying ingredients
                state.chef_location = .WalkingToIIS;
                state.chef_timer = WALK_TO_EIS; // Same distance back to IIS
                state.last_event = "Chef picked ingredients from EIS";
            }
        },
        .WalkingToIIS => {
            // Arrived at IIS with ingredients - engine handles the transfer
            state.chef_carrying = null;
            state.chef_location = .AtWorkstation;
            state.last_event = "Chef delivered ingredients to IIS";
            state.engine.notifyPickupComplete(CHEF_ID);
        },
        else => {},
    }
}


fn handleInterrupt(state: *GameState) void {
    if (state.chef_state == .Interrupted) return;

    // If chef was carrying something, handle it
    if (state.chef_carrying) |item| {
        switch (item) {
            .Meal => {
                // Put meal back in IOS
                _ = state.engine.addToStorage(KITCHEN_IOS_ID, .Meal);
                state.last_event = "Chef interrupted! Meal returned to IOS";
            },
            .Vegetable => {
                state.last_event = "Chef interrupted! Dropped vegetable";
            },
            .Meat => {
                state.last_event = "Chef interrupted! Dropped meat";
            },
            .Water => {
                state.last_event = "Chef interrupted! Spilled water";
            },
        }
        state.chef_carrying = null;
    } else {
        state.last_event = "Chef interrupted! Blocked for 4 seconds";
    }

    state.engine.abandonWork(CHEF_ID);
    state.engine.notifyWorkerBusy(CHEF_ID);
    state.chef_state = .Interrupted;
    state.chef_timer = INTERRUPT_DURATION;
}

fn handleSteal(state: *GameState) void {
    // Steal random item from EIS
    const eis_veg = state.engine.getStorageQuantity(KITCHEN_EIS_ID, .Vegetable);
    const eis_meat = state.engine.getStorageQuantity(KITCHEN_EIS_ID, .Meat);
    const total = eis_veg + eis_meat;
    if (total == 0) {
        state.last_event = "Thief found nothing to steal!";
        return;
    }

    // Simple "random": alternate based on tick count
    if (state.total_ticks % 2 == 0 and eis_veg > 0) {
        _ = state.engine.removeFromStorage(KITCHEN_EIS_ID, .Vegetable);
        state.last_event = "Thief stole a vegetable from EIS!";
    } else if (eis_meat > 0) {
        _ = state.engine.removeFromStorage(KITCHEN_EIS_ID, .Meat);
        state.last_event = "Thief stole meat from EIS!";
    } else if (eis_veg > 0) {
        _ = state.engine.removeFromStorage(KITCHEN_EIS_ID, .Vegetable);
        state.last_event = "Thief stole a vegetable from EIS!";
    }
}

// ============================================================================
// Display
// ============================================================================

fn render(state: *GameState) void {
    // Clear screen
    std.debug.print("\x1b[2J\x1b[H", .{});

    const garden_veg = state.engine.getStorageQuantity(GARDEN_STORAGE_ID, .Vegetable);
    const butcher_meat = state.engine.getStorageQuantity(BUTCHER_STORAGE_ID, .Meat);
    const condenser_water = state.engine.getStorageQuantity(CONDENSER_EOS_ID, .Water);
    const eis_veg = state.engine.getStorageQuantity(KITCHEN_EIS_ID, .Vegetable);
    const eis_meat = state.engine.getStorageQuantity(KITCHEN_EIS_ID, .Meat);
    const eis_water = state.engine.getStorageQuantity(KITCHEN_EIS_ID, .Water);
    const iis_veg = state.engine.getStorageQuantity(KITCHEN_IIS_ID, .Vegetable);
    const iis_meat = state.engine.getStorageQuantity(KITCHEN_IIS_ID, .Meat);
    const iis_water = state.engine.getStorageQuantity(KITCHEN_IIS_ID, .Water);
    const ios_meals = state.engine.getStorageQuantity(KITCHEN_IOS_ID, .Meal);
    const eos_meals = state.engine.getStorageQuantity(KITCHEN_EOS_ID, .Meal);

    const ready_str: []const u8 = if (state.canStartCooking()) "Ready!" else "";

    std.debug.print(
        \\
        \\=== Kitchen Simulator ===
        \\
        \\[Garden]       Vegetables: {d}
        \\[Butcher]      Meat: {d}
        \\[Condenser]    Water: {d}  {s}
        \\
        \\[Kitchen EIS]  Veg: {d}  Meat: {d}  Water: {d}  {s}
        \\[Kitchen IIS]  Veg: {d}  Meat: {d}  Water: {d}
        \\[Workstation]  {s}
        \\[Kitchen IOS]  Meals: {d}
        \\[Kitchen EOS]  Meals: {d}
        \\
        \\Chef: {s}
        \\
        \\{s}
        \\
        \\Controls: [M] Add meat  [V] Add vegetable  [W] Condense water  [I] Interrupt  [S] Steal  [Q] Quit
        \\
    , .{
        garden_veg,
        butcher_meat,
        condenser_water,
        getCondenserStatus(state),
        eis_veg,
        eis_meat,
        eis_water,
        ready_str,
        iis_veg,
        iis_meat,
        iis_water,
        getWorkstationStatus(state),
        ios_meals,
        eos_meals,
        getChefStatus(state),
        state.last_event,
    });
}

fn getCondenserStatus(state: *GameState) []const u8 {
    const status = state.engine.getWorkstationStatus(CONDENSER_WORKSTATION_ID);
    return switch (status orelse .Blocked) {
        .Blocked => "Blocked",
        .Queued => "Queued",
        .Active => "Condensing...",
    };
}

fn getWorkstationStatus(state: *GameState) []const u8 {
    const status = state.engine.getWorkstationStatus(KITCHEN_WORKSTATION_ID);
    return switch (status orelse .Blocked) {
        .Blocked => if (state.canStartCooking())
            "Blocked (waiting for chef)"
        else
            "Blocked (need 1v + 1m + 1w)",
        .Queued => "Queued (waiting for chef)",
        .Active => "Cooking...",
    };
}

fn getChefStatus(state: *GameState) []const u8 {
    const garden_veg = state.engine.getStorageQuantity(GARDEN_STORAGE_ID, .Vegetable);
    const butcher_meat = state.engine.getStorageQuantity(BUTCHER_STORAGE_ID, .Meat);
    const condenser_water = state.engine.getStorageQuantity(CONDENSER_EOS_ID, .Water);
    const condenser_status = state.engine.getWorkstationStatus(CONDENSER_WORKSTATION_ID);

    return switch (state.chef_state) {
        .Idle => if (garden_veg > 0 or butcher_meat > 0 or condenser_water > 0 or state.canStartCooking())
            "Idle (waiting for assignment)"
        else if (condenser_status == .Queued)
            "Idle (condenser ready)"
        else
            "Idle (nothing to do)",
        .Interrupted => "INTERRUPTED!",
        .Walking => switch (state.chef_location) {
            .WalkingToGarden => "Walking to garden...",
            .WalkingFromGarden => "Returning from garden...",
            .WalkingToButcher => "Walking to butcher...",
            .WalkingFromButcher => "Returning from butcher...",
            .WalkingToCondenser => "Walking to condenser...",
            .WalkingFromCondenser => "Returning from condenser...",
            .WalkingToEIS => "Walking to EIS...",
            .WalkingToIIS => "Carrying ingredients to IIS...",
            else => "Walking...",
        },
        .Working => if (state.chef_location == .AtCondenser)
            "Condensing water..."
        else
            "Cooking...",
    };
}

// ============================================================================
// Input Handling
// ============================================================================

fn setupTerminal() !?std.posix.termios {
    // Check if stdin is a TTY
    if (!std.posix.isatty(std.posix.STDIN_FILENO)) {
        return null;
    }

    var termios = try std.posix.tcgetattr(std.posix.STDIN_FILENO);
    const original = termios;

    // Disable canonical mode and echo
    termios.lflag.ICANON = false;
    termios.lflag.ECHO = false;
    termios.cc[@intFromEnum(std.posix.V.MIN)] = 0;
    termios.cc[@intFromEnum(std.posix.V.TIME)] = 0;

    try std.posix.tcsetattr(std.posix.STDIN_FILENO, .NOW, termios);
    return original;
}

fn restoreTerminal(original: ?std.posix.termios) void {
    if (original) |term| {
        std.posix.tcsetattr(std.posix.STDIN_FILENO, .NOW, term) catch {};
    }
}

fn pollInput() ?u8 {
    var buf: [1]u8 = undefined;
    const n = std.posix.read(std.posix.STDIN_FILENO, &buf) catch return null;
    if (n > 0) return buf[0];
    return null;
}

// ============================================================================
// Main
// ============================================================================

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize engine with Item type
    var engine = GameEngine.init(allocator);
    defer engine.deinit();

    // Initialize game state BEFORE hooks can fire
    // (hooks use g_state and can be called during addWorker/addWorkstation)
    var state = GameState{
        .engine = &engine,
    };
    g_state = &state;

    engine.setFindBestWorker(findBestWorker);

    // Add chef
    _ = engine.addWorker(CHEF_ID, .{});

    // Create storages (each storage holds one item type)
    // Garden produces vegetables (external source)
    _ = engine.addStorage(GARDEN_STORAGE_ID, .{ .item = .Vegetable });

    // Butcher produces meat (external source)
    _ = engine.addStorage(BUTCHER_STORAGE_ID, .{ .item = .Meat });

    // Condenser IOS - holds produced water (1 per cycle)
    _ = engine.addStorage(CONDENSER_IOS_ID, .{ .item = .Water });

    // Condenser EOS - output buffer for produced water
    _ = engine.addStorage(CONDENSER_EOS_ID, .{ .item = .Water });

    // Kitchen EIS - receives ingredients (need separate storage for each item type)
    _ = engine.addStorage(KITCHEN_EIS_ID, .{ .item = .Vegetable });
    const KITCHEN_EIS_MEAT_ID: u32 = 108;
    const KITCHEN_EIS_WATER_ID: u32 = 109;
    _ = engine.addStorage(KITCHEN_EIS_MEAT_ID, .{ .item = .Meat });
    _ = engine.addStorage(KITCHEN_EIS_WATER_ID, .{ .item = .Water });

    // Kitchen IIS - holds recipe requirements (1 of each per cycle)
    const KITCHEN_IIS_VEG_ID: u32 = 110;
    const KITCHEN_IIS_MEAT_ID: u32 = 111;
    const KITCHEN_IIS_WATER_ID: u32 = 112;
    _ = engine.addStorage(KITCHEN_IIS_VEG_ID, .{ .item = .Vegetable });
    _ = engine.addStorage(KITCHEN_IIS_MEAT_ID, .{ .item = .Meat });
    _ = engine.addStorage(KITCHEN_IIS_WATER_ID, .{ .item = .Water });

    // Kitchen IOS - holds produced meal (1 per cycle)
    _ = engine.addStorage(KITCHEN_IOS_ID, .{ .item = .Meal });

    // Kitchen EOS - output buffer for finished meals
    _ = engine.addStorage(KITCHEN_EOS_ID, .{ .item = .Meal });

    // Add transports for moving ingredients from external sources to kitchen
    // Transport vegetables from garden to kitchen EIS
    _ = engine.addTransport(.{
        .from = GARDEN_STORAGE_ID,
        .to = KITCHEN_EIS_ID,
        .item = .Vegetable,
        .priority = .Normal,
    });

    // Transport meat from butcher to kitchen EIS
    _ = engine.addTransport(.{
        .from = BUTCHER_STORAGE_ID,
        .to = KITCHEN_EIS_MEAT_ID,
        .item = .Meat,
        .priority = .Normal,
    });

    // Transport water from condenser EOS to kitchen EIS
    _ = engine.addTransport(.{
        .from = CONDENSER_EOS_ID,
        .to = KITCHEN_EIS_WATER_ID,
        .item = .Water,
        .priority = .Normal,
    });

    // Water condenser workstation - producer (no inputs, just process and store)
    // Low priority so transporting ingredients takes precedence
    _ = engine.addWorkstation(CONDENSER_WORKSTATION_ID, .{
        .ios = &.{CONDENSER_IOS_ID},
        .eos = &.{CONDENSER_EOS_ID},
        .process_duration = CONDENSE_TIME,
        .priority = .Low,
    });

    // Kitchen workstation - full cycle with all storages
    _ = engine.addWorkstation(KITCHEN_WORKSTATION_ID, .{
        .eis = &.{ KITCHEN_EIS_ID, KITCHEN_EIS_MEAT_ID, KITCHEN_EIS_WATER_ID },
        .iis = &.{ KITCHEN_IIS_VEG_ID, KITCHEN_IIS_MEAT_ID, KITCHEN_IIS_WATER_ID },
        .ios = &.{KITCHEN_IOS_ID},
        .eos = &.{KITCHEN_EOS_ID},
        .process_duration = COOK_TIME,
        .priority = .High,
    });

    // Setup terminal for non-blocking input
    const original_termios = try setupTerminal();
    defer restoreTerminal(original_termios);

    // Check if we're in interactive mode (TTY) or demo mode (piped)
    const interactive = original_termios != null;

    if (!interactive) {
        // Demo mode: run a quick simulation
        std.debug.print("Kitchen Simulator - Demo Mode (no TTY detected)\n", .{});
        std.debug.print("Run directly in terminal for interactive mode.\n\n", .{});

        // Add ingredients to garden and butcher
        // Single-item storage: add 1 item each (max capacity)
        _ = engine.addToStorage(GARDEN_STORAGE_ID, .Vegetable);
        _ = engine.addToStorage(BUTCHER_STORAGE_ID, .Meat);
        std.debug.print("Added 1 vegetable to garden and 1 meat to butcher\n\n", .{});

        // Run 800 ticks (80 seconds) of simulation - enough for full cycle with condenser
        var tick: u32 = 0;
        var last_event: []const u8 = "";
        while (tick < 800) : (tick += 1) {
            updateGame(&state);

            // Print when event changes
            if (!std.mem.eql(u8, state.last_event, last_event)) {
                last_event = state.last_event;
                std.debug.print("[{d:3}] {s}\n", .{ tick, last_event });
            }

            // Stop early if we made a meal
            const eos_meals = engine.getStorageQuantity(KITCHEN_EOS_ID, .Meal);
            if (eos_meals > 0) {
                std.debug.print("\n[SUCCESS] Meal completed and stored in EOS!\n", .{});
                break;
            }
        }

        const eis_veg = engine.getStorageQuantity(KITCHEN_EIS_ID, .Vegetable);
        const eis_meat = engine.getStorageQuantity(KITCHEN_EIS_ID, .Meat);
        const eis_water = engine.getStorageQuantity(KITCHEN_EIS_ID, .Water);
        const eos_meals = engine.getStorageQuantity(KITCHEN_EOS_ID, .Meal);
        std.debug.print("\nFinal state: EIS({d}v/{d}m/{d}w) EOS({d} meals)\n", .{
            eis_veg,
            eis_meat,
            eis_water,
            eos_meals,
        });
        return;
    }

    // Interactive game loop - only render when state changes
    var running = true;
    var last_event: []const u8 = "";
    var last_chef_state: ChefState = .Idle;
    var last_chef_location: Location = .Kitchen;
    var last_garden: u32 = 0;
    var last_butcher: u32 = 0;
    var last_condenser: u32 = 0;
    var last_eis_veg: u32 = 0;
    var last_eis_meat: u32 = 0;
    var last_eis_water: u32 = 0;
    var last_iis_veg: u32 = 0;
    var last_iis_meat: u32 = 0;
    var last_iis_water: u32 = 0;
    var last_ios: u32 = 0;
    var last_eos: u32 = 0;

    // Initial render
    render(&state);

    while (running) {
        // Handle input
        if (pollInput()) |key| {
            switch (key) {
                'q', 'Q' => running = false,
                'm', 'M' => {
                    _ = engine.addToStorage(BUTCHER_STORAGE_ID, .Meat);
                    state.last_event = "Meat added to butcher";
                },
                'v', 'V' => {
                    _ = engine.addToStorage(GARDEN_STORAGE_ID, .Vegetable);
                    state.last_event = "Vegetable added to garden";
                },
                'w', 'W' => {
                    // Condenser works automatically, but W adds water directly (cheat)
                    _ = engine.addToStorage(KITCHEN_EIS_ID, .Water);
                    state.last_event = "Water added directly to EIS (cheat)";
                },
                'i', 'I' => handleInterrupt(&state),
                's', 'S' => handleSteal(&state),
                else => {},
            }
        }

        // Update game
        updateGame(&state);

        // Get current storage values
        const garden_veg = engine.getStorageQuantity(GARDEN_STORAGE_ID, .Vegetable);
        const butcher_meat = engine.getStorageQuantity(BUTCHER_STORAGE_ID, .Meat);
        const condenser_water = engine.getStorageQuantity(CONDENSER_EOS_ID, .Water);
        const eis_veg = engine.getStorageQuantity(KITCHEN_EIS_ID, .Vegetable);
        const eis_meat = engine.getStorageQuantity(KITCHEN_EIS_ID, .Meat);
        const eis_water = engine.getStorageQuantity(KITCHEN_EIS_ID, .Water);
        const iis_veg = engine.getStorageQuantity(KITCHEN_IIS_ID, .Vegetable);
        const iis_meat = engine.getStorageQuantity(KITCHEN_IIS_ID, .Meat);
        const iis_water = engine.getStorageQuantity(KITCHEN_IIS_ID, .Water);
        const ios_meals = engine.getStorageQuantity(KITCHEN_IOS_ID, .Meal);
        const eos_meals = engine.getStorageQuantity(KITCHEN_EOS_ID, .Meal);

        // Check if state changed
        const state_changed = !std.mem.eql(u8, state.last_event, last_event) or
            state.chef_state != last_chef_state or
            state.chef_location != last_chef_location or
            garden_veg != last_garden or
            butcher_meat != last_butcher or
            condenser_water != last_condenser or
            eis_veg != last_eis_veg or
            eis_meat != last_eis_meat or
            eis_water != last_eis_water or
            iis_veg != last_iis_veg or
            iis_meat != last_iis_meat or
            iis_water != last_iis_water or
            ios_meals != last_ios or
            eos_meals != last_eos;

        if (state_changed) {
            render(&state);

            // Update last state
            last_event = state.last_event;
            last_chef_state = state.chef_state;
            last_chef_location = state.chef_location;
            last_garden = garden_veg;
            last_butcher = butcher_meat;
            last_condenser = condenser_water;
            last_eis_veg = eis_veg;
            last_eis_meat = eis_meat;
            last_eis_water = eis_water;
            last_iis_veg = iis_veg;
            last_iis_meat = iis_meat;
            last_iis_water = iis_water;
            last_ios = ios_meals;
            last_eos = eos_meals;
        }

        // Sleep for tick duration
        std.Thread.sleep(TICK_MS * std.time.ns_per_ms);
    }

    // Clear screen on exit
    std.debug.print("\x1b[2J\x1b[H", .{});
    std.debug.print("Thanks for playing!\n", .{});
}
