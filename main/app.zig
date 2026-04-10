const std = @import("std");

const idf = @cImport({
    // wint_t isn't injected by musl-mode clang before newlib's sys/_types.h
    @cDefine("wint_t", "unsigned int");
    // riscv pre-includes (from previous fix)
    @cInclude("riscv/rv_utils.h");
    @cInclude("riscv/interrupt.h");
    @cInclude("esp_private/interrupt_intc.h");
    // your actual includes
    @cInclude("freertos/FreeRTOS.h");
    @cInclude("freertos/task.h");
    @cInclude("esp_log.h");
});

const TAG = "ZIG_BOSS";

export fn app_main() void {
    // Note: We use the actual ESP_LOGI style if the macro translated,
    // but calling the underlying function works too.
    // Zig strings are already null-terminated when passed to C in this context.

    idf.esp_log_write(idf.ESP_LOG_INFO, TAG, "Booted directly into Zig app_main!\n");

    var counter: u32 = 0;
    while (true) {
        // Use idf.esp_log_write but note that Zig's @cImport sometimes
        // struggles with C's "..." (varargs).
        // If this line fails, use:
        // idf.esp_rom_printf("Zig running! Count: %d\n", counter);

        idf.esp_log_write(idf.ESP_LOG_INFO, TAG, "Zig is running! Count: %d\n", counter);

        counter += 1;

        // Use the FreeRTOS delay (1000ms / portTICK_PERIOD_MS)
        // Note: idf.portTICK_PERIOD_MS is often a macro that Zig converts to a constant.
        idf.vTaskDelay(1000 / idf.portTICK_PERIOD_MS);
    }
}
