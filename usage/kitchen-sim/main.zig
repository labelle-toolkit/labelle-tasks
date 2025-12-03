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

// Recipe requirements
const VEGETABLES_NEEDED = 2;
const MEAT_NEEDED = 1;
const WATER_NEEDED = 1;

// Storage limits
const EOS_MAX_MEALS = 4;

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

// Use the parameterized engine type
const GameEngine = tasks.Engine(u32, Item);

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
        const eos_meals = self.engine.getStorageQuantity(KITCHEN_EOS_ID, .Meal);
        return eis_veg >= VEGETABLES_NEEDED and
            eis_meat >= MEAT_NEEDED and
            eis_water >= WATER_NEEDED and
            eos_meals < EOS_MAX_MEALS;
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
// Engine Callbacks
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

fn onPickupStarted(
    worker_id: u32,
    workstation_id: u32,
    eis_id: u32,
) void {
    _ = worker_id;
    _ = eis_id;

    if (workstation_id == KITCHEN_WORKSTATION_ID) {
        // Walk to EIS to pickup ingredients
        g_state.chef_state = .Walking;
        g_state.chef_location = .WalkingToEIS;
        g_state.chef_timer = WALK_TO_EIS;
        g_state.last_event = "Chef walking to EIS for ingredients";
    }
}

fn onProcessStarted(
    worker_id: u32,
    workstation_id: u32,
) void {
    _ = worker_id;

    if (workstation_id == KITCHEN_WORKSTATION_ID) {
        // Start cooking
        g_state.chef_state = .Working;
        g_state.chef_location = .AtWorkstation;
        g_state.last_event = "Chef started cooking";
    } else if (workstation_id == CONDENSER_WORKSTATION_ID) {
        // Start condensing water
        g_state.chef_state = .Working;
        g_state.chef_location = .AtCondenser;
        g_state.last_event = "Chef started condensing water";
    }
}

fn onProcessComplete(
    worker_id: u32,
    workstation_id: u32,
) void {
    _ = worker_id;

    if (workstation_id == KITCHEN_WORKSTATION_ID) {
        g_state.last_event = "Cooking complete! Meal ready in IOS";
    } else if (workstation_id == CONDENSER_WORKSTATION_ID) {
        g_state.last_event = "Condensing complete! Water ready";
    }
}

fn onStoreStarted(
    worker_id: u32,
    workstation_id: u32,
    eos_id: u32,
) void {
    _ = worker_id;
    _ = eos_id;

    if (workstation_id == KITCHEN_WORKSTATION_ID) {
        // Take meal from IOS
        g_state.chef_carrying = .Meal;
        // Walk to EOS to drop it
        g_state.chef_state = .Walking;
        g_state.chef_location = .WalkingToEIS; // Reuse for simplicity
        g_state.chef_timer = WALK_TO_EIS;
        g_state.last_event = "Chef moving meal to storage";
    } else if (workstation_id == CONDENSER_WORKSTATION_ID) {
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

fn onTransportStarted(
    worker_id: u32,
    from_storage_id: u32,
    to_storage_id: u32,
    item: Item,
) void {
    _ = worker_id;
    _ = to_storage_id;

    if (from_storage_id == GARDEN_STORAGE_ID) {
        g_state.chef_state = .Walking;
        g_state.chef_location = .WalkingToGarden;
        g_state.chef_timer = WALK_TO_GARDEN;
        g_state.chef_carrying = item;
        g_state.last_event = "Chef walking to garden";
    } else if (from_storage_id == BUTCHER_STORAGE_ID) {
        g_state.chef_state = .Walking;
        g_state.chef_location = .WalkingToButcher;
        g_state.chef_timer = WALK_TO_BUTCHER;
        g_state.chef_carrying = item;
        g_state.last_event = "Chef walking to butcher";
    } else if (from_storage_id == CONDENSER_EOS_ID) {
        g_state.chef_state = .Walking;
        g_state.chef_location = .WalkingToCondenser;
        g_state.chef_timer = WALK_TO_CONDENSER;
        g_state.chef_carrying = item;
        g_state.last_event = "Chef walking to condenser";
    }
}

fn onWorkerReleased(
    worker_id: u32,
    workstation_id: u32,
) void {
    _ = worker_id;
    _ = workstation_id;
    g_state.chef_state = .Idle;
    g_state.chef_location = .Kitchen;
    g_state.last_event = "Chef released from workstation";
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
                _ = state.engine.addToStorage(KITCHEN_IOS_ID, .Meal, 1);
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
        _ = state.engine.removeFromStorage(KITCHEN_EIS_ID, .Vegetable, 1);
        state.last_event = "Thief stole a vegetable from EIS!";
    } else if (eis_meat > 0) {
        _ = state.engine.removeFromStorage(KITCHEN_EIS_ID, .Meat, 1);
        state.last_event = "Thief stole meat from EIS!";
    } else if (eis_veg > 0) {
        _ = state.engine.removeFromStorage(KITCHEN_EIS_ID, .Vegetable, 1);
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
        \\[Kitchen EOS]  Meals: {d}/{d}
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
        EOS_MAX_MEALS,
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
    const eos_meals = state.engine.getStorageQuantity(KITCHEN_EOS_ID, .Meal);
    const status = state.engine.getWorkstationStatus(KITCHEN_WORKSTATION_ID);
    return switch (status orelse .Blocked) {
        .Blocked => if (eos_meals >= EOS_MAX_MEALS)
            "Blocked (EOS full)"
        else if (state.canStartCooking())
            "Blocked (waiting for chef)"
        else
            "Blocked (need 2v + 1m + 1w)",
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

    // Initialize game state BEFORE setting callbacks
    // (callbacks use g_state and can be called during addWorker/addWorkstation)
    var state = GameState{
        .engine = &engine,
    };
    g_state = &state;

    engine.setFindBestWorker(findBestWorker);
    engine.setOnPickupStarted(onPickupStarted);
    engine.setOnProcessStarted(onProcessStarted);
    engine.setOnProcessComplete(onProcessComplete);
    engine.setOnStoreStarted(onStoreStarted);
    engine.setOnTransportStarted(onTransportStarted);
    engine.setOnWorkerReleased(onWorkerReleased);

    // Add chef
    _ = engine.addWorker(CHEF_ID, .{});

    // Create storages
    // Garden produces vegetables (external source)
    const garden_slots = [_]GameEngine.Slot{.{ .item = .Vegetable, .capacity = 10 }};
    _ = engine.addStorage(GARDEN_STORAGE_ID, .{ .slots = &garden_slots });

    // Butcher produces meat (external source)
    const butcher_slots = [_]GameEngine.Slot{.{ .item = .Meat, .capacity = 10 }};
    _ = engine.addStorage(BUTCHER_STORAGE_ID, .{ .slots = &butcher_slots });

    // Condenser IOS - holds produced water (1 per cycle)
    const condenser_ios_slots = [_]GameEngine.Slot{.{ .item = .Water, .capacity = 1 }};
    _ = engine.addStorage(CONDENSER_IOS_ID, .{ .slots = &condenser_ios_slots });

    // Condenser EOS - output buffer for produced water
    const condenser_eos_slots = [_]GameEngine.Slot{.{ .item = .Water, .capacity = 5 }};
    _ = engine.addStorage(CONDENSER_EOS_ID, .{ .slots = &condenser_eos_slots });

    // Kitchen EIS - receives ingredients from garden/butcher/condenser
    const eis_slots = [_]GameEngine.Slot{
        .{ .item = .Vegetable, .capacity = 10 },
        .{ .item = .Meat, .capacity = 10 },
        .{ .item = .Water, .capacity = 10 },
    };
    _ = engine.addStorage(KITCHEN_EIS_ID, .{ .slots = &eis_slots });

    // Kitchen IIS - holds recipe requirements (consumed per cycle)
    const iis_slots = [_]GameEngine.Slot{
        .{ .item = .Vegetable, .capacity = VEGETABLES_NEEDED },
        .{ .item = .Meat, .capacity = MEAT_NEEDED },
        .{ .item = .Water, .capacity = WATER_NEEDED },
    };
    _ = engine.addStorage(KITCHEN_IIS_ID, .{ .slots = &iis_slots });

    // Kitchen IOS - holds produced meal
    const ios_slots = [_]GameEngine.Slot{.{ .item = .Meal, .capacity = 1 }};
    _ = engine.addStorage(KITCHEN_IOS_ID, .{ .slots = &ios_slots });

    // Kitchen EOS - output buffer for finished meals
    const eos_slots = [_]GameEngine.Slot{.{ .item = .Meal, .capacity = EOS_MAX_MEALS }};
    _ = engine.addStorage(KITCHEN_EOS_ID, .{ .slots = &eos_slots });

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
        .to = KITCHEN_EIS_ID,
        .item = .Meat,
        .priority = .Normal,
    });

    // Transport water from condenser EOS to kitchen EIS
    _ = engine.addTransport(.{
        .from = CONDENSER_EOS_ID,
        .to = KITCHEN_EIS_ID,
        .item = .Water,
        .priority = .Normal,
    });

    // Water condenser workstation - producer (no inputs, just process and store)
    // Low priority so transporting ingredients takes precedence
    _ = engine.addWorkstation(CONDENSER_WORKSTATION_ID, .{
        .ios = CONDENSER_IOS_ID,
        .eos = CONDENSER_EOS_ID,
        .process_duration = CONDENSE_TIME,
        .priority = .Low,
    });

    // Kitchen workstation - full cycle with all storages
    _ = engine.addWorkstation(KITCHEN_WORKSTATION_ID, .{
        .eis = KITCHEN_EIS_ID,
        .iis = KITCHEN_IIS_ID,
        .ios = KITCHEN_IOS_ID,
        .eos = KITCHEN_EOS_ID,
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
        _ = engine.addToStorage(GARDEN_STORAGE_ID, .Vegetable, 3);
        _ = engine.addToStorage(BUTCHER_STORAGE_ID, .Meat, 2);
        std.debug.print("Added 3 vegetables to garden and 2 meat to butcher\n\n", .{});

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
                    _ = engine.addToStorage(BUTCHER_STORAGE_ID, .Meat, 1);
                    state.last_event = "Meat added to butcher";
                },
                'v', 'V' => {
                    _ = engine.addToStorage(GARDEN_STORAGE_ID, .Vegetable, 1);
                    state.last_event = "Vegetable added to garden";
                },
                'w', 'W' => {
                    // Condenser works automatically, but W adds water directly (cheat)
                    _ = engine.addToStorage(KITCHEN_EIS_ID, .Water, 1);
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
