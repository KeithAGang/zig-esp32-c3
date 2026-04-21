const std = @import("std");
const c = @import("idf_c/idf_c.zig").c;
const Viewport = @import("viewport/viewport.zig").ViewPort;
const uart = @import("uart/uart.zig");
const drawWindow = @import("compositor/compositor.zig").drawWindow;

extern "c" fn esp_get_free_heap_size() u32;

// ============================================================================
// DOD STATE MANAGEMENT
// ============================================================================
// We explicitly define our data requirements.
const MAX_CMD_LEN = 64;
const HISTORY_SIZE = 5;

// 🔥 FIX 1: Move the physical memory pool OUTSIDE the function!
// Now it lives safely in Static RAM (.bss), not on the tiny execution stack.
var os_memory_pool: [32768]u8 = undefined;

// The clay.h pattern: we know EXACTLY how many bytes this system needs.
// 5 strings of 64 bytes = 320 bytes. We add a little overhead for the ArrayList pointers.
const REPL_MEMORY_REQUIREMENT = (MAX_CMD_LEN * HISTORY_SIZE) + 128;

const ReplState = struct {
    allocator: std.mem.Allocator,
    history: std.ArrayList([]const u8), // Zig's dynamic array, but backed by our safe memory!

    pub fn init(allocator: std.mem.Allocator) ReplState {
        return .{
            .allocator = allocator,
            .history = .empty,
        };
    }

    pub fn saveCommand(self: *ReplState, cmd: []const u8) void {
        if (cmd.len == 0) return;

        // Duplicate the string into our memory pool
        const cmd_copy = self.allocator.dupe(u8, cmd) catch return;

        // If history is full, remove the oldest command (FIFO)
        if (self.history.items.len >= HISTORY_SIZE) {
            const old_cmd = self.history.orderedRemove(0);
            self.allocator.free(old_cmd);
        }

        self.history.append(self.allocator, cmd_copy) catch return;
    }

    pub fn printHistory(self: *ReplState) void {
        uart.Terminal.print("\r\n--- Command History ---\r\n");
        for (self.history.items, 0..) |cmd, i| {
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "[{d}] {s}\r\n", .{ i, cmd }) catch continue;
            uart.Terminal.print(msg);
        }
    }
};

// ============================================================================
// COMMAND PARSER
// ============================================================================
fn execute_command(state: *ReplState, cmd: []const u8, window: *Viewport) void {
    if (cmd.len == 0) return;

    // Save every valid command to our FBA-backed history
    state.saveCommand(cmd);

    if (std.mem.eql(u8, cmd, "help")) {
        window.printString("Commands: help, free, history, clear\n");
    } else if (std.mem.eql(u8, cmd, "history")) {
        state.printHistory();
    } else if (std.mem.eql(u8, cmd, "free")) {
        const free_ram = esp_get_free_heap_size();
        var buf: [64]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Free OS Heap: {d} bytes\n", .{free_ram}) catch "";
        window.printString(msg);
    } else if (std.mem.eql(u8, cmd, "clear")) {
        window.printString("\x1B[2J\x1B[H");
    } else {
        window.printString("Unknown command.\n");
    }
}

// ============================================================================
// MAIN TASK
// ============================================================================
export fn app_main() void {
    const ascii_parser = @import("ascii_parser/ascii_parser.zig");
    var parser = ascii_parser.Parser{};
    uart.Terminal.init();
    c.vTaskDelay(50);

    var fba = std.heap.FixedBufferAllocator.init(&os_memory_pool);

    // 3. INJECT THE ALLOCATOR INTO OUR STATE MACHINE
    var repl_state = ReplState.init(fba.allocator());

    uart.Terminal.print("\x1B[2J\x1B[H");
    uart.Terminal.print("Zig Microkernel\r\nzig-cli> ");

    // 🔥 THE BAIT: Interrogate the terminal right before the loop starts!
    // This forces the terminal to reply with its size, triggering your layout engine.
    uart.Terminal.print("\x1B[999;999H\x1B[6n");

    var buffer: [MAX_CMD_LEN]u8 = undefined;
    var buf_len: usize = 0;

    var left_window = Viewport.init(fba.allocator());

    while (true) {
        // 1. Get raw byte from hardware
        if (uart.Terminal.readByte(0xffffffff)) |char| {

            // 2. Transform raw byte into a semantic Event
            if (parser.processByte(char)) |event| {

                // 3. Handle the Event!
                switch (event) {
                    .printable => |letter| {
                        if (buf_len < buffer.len) {
                            buffer[buf_len] = letter;
                            buf_len += 1;
                            left_window.printChar(letter);
                        }
                    },
                    .enter => {
                        left_window.printChar('\n');
                        execute_command(&repl_state, buffer[0..buf_len], &left_window);
                        buf_len = 0;
                        //left_window.printChar('\n');
                        left_window.printString("zig-cli> ");
                    },
                    .backspace => {
                        if (buf_len > 0) {
                            buf_len -= 1;
                            // Tell the Viewport to erase the letter!
                            left_window.backspace();
                        }
                    },
                    .clear_screen => { // The Ctrl+L magic!
                        // uart.Terminal.print("\x1B[2J\x1B[H");
                        // uart.Terminal.print("zig-cli> ");
                        // Re-print whatever they were currently typing
                        left_window.clear();
                        left_window.printString(buffer[0..buf_len]);
                    },
                    .screen_size => |size| {
                        // We just discovered the terminal size!
                        // Let's clear the screen and draw a tiling window layout!
                        uart.Terminal.print("\x1B[2J"); // Clear screen
                        left_window.clear();

                        // Calculate a gap-based layout (The Hyprland signature)
                        const gap = 2;
                        const half_width = (size.cols / 2) - gap;

                        // Draw Left Window (e.g., Rust App)
                        drawWindow(gap, gap, half_width, size.rows - (gap * 2));

                        // Draw Right Window (e.g., OS Logs)
                        drawWindow(half_width + (gap * 2), gap, half_width, size.rows - (gap * 2));

                        // THE RESPONSIVE TRIGGER
                        // This frees the old arrays and perfectly allocates the new ones!
                        const target_x = gap + 1;
                        const target_y = gap + 1;
                        const target_w = half_width - 2;
                        const target_h = (size.rows - (gap * 2)) - 2;

                        left_window.resize(target_x, target_y, target_w, target_h) catch {
                            uart.Terminal.print("OOM Error!\n");
                            continue;
                        };

                        left_window.printString("zig-cli> ");
                    },
                    .up => {
                        uart.Terminal.print("\r\n[TODO: Fetch older history]\r\nzig-cli> ");
                    },
                    .down => {
                        uart.Terminal.print("\r\n[TODO: Fetch newer history]\r\nzig-cli> ");
                    },
                    .left, .right, .swap_window, .unsupported => {
                        // Ignore for now
                    },
                }

                left_window.flush();
            }
        }
    }
}
