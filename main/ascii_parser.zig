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
    up: void, // Triggered by ESC [ A
    down: void, // Triggered by ESC [ B
    right: void, // Triggered by ESC [ C
    left: void, // Triggered by ESC [ D
    unsupported: void,
};

// The three states our machine can be in
const State = enum {
    normal,
    escape,
    bracket,
};

// ============================================================================
// THE STATE MACHINE
// ============================================================================
pub const Parser = struct {
    state: State = .normal,

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
                    '\r', '\n' => return .enter,
                    8, 127 => return .backspace,
                    32...126 => return .{ .printable = b },
                    else => return null,
                }
            },
            .escape => {
                if (b == '[') {
                    self.state = .bracket;
                } else {
                    // It was an ESC, but not an arrow key sequence.
                    // Reset and ignore.
                    self.state = .normal;
                    return .unsupported;
                }
                return null;
            },
            .bracket => {
                // We saw ESC, then [. The next byte determines the arrow!
                self.state = .normal; // Always reset after resolving
                switch (b) {
                    'A' => return .up,
                    'B' => return .down,
                    'C' => return .right,
                    'D' => return .left,
                    else => return .unsupported, // Could be PageUp, Home, etc.
                }
            },
        }
    }
};
