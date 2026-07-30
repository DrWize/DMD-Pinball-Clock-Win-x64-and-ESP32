#pragma once

#include <stdbool.h>
#include <stdint.h>

#include "esp_err.h"

typedef struct {
    bool chip_temperature_available;
    float chip_temperature_c;
    bool wifi_rssi_available;
    int8_t wifi_rssi_dbm;
    uint32_t free_heap_bytes;
    uint32_t minimum_free_heap_bytes;
    uint32_t free_psram_bytes;
    uint32_t total_psram_bytes;
    bool sd_available;
    uint64_t sd_total_bytes;
    uint64_t sd_free_bytes;
    bool settings_file_present;
    uint32_t flash_size_bytes;
    uint16_t cpu_frequency_mhz;
    uint32_t boot_count;
    const char *reset_reason;
    esp_err_t last_nvs_save_error;
    esp_err_t last_sd_save_error;
} dmd_diagnostics_t;

esp_err_t dmd_diagnostics_init(void);
void dmd_diagnostics_get(dmd_diagnostics_t *diagnostics);
