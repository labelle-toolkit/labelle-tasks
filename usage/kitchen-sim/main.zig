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
const WALK_TO_EIS_SECS = 1;
const COOK_TIME_SECS = 4;
const INTERRUPT_DURATION_SECS = 4;

// Convert to ticks
const WALK_TO_GARDEN = WALK_TO_GARDEN_SECS * TICKS_PER_SECOND;
const WALK_TO_BUTCHER = WALK_TO_BUTCHER_SECS * TICKS_PER_SECOND;
const WALK_TO_EIS = WALK_TO_EIS_SECS * TICKS_PER_SECOND;
const COOK_TIME = COOK_TIME_SECS * TICKS_PER_SECOND;
const INTERRUPT_DURATION = INTERRUPT_DURATION_SECS * TICKS_PER_SECOND;

// Recipe requirements
const VEGETABLES_NEEDED = 2;
const MEAT_NEEDED = 1;

// Entity IDs
const CHEF_ID: u32 = 1;
const GARDEN_WORKSTATION_ID: u32 = 10;
const BUTCHER_WORKSTATION_ID: u32 = 11;
const KITCHEN_WORKSTATION_ID: u32 = 12;

// ============================================================================
// Game State
// ============================================================================

const Location = enum {
    Kitchen,
    Garden,
    Butcher,
    WalkingToGarden,
    WalkingFromGarden,
    WalkingToButcher,
    WalkingFromButcher,
    WalkingToEIS,
    WalkingFromEIS,
    AtWorkstation,
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
    Meal,
};

const GameState = struct {
    // Storages
    garden_vegetables: u32 = 0,
    butcher_meat: u32 = 0,
    eis_vegetables: u32 = 0,
    eis_meat: u32 = 0,
    iis_vegetables: u32 = 0,
    iis_meat: u32 = 0,
    ios_meals: u32 = 0,
    eos_meals: u32 = 0,

    // Chef state
    chef_state: ChefState = .Idle,
    chef_location: Location = .Kitchen,
    chef_timer: u32 = 0,
    chef_carrying: ?Item = null,

    // Current cooking step
    cooking_step: u8 = 0,
    cooking_timer: u32 = 0,

    // Time tracking
    total_ticks: u64 = 0,

    // Event messages
    last_event: []const u8 = "",

    // Engine reference
    engine: *tasks.Engine(u32),

    fn canStartCooking(self: *const GameState) bool {
        return self.eis_vegetables >= VEGETABLES_NEEDED and self.eis_meat >= MEAT_NEEDED;
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
    workstation_id: u32,
    step: tasks.StepType,
    available_workers: []const u32,
) ?u32 {
    _ = workstation_id;
    _ = step;
    // Only one chef, return them if available
    for (available_workers) |worker| {
        if (worker == CHEF_ID) return worker;
    }
    return null;
}

fn onStepStarted(
    worker_id: u32,
    workstation_id: u32,
    step: tasks.StepDef,
) void {
    _ = worker_id;

    if (workstation_id == KITCHEN_WORKSTATION_ID) {
        switch (step.type) {
            .Pickup => {
                // Walk to EIS to pickup ingredients
                g_state.chef_state = .Walking;
                g_state.chef_location = .WalkingToEIS;
                g_state.chef_timer = WALK_TO_EIS;
                g_state.last_event = "Chef walking to EIS for ingredients";
            },
            .Cook => {
                // Start cooking
                g_state.chef_state = .Working;
                g_state.chef_location = .AtWorkstation;
                g_state.cooking_timer = COOK_TIME;
                g_state.last_event = "Chef started cooking";
            },
            .Store => {
                // Move meal from IOS to EOS
                g_state.chef_state = .Walking;
                g_state.chef_location = .WalkingToEIS; // Reuse for simplicity
                g_state.chef_timer = WALK_TO_EIS;
                g_state.chef_carrying = .Meal;
                g_state.last_event = "Chef moving meal to storage";
            },
            else => {},
        }
    } else if (workstation_id == GARDEN_WORKSTATION_ID) {
        g_state.chef_state = .Walking;
        g_state.chef_location = .WalkingToGarden;
        g_state.chef_timer = WALK_TO_GARDEN;
        g_state.last_event = "Chef walking to garden";
    } else if (workstation_id == BUTCHER_WORKSTATION_ID) {
        g_state.chef_state = .Walking;
        g_state.chef_location = .WalkingToButcher;
        g_state.chef_timer = WALK_TO_BUTCHER;
        g_state.last_event = "Chef walking to butcher";
    }
}

fn onStepCompleted(
    worker_id: u32,
    workstation_id: u32,
    step: tasks.StepDef,
) void {
    _ = worker_id;
    _ = workstation_id;
    _ = step;
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

fn shouldContinue(
    workstation_id: u32,
    worker_id: u32,
    cycles_completed: u32,
) bool {
    _ = worker_id;
    _ = cycles_completed;

    // Continue if workstation can still work
    if (workstation_id == KITCHEN_WORKSTATION_ID) {
        return g_state.canStartCooking();
    } else if (workstation_id == GARDEN_WORKSTATION_ID) {
        return g_state.garden_vegetables > 0;
    } else if (workstation_id == BUTCHER_WORKSTATION_ID) {
        return g_state.butcher_meat > 0;
    }
    return false;
}

// ============================================================================
// Game Logic
// ============================================================================

fn updateGame(state: *GameState) void {
    state.total_ticks += 1;

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
            checkAndAssignWork(state);
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

    if (state.cooking_timer > 0) {
        state.cooking_timer -= 1;
        if (state.cooking_timer == 0) {
            handleCookingComplete(state);
        }
        return;
    }

    // Check for available work if idle
    if (state.chef_state == .Idle) {
        checkAndAssignWork(state);
    }
}

fn handleTimerComplete(state: *GameState) void {
    switch (state.chef_location) {
        .WalkingToGarden => {
            state.chef_location = .Garden;
            if (state.garden_vegetables > 0) {
                state.garden_vegetables -= 1;
                state.chef_carrying = .Vegetable;
                state.chef_location = .WalkingFromGarden;
                state.chef_timer = WALK_TO_GARDEN;
                state.last_event = "Chef picked vegetable, returning";
            }
        },
        .WalkingFromGarden => {
            state.chef_location = .Kitchen;
            if (state.chef_carrying == .Vegetable) {
                state.eis_vegetables += 1;
                state.chef_carrying = null;
                state.last_event = "Chef stored vegetable in EIS";
            }
            state.engine.notifyStepComplete(CHEF_ID);
            // Signal resources available again if there's more vegetables
            if (state.garden_vegetables > 0) {
                state.engine.notifyResourcesAvailable(GARDEN_WORKSTATION_ID);
            }
        },
        .WalkingToButcher => {
            state.chef_location = .Butcher;
            if (state.butcher_meat > 0) {
                state.butcher_meat -= 1;
                state.chef_carrying = .Meat;
                state.chef_location = .WalkingFromButcher;
                state.chef_timer = WALK_TO_BUTCHER;
                state.last_event = "Chef picked meat, returning";
            }
        },
        .WalkingFromButcher => {
            state.chef_location = .Kitchen;
            if (state.chef_carrying == .Meat) {
                state.eis_meat += 1;
                state.chef_carrying = null;
                state.last_event = "Chef stored meat in EIS";
            }
            state.engine.notifyStepComplete(CHEF_ID);
            // Signal resources available again if there's more meat
            if (state.butcher_meat > 0) {
                state.engine.notifyResourcesAvailable(BUTCHER_WORKSTATION_ID);
            }
        },
        .WalkingToEIS => {
            // Pickup from EIS or drop to EOS
            if (state.chef_carrying == .Meal) {
                // Dropping meal to EOS
                state.eos_meals += 1;
                state.chef_carrying = null;
                state.chef_location = .Kitchen;
                state.last_event = "Chef stored meal in EOS";
                state.engine.notifyStepComplete(CHEF_ID);
            } else {
                // Picking up ingredients
                if (state.eis_vegetables > 0) {
                    state.eis_vegetables -= 1;
                    state.iis_vegetables += 1;
                }
                if (state.eis_meat > 0) {
                    state.eis_meat -= 1;
                    state.iis_meat += 1;
                }
                state.chef_location = .WalkingFromEIS;
                state.chef_timer = WALK_TO_EIS;
                state.last_event = "Chef picked ingredients from EIS";
            }
        },
        .WalkingFromEIS => {
            state.chef_location = .AtWorkstation;
            state.last_event = "Chef at workstation with ingredients";
            state.engine.notifyStepComplete(CHEF_ID);
        },
        else => {},
    }

    // Check if kitchen can start after gathering
    if (state.canStartCooking()) {
        state.engine.notifyResourcesAvailable(KITCHEN_WORKSTATION_ID);
    }
}

fn handleCookingComplete(state: *GameState) void {
    // Move ingredients from IIS to meal in IOS
    state.iis_vegetables = 0;
    state.iis_meat = 0;
    state.ios_meals += 1;
    state.last_event = "Cooking complete! Meal ready in IOS";
    state.engine.notifyStepComplete(CHEF_ID);
}

fn checkAndAssignWork(state: *GameState) void {
    // Priority: Kitchen > Butcher > Garden
    if (state.canStartCooking()) {
        state.engine.notifyResourcesAvailable(KITCHEN_WORKSTATION_ID);
    } else if (state.butcher_meat > 0) {
        state.engine.notifyResourcesAvailable(BUTCHER_WORKSTATION_ID);
    } else if (state.garden_vegetables > 0) {
        state.engine.notifyResourcesAvailable(GARDEN_WORKSTATION_ID);
    }
}

fn handleInterrupt(state: *GameState) void {
    if (state.chef_state == .Interrupted) return;

    state.engine.abandonWork(CHEF_ID);
    state.engine.notifyWorkerBusy(CHEF_ID);
    state.chef_state = .Interrupted;
    state.chef_timer = INTERRUPT_DURATION;
    state.chef_carrying = null;
    state.last_event = "Chef interrupted! Blocked for 4 seconds";
}

fn handleSteal(state: *GameState) void {
    // Steal random item from EIS
    const total = state.eis_vegetables + state.eis_meat;
    if (total == 0) {
        state.last_event = "Thief found nothing to steal!";
        return;
    }

    // Simple "random": alternate based on tick count
    if (state.total_ticks % 2 == 0 and state.eis_vegetables > 0) {
        state.eis_vegetables -= 1;
        state.last_event = "Thief stole a vegetable from EIS!";
    } else if (state.eis_meat > 0) {
        state.eis_meat -= 1;
        state.last_event = "Thief stole meat from EIS!";
    } else if (state.eis_vegetables > 0) {
        state.eis_vegetables -= 1;
        state.last_event = "Thief stole a vegetable from EIS!";
    }
}

// ============================================================================
// Display
// ============================================================================

fn render(state: *GameState) void {
    // Clear screen
    std.debug.print("\x1b[2J\x1b[H", .{});

    const total_secs = state.total_ticks / TICKS_PER_SECOND;
    const mins = total_secs / 60;
    const secs = total_secs % 60;

    const ready_str: []const u8 = if (state.canStartCooking()) "Ready!" else "";

    std.debug.print(
        \\
        \\=== Kitchen Simulator ===
        \\Time: {d:0>2}:{d:0>2}
        \\
        \\[Garden]       Vegetables: {d}
        \\[Butcher]      Meat: {d}
        \\
        \\[Kitchen EIS]  Vegetables: {d}  Meat: {d}  {s}
        \\[Kitchen IIS]  Vegetables: {d}  Meat: {d}
        \\[Workstation]  {s}
        \\[Kitchen IOS]  Meals: {d}
        \\[Kitchen EOS]  Meals: {d}
        \\
        \\Chef: {s}
        \\
        \\{s}
        \\
        \\Controls: [M] Add meat  [V] Add vegetable  [I] Interrupt  [S] Steal  [Q] Quit
        \\
    , .{
        mins,
        secs,
        state.garden_vegetables,
        state.butcher_meat,
        state.eis_vegetables,
        state.eis_meat,
        ready_str,
        state.iis_vegetables,
        state.iis_meat,
        getWorkstationStatus(state),
        state.ios_meals,
        state.eos_meals,
        getChefStatus(state),
        state.last_event,
    });
}

fn getWorkstationStatus(state: *GameState) []const u8 {
    if (state.cooking_timer > 0) {
        return "Cooking...";
    }
    const status = state.engine.getWorkstationStatus(KITCHEN_WORKSTATION_ID);
    return switch (status orelse .Blocked) {
        .Blocked => "Blocked (need ingredients)",
        .Queued => "Queued (waiting for chef)",
        .Active => "Active",
    };
}

fn getChefStatus(state: *GameState) []const u8 {
    return switch (state.chef_state) {
        .Idle => "Idle",
        .Interrupted => "INTERRUPTED!",
        .Walking => switch (state.chef_location) {
            .WalkingToGarden => "Walking to garden...",
            .WalkingFromGarden => "Returning from garden...",
            .WalkingToButcher => "Walking to butcher...",
            .WalkingFromButcher => "Returning from butcher...",
            .WalkingToEIS => "Walking to EIS...",
            .WalkingFromEIS => "Walking to workstation...",
            else => "Walking...",
        },
        .Working => "Cooking...",
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

    // Initialize engine
    var engine = tasks.Engine(u32).init(allocator);
    defer engine.deinit();

    engine.setFindBestWorker(findBestWorker);
    engine.setOnStepStarted(onStepStarted);
    engine.setOnStepCompleted(onStepCompleted);
    engine.setOnWorkerReleased(onWorkerReleased);
    engine.setShouldContinue(shouldContinue);

    // Add chef
    _ = engine.addWorker(CHEF_ID, .{});

    // Add workstations
    const garden_steps = [_]tasks.StepDef{.{ .type = .Pickup }};
    _ = engine.addWorkstation(GARDEN_WORKSTATION_ID, .{
        .steps = &garden_steps,
        .priority = .Low,
    });

    const butcher_steps = [_]tasks.StepDef{.{ .type = .Pickup }};
    _ = engine.addWorkstation(BUTCHER_WORKSTATION_ID, .{
        .steps = &butcher_steps,
        .priority = .Normal,
    });

    const kitchen_steps = [_]tasks.StepDef{
        .{ .type = .Pickup }, // Get from EIS to IIS
        .{ .type = .Cook }, // Cook at workstation
        .{ .type = .Store }, // Move from IOS to EOS
    };
    _ = engine.addWorkstation(KITCHEN_WORKSTATION_ID, .{
        .steps = &kitchen_steps,
        .priority = .High,
    });

    // Initialize game state
    var state = GameState{
        .engine = &engine,
    };
    g_state = &state;

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
        state.garden_vegetables = 3;
        state.butcher_meat = 2;
        std.debug.print("Added 3 vegetables to garden and 2 meat to butcher\n\n", .{});

        // Run 500 ticks (50 seconds) of simulation - enough for full cycle
        var tick: u32 = 0;
        var last_event: []const u8 = "";
        while (tick < 500) : (tick += 1) {
            if (state.chef_state == .Idle) {
                checkAndAssignWork(&state);
            }
            updateGame(&state);

            // Print when event changes
            if (!std.mem.eql(u8, state.last_event, last_event)) {
                last_event = state.last_event;
                std.debug.print("[{d:3}] {s}\n", .{ tick, last_event });
            }

            // Stop early if we made a meal
            if (state.eos_meals > 0) {
                std.debug.print("\n[SUCCESS] Meal completed and stored in EOS!\n", .{});
                break;
            }
        }

        std.debug.print("\nFinal state: EIS({d}v/{d}m) EOS({d} meals)\n", .{
            state.eis_vegetables,
            state.eis_meat,
            state.eos_meals,
        });
        return;
    }

    // Interactive game loop
    var running = true;
    while (running) {
        // Handle input
        if (pollInput()) |key| {
            switch (key) {
                'q', 'Q' => running = false,
                'm', 'M' => {
                    state.butcher_meat += 1;
                    state.last_event = "Meat added to butcher";
                    if (state.chef_state == .Idle) {
                        checkAndAssignWork(&state);
                    }
                },
                'v', 'V' => {
                    state.garden_vegetables += 1;
                    state.last_event = "Vegetable added to garden";
                    if (state.chef_state == .Idle) {
                        checkAndAssignWork(&state);
                    }
                },
                'i', 'I' => handleInterrupt(&state),
                's', 'S' => handleSteal(&state),
                else => {},
            }
        }

        // Update game
        updateGame(&state);

        // Render
        render(&state);

        // Sleep for tick duration
        std.Thread.sleep(TICK_MS * std.time.ns_per_ms);
    }

    // Clear screen on exit
    std.debug.print("\x1b[2J\x1b[H", .{});
    std.debug.print("Thanks for playing!\n", .{});
}
