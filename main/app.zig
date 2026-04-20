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
fn execute_command(state: *ReplState, cmd: []const u8) void {
    if (cmd.len == 0) return;

    // Save every valid command to our FBA-backed history
    state.saveCommand(cmd);

    if (std.mem.eql(u8, cmd, "help")) {
        uart.Terminal.print("\r\nCommands: help, free, history, clear\r\n");
    } else if (std.mem.eql(u8, cmd, "history")) {
        state.printHistory();
    } else if (std.mem.eql(u8, cmd, "free")) {
        const free_ram = esp_get_free_heap_size();
        var buf: [64]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "\r\nFree OS Heap: {d} bytes\r\n", .{free_ram}) catch "";
        uart.Terminal.print(msg);
    } else if (std.mem.eql(u8, cmd, "clear")) {
        uart.Terminal.print("\x1B[2J\x1B[H");
    } else {
        uart.Terminal.print("\r\nUnknown command.\r\n");
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

    // 1. ALLOCATE THE PHYSICAL SILICON CELLS (The .bss section)
    // We claim exactly what we calculated we need.
    var repl_memory_pool: [REPL_MEMORY_REQUIREMENT]u8 = undefined;

    // 2. WRAP IT IN ZIG'S FBA
    var fba = std.heap.FixedBufferAllocator.init(&repl_memory_pool);

    // 3. INJECT THE ALLOCATOR INTO OUR STATE MACHINE
    var repl_state = ReplState.init(fba.allocator());

    uart.Terminal.print("\x1B[2J\x1B[H");
    uart.Terminal.print("Zig Microkernel\r\nzig-cli> ");

    // 🔥 THE BAIT: Interrogate the terminal right before the loop starts!
    // This forces the terminal to reply with its size, triggering your layout engine.
    uart.Terminal.print("\x1B[999;999H\x1B[6n");

    var buffer: [MAX_CMD_LEN]u8 = undefined;
    var buf_len: usize = 0;

    var left_window = Viewport.init(0, 0, 0, 0);

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
                        execute_command(&repl_state, buffer[0..buf_len]);
                        buf_len = 0;
                        left_window.printChar('\n');
                        left_window.printString("zig-cli> ");
                    },
                    .backspace => {
                        // For now, backspace is tricky with viewports.
                        // Let's just update the buffer memory but leave the visual alone until we add full redrawing.
                        if (buf_len > 0) {
                            buf_len -= 1;
                        }
                    },
                    .clear_screen => { // The Ctrl+L magic!
                        uart.Terminal.print("\x1B[2J\x1B[H");
                        uart.Terminal.print("zig-cli> ");
                        // Re-print whatever they were currently typing
                        uart.Terminal.print(buffer[0..buf_len]);
                    },
                    .screen_size => |size| {
                        // We just discovered the terminal size!
                        // Let's clear the screen and draw a tiling window layout!
                        uart.Terminal.print("\x1B[2J"); // Clear screen

                        // Calculate a gap-based layout (The Hyprland signature)
                        const gap = 2;
                        const half_width = (size.cols / 2) - gap;

                        // Draw Left Window (e.g., Rust App)
                        drawWindow(gap, gap, half_width, size.rows - (gap * 2));

                        // Draw Right Window (e.g., OS Logs)
                        drawWindow(half_width + (gap * 2), gap, half_width, size.rows - (gap * 2));

                        // Park the cursor safely at the bottom
                        //var buf: [32]u8 = undefined;
                        //const park_pos = std.fmt.bufPrint(&buf, "\x1B[{d};0H", .{size.rows}) catch return;
                        //uart.Terminal.print(park_pos);

                        // Configure the Viewport
                        // Start +1 inside the border, and make it -2 smaller than the border
                        left_window.global_x = gap + 1;
                        left_window.global_y = gap + 1;
                        left_window.width = half_width - 2;
                        left_window.height = (size.rows - (gap * 2)) - 2;

                        // Reset its local state and print the prompt inside the box
                        left_window.clear();
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
            }
        }
    }
}
