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

const TAG = "DOD_Hydro";

// 1. DATA DEFINITIONS (The Shape of our System)
// ============================================================================

// The raw data coming from the outside world.
const SensorSnapshot = extern struct {
    ph_value: f32,
    tick_timestamp: u32,
};

// The explicit commands our system can generate.
// We use a strictly typed enum rather than boolean flags.
const PumpCommand = enum(u8) {
    StartPumping,
    WaitAndRest,
    SystemIdle,
};

// Global queue handle. This is the pipeline connecting our transforms.
var sensor_queue: idf.QueueHandle_t = null;

// ============================================================================
// 2. PURE DATA TRANSFORMATIONS (The Logic)
// ============================================================================
// Notice this function does NOT touch hardware, Queues, or RTOS APIs.
// It takes data in, and returns data out. It is trivially unit-testable.

fn evaluate_hydroponics_policy(ph: f32) PumpCommand {
    if (ph >= 4.5 and ph <= 6.0) {
        return .StartPumping;
    }

    return .SystemIdle;
}

fn read_hardware_ph() f32 {
    const values = [6]f32{ 3.3, 5.2, 4.5, 6.0, 5.7, 7.9 };
    const tick = asm volatile ("csrr %[ret], mcycle"
        : [ret] "=r" (-> u32),
    );
    return values[tick % 6];
}

// ============================================================================
// 3. SYSTEM NODES (The FreeRTOS Tasks that route the data)
// ============================================================================

// SYSTEM A: Data Ingestion
// Goal: Translate physical world -> SensorSnapshot -> Push to Queue
export fn ingest_system_task(arg: ?*anyopaque) callconv(.c) void {
    _ = arg;
    const sample_rate_ticks = 10000 / idf.portTICK_PERIOD_MS; // 10 seconds

    while (true) {
        var snapshot = SensorSnapshot{ .ph_value = read_hardware_ph(), .tick_timestamp = idf.xTaskGetTickCount() };

        // Push data into the pipeline. Pass-by-copy means the downstream system
        // owns this data completely once it's in the queue.
        if (idf.xQueueSend(sensor_queue, &snapshot, 0) != idf.pdPASS) {
            idf.esp_log_write(idf.ESP_LOG_ERROR, TAG, "Pipeline congested! Dropped snapshot.\n");
        }

        idf.vTaskDelay(sample_rate_ticks);
    }
}

// SYSTEM B: Logic & Actuation
// Goal: Pull SensorSnapshot -> Transform via pure logic -> Execute Hardware Action
export fn actuator_system_task(arg: ?*anyopaque) callconv(.c) void {
    _ = arg;
    var current_snapshot: SensorSnapshot = undefined;

    const pump_duration_ticks = 20000 / idf.portTICK_PERIOD_MS;
    const rest_duration_ticks = 40000 / idf.portTICK_PERIOD_MS;
    const idle_duration_ticks = 60000 / idf.portTICK_PERIOD_MS;

    while (true) {
        // Block until new data arrives in the pipeline.
        if (idf.xQueueReceive(sensor_queue, &current_snapshot, idf.portMAX_DELAY) == idf.pdTRUE) {

            // 1. Transform raw data into an actionable command
            const command = evaluate_hydroponics_policy(current_snapshot.ph_value);

            // 2. Execute the hardware mapping based purely on the data command
            switch (command) {
                .StartPumping => {
                    idf.esp_log_write(idf.ESP_LOG_INFO, TAG, "Cmd: StartPumping (pH %.2f)\n", current_snapshot.ph_value);
                    // GPIO ON
                    idf.vTaskDelay(pump_duration_ticks);

                    idf.esp_log_write(idf.ESP_LOG_INFO, TAG, "Cmd: WaitAndRest\n");
                    // GPIO OFF
                    idf.vTaskDelay(rest_duration_ticks);
                },
                .SystemIdle, .WaitAndRest => {
                    idf.esp_log_write(idf.ESP_LOG_WARN, TAG, "Cmd: SystemIdle (pH %.2f)\n", current_snapshot.ph_value);
                    // GPIO OFF
                    idf.vTaskDelay(idle_duration_ticks);
                },
            }
        }
    }
}

// ============================================================================
// 4. MAIN ENTRY (Wiring the pipeline together)
// ============================================================================
export fn app_main() void {
    idf.esp_log_write(idf.ESP_LOG_INFO, "SYSTEM", "Booting DOD Pipeline...\n");

    // Allocate the pipeline buffer (Queue of 5 snapshots)
    sensor_queue = idf.xQueueCreate(5, @sizeOf(SensorSnapshot));
    if (sensor_queue == null) {
        idf.esp_log_write(idf.ESP_LOG_ERROR, "SYSTEM", "Failed to allocate pipeline.\n");
        return;
    }

    // Spawn the discrete processing nodes
    _ = idf.xTaskCreate(ingest_system_task, "ingest_node", 4096, null, 4, null);
    _ = idf.xTaskCreate(actuator_system_task, "actuator_node", 4096, null, 5, null);

    idf.vTaskDelete(null);
}
