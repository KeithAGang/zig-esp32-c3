const std = @import("std");
const uart = @import("../uart/uart.zig");

pub const ViewPort = struct {
    // Global space (The physical monitor)
    global_x: u16 = 0,
    global_y: u16 = 0,

    // The Box limits
    width: u16 = 0,
    height: u16 = 0,

    // Local space (Tenant's Cursor)
    local_x: u16 = 0,
    local_y: u16 = 0,

    // RESPONSIVE MEMORY: Zig Slices instead of fixed arrays
    current_buf: []u8 = &[_]u8{},
    prev_buf: []u8 = &[_]u8{},
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ViewPort {
        return .{
            .allocator = allocator,
        };
    }

    // THE RESIZER: Call this whenever clay.h changes the window size!
    pub fn resize(self: *ViewPort, x: u16, y: u16, new_w: u16, new_h: u16) !void {
        self.global_x = x;
        self.global_y = y;

        // If the size didn't change, just clear it and return
        if (self.width == new_w and self.height == new_h) {
            self.clear();

            if (self.prev_buf.len > 0) @memset(self.prev_buf, ' ');
            return;
        }

        // 1. Free the old memory to prevent leaks
        if (self.current_buf.len > 0) {
            self.allocator.free(self.current_buf);
            self.allocator.free(self.prev_buf);
        }

        // 2. Ask the FBA for exact new memory size (Width * Height)
        const size = @as(usize, new_w) * @as(usize, new_h);
        self.current_buf = try self.allocator.alloc(u8, size);
        self.prev_buf = try self.allocator.alloc(u8, size);

        self.width = new_w;
        self.height = new_h;
        self.local_x = 0;
        self.local_y = 0;

        // 3. Fill current with spaces, prev with 0 (to force a full redraw on next flush)
        @memset(self.current_buf, ' ');
        @memset(self.prev_buf, ' ');
    }

    // Helper function to find the 1D index for a 2D coordinate
    fn getIdx(self: *ViewPort, x: u16, y: u16) usize {
        return (@as(usize, y) * @as(usize, self.width)) + @as(usize, x);
    }

    pub fn newLine(self: *ViewPort) void {
        // Snap back to the left edge of OUR Box
        self.local_x = 0;
        // Move down the line in OUR Box
        self.local_y += 1;

        // If we hit the bottom of our box, wrap back to the top for now.
        // (Later, we will implement full scrolling here)
        if (self.local_y >= self.height) {
            self.local_y = 0;
            self.clear(); // Wipe the inside of the box clean
        }
    }

    pub fn printChar(self: *ViewPort, char: u8) void {
        // 1. Handle the `ENTER` key
        if (char == '\n' or char == '\r') {
            self.newLine();
            return;
        }

        // 2. The Typewriter Bell: If we hit the right edge of our box, wrap!
        if (self.local_x >= self.width) {
            self.newLine();
        }

        // Save to the 1D slice!
        if (self.current_buf.len > 0) {
            self.current_buf[self.getIdx(self.local_x, self.local_y)] = char;
            self.local_x += 1;
        }
    }

    pub fn printString(self: *ViewPort, text: []const u8) void {
        for (text) |c| {
            self.printChar(c);
        }
    }

    pub fn backspace(self: *ViewPort) void {
        // Only backspace if we aren't at the very left edge
        if (self.local_x > 0) {
            self.local_x -= 1;
            // Overwrite the character in our RAM slice with a space
            self.current_buf[self.getIdx(self.local_x, self.local_y)] = ' ';
        }
    }

    pub fn clear(self: *ViewPort) void {
        self.local_x = 0;
        self.local_y = 0;

        if (self.current_buf.len > 0) {
            @memset(self.current_buf, ' '); // Instantly wipes the RAM buffer
        }
    }

    pub fn flush(self: *ViewPort) void {
        if (self.current_buf.len == 0) return;
        var buf: [32]u8 = undefined;

        for (0..self.height) |y| {
            for (0..self.width) |x| {
                const idx = self.getIdx(@intCast(x), @intCast(y));
                const current_char = self.current_buf[idx];
                const prev_char = self.prev_buf[idx];

                if (current_char != prev_char) {
                    const absolute_x = self.global_x + @as(u16, @intCast(x));
                    const absolute_y = self.global_y + @as(u16, @intCast(y));

                    const cmd = std.fmt.bufPrint(&buf, "\x1B[{d};{d}H{c}", .{ absolute_y, absolute_x, current_char }) catch continue;
                    uart.Terminal.print(cmd);

                    self.prev_buf[idx] = current_char;
                }
            }
        }
    }
};
