// main/uart.zig
const std = @import("std");
const c = @import("../idf_c/idf_c.zig").c;

// ============================================================================
// MANUAL C BINDINGS (Bypassing driver/uart.h)
// ============================================================================
const UART_NUM_0: i32 = 0;

// This perfectly matches the C memory layout of uart_config_t in ESP-IDF
const uart_config_t = extern struct {
    baud_rate: i32,
    data_bits: i32,
    parity: i32,
    stop_bits: i32,
    flow_ctrl: i32,
    rx_flow_ctrl_thresh: u8,
    source_clk: i32,
    flags: u32, // We collapsed the messy C bitfield into a single safe u32!
};

// Declare the external functions.
extern "c" fn uart_param_config(uart_num: i32, uart_config: *const uart_config_t) i32;
extern "c" fn uart_driver_install(uart_num: i32, rx_buffer_size: i32, tx_buffer_size: i32, queue_size: i32, uart_queue: ?*anyopaque, intr_alloc_flags: i32) i32;
extern "c" fn uart_read_bytes(uart_num: i32, buf: [*c]u8, length: u32, ticks_to_wait: u32) i32;
extern "c" fn uart_write_bytes(uart_num: i32, src: [*c]const u8, size: usize) i32;

// ============================================================================
// ZIG TERMINAL WRAPPER
// ============================================================================
pub const Terminal = struct {
    pub fn init() void {
        // NO 'c.' prefix here! We use the local extern struct.
        const config = uart_config_t{
            .baud_rate = 115200,
            .data_bits = 2, // 2 = UART_DATA_8_BITS
            .parity = 0, // 0 = UART_PARITY_DISABLE
            .stop_bits = 1, // 1 = UART_STOP_BITS_1
            .flow_ctrl = 0, // 0 = UART_HW_FLOWCTRL_DISABLE
            .rx_flow_ctrl_thresh = 0,
            .source_clk = 0, // 0 = default clock source
            .flags = 0, // Initialize the bitfield safely to 0
        };

        // NO 'c.' prefixes here either! We call the local extern functions.
        _ = uart_param_config(UART_NUM_0, &config);
        _ = uart_driver_install(UART_NUM_0, 256, 0, 0, null, 0);
    }

    pub fn readByte(timeout_ticks: u32) ?u8 {
        var byte: u8 = 0;
        const bytes_read = uart_read_bytes(UART_NUM_0, &byte, 1, timeout_ticks);
        if (bytes_read > 0) return byte;
        return null;
    }

    pub fn writeByte(byte: u8) void {
        _ = uart_write_bytes(UART_NUM_0, &byte, 1);
    }

    pub fn print(text: []const u8) void {
        _ = uart_write_bytes(UART_NUM_0, text.ptr, text.len);
    }
};
