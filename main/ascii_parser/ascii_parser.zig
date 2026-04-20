const std = @import("std");

// ============================================================================
// THE DATA MODEL (DOD)
// ============================================================================
// Instead of raw bytes, our OS will now operate on these distinct events.
// This is a "Tagged Union" in Zig. It takes up 2 bytes of memory total.
pub const Event = union(enum) {
    printable: u8,
    enter: void,
    backspace: void,
    clear_screen: void, // Triggered by Ctrl+L
    swap_window: void,
    up: void, // Triggered by ESC [ A
    down: void, // Triggered by ESC [ B
    right: void, // Triggered by ESC [ C
    left: void, // Triggered by ESC [ D
    // THE NEW PAYLOAD: We now pass a struct containing the screen dimensions!
    screen_size: struct { rows: u16, cols: u16 },
    unsupported: void,
};

// The three states our machine can be in
const State = enum {
    normal,
    escape,
    bracket,
    params,
};

// ============================================================================
// THE STATE MACHINE
// ============================================================================
pub const Parser = struct {
    state: State = .normal,
    param_buf: [16]u8 = undefined,
    param_len: usize = 0,

    // Feed one byte at a time. Returns an Event if one is complete, or null if
    // it needs more bytes to finish a sequence.
    pub fn processByte(self: *Parser, b: u8) ?Event {
        switch (self.state) {
            .normal => {
                switch (b) {
                    0x1B => { // ESC character (27)
                        self.state = .escape;
                        return null; // Need More Bytes!
                    },
                    0x0C => return .clear_screen, // Ctrl+L
                    0x17 => return .swap_window,
                    '\r', '\n' => return .enter,
                    8, 127 => return .backspace,
                    32...126 => return .{ .printable = b },
                    else => return null,
                }
            },
            .escape => {
                if (b == '[') {
                    self.state = .bracket;
                    self.param_len = 0; // Clear the number buffer
                } else {
                    // It was an ESC, but not an arrow key sequence.
                    // Reset and ignore.
                    self.state = .normal;
                    return .unsupported;
                }
                return null;
            },
            .bracket, .params => {
                // If its a number or semicolon, we save it
                if ((b >= '0' and b <= '9') or b == ';') {
                    self.state = .params;
                    if (self.param_len < self.param_buf.len) {
                        self.param_buf[self.param_len] = b;
                        self.param_len += 1;
                    }
                    return null; // Keep reading bytes
                } else {
                    // We saw ESC, then [. The next byte determines the arrow!
                    defer self.state = .normal; // Guarantee reset after resolving
                    if (self.state == .bracket) {
                        switch (b) {
                            'A' => return .up,
                            'B' => return .down,
                            'C' => return .right,
                            'D' => return .left,
                            else => return .unsupported, // Could be PageUp, Home, etc.
                        }
                    } else if (self.state == .params and b == 'R') {
                        // It's the 'R' command! A Device Status Report!
                        return self.parseScreenSize();
                    }
                    return .unsupported;
                }
            },
        }
    }
    // DOD Extraction Function
    fn parseScreenSize(self: *Parser) Event {
        // We have something like "24;80" in the buffer. Let's split it.
        const str = self.param_buf[0..self.param_len];
        var iter = std.mem.splitScalar(u8, str, ';');

        const row_str = iter.next() orelse return .unsupported;
        const col_str = iter.next() orelse return .unsupported;

        // Convert the strings to actual integers
        const rows = std.fmt.parseInt(u16, row_str, 10) catch return .unsupported;
        const cols = std.fmt.parseInt(u16, col_str, 10) catch return .unsupported;

        return .{ .screen_size = .{ .rows = rows, .cols = cols } };
    }
};
