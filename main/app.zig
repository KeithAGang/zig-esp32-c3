const std = @import("std");
const c = @import("idf_c.zig").c;
const uart = @import("uart.zig");

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

    var buffer: [MAX_CMD_LEN]u8 = undefined;
    var buf_len: usize = 0;

    while (true) {
        if (uart.Terminal.readByte(0xffffffff)) |char| {
            if (char == '\r' or char == '\n') {
                execute_command(&repl_state, buffer[0..buf_len]);
                buf_len = 0;
                uart.Terminal.print("zig-cli> ");
            } else if (char == 8 or char == 127) {
                if (buf_len > 0) {
                    buf_len -= 1;
                    uart.Terminal.print("\x08 \x08");
                }
            } else if (char >= 32 and char <= 126) {
                if (buf_len < buffer.len) {
                    buffer[buf_len] = char;
                    buf_len += 1;
                    uart.Terminal.writeByte(char);
                }
            }
        }
    }
}
