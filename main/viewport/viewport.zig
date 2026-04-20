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

    // Initialize with bounds
    pub fn init(x: u16, y: u16, w: u16, h: u16) ViewPort {
        return .{
            .global_x = x,
            .global_y = y,
            .width = w,
            .height = h,
        };
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

        // 3. The Translator: Local -> Global
        const absolute_x = self.global_x + self.local_x;
        const absolute_y = self.global_y + self.local_y;

        // 4. Teleport the physical cursor and print
        var buf: [32]u8 = undefined;
        const cmd = std.fmt.bufPrint(&buf, "\x1B[{d};{d}H{c}", .{ absolute_y, absolute_x, char }) catch return;
        uart.Terminal.print(cmd);

        // 5. Advance our local math
        self.local_x += 1;
    }

    pub fn printString(self: *ViewPort, text: []const u8) void {
        for (text) |c| {
            self.printChar(c);
        }
    }

    pub fn clear(self: *ViewPort) void {
        self.local_x = 0;
        self.local_y = 0;

        // Overwrite the inside of our box with spaces, without touching the borders!
        var buf: [32]u8 = undefined;
        for (0..self.height) |row| {
            const absolute_y = self.global_y + @as(u16, @intCast(row));
            const cmd = std.fmt.bufPrint(&buf, "\x1B[{d};{d}H", .{ absolute_y, self.global_x }) catch return;
            uart.Terminal.print(cmd);

            for (0..self.width) |_| uart.Terminal.print(" ");
        }

        // Put cursor back at Local (0,0)
        const reset_cmd = std.fmt.bufPrint(&buf, "\x1B[{d};{d}H", .{ self.global_y, self.global_x }) catch return;
        uart.Terminal.print(reset_cmd);
    }
};
