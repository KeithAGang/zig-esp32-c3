const std = @import("std");

// Import the ESP-IDF headers directly!
const idf = @cImport({
    @cInclude("freertos/FreeRTOS.h");
    @cInclude("freertos/task.h");
    @cInclude("esp_log.h");
});

const TAG = "ZIG_BOSS";

// This replaces main.c entirely
export fn app_main() void {
    idf.esp_log_write(idf.ESP_LOG_INFO, TAG, "Booted directly into Zig app_main!\n");

    var counter: u32 = 0;
    while (true) {
        idf.esp_log_write(idf.ESP_LOG_INFO, TAG, "Zig is running! Count: %lu\n", counter);
        counter += 1;

        // Use the imported FreeRTOS delay
        idf.vTaskDelay(100);
    }
}
