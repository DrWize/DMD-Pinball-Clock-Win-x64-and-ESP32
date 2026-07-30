#pragma once

#include <stdbool.h>
#include <stdint.h>

#include "esp_err.h"

typedef struct {
    bool available;
    uint32_t event_count;
    uint32_t read_error_count;
    uint32_t last_event_ms;
    uint16_t last_x;
    uint16_t last_y;
    uint8_t last_status;
    int interrupt_level;
} dmd_touch_diagnostics_t;

esp_err_t dmd_board_init(void);
bool dmd_board_read_touch(uint16_t *x, uint16_t *y);
bool dmd_board_touch_available(void);
void dmd_board_get_touch_diagnostics(dmd_touch_diagnostics_t *diagnostics);
esp_err_t dmd_board_set_sd_enabled(bool enabled);
