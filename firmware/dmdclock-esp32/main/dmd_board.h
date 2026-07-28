#pragma once

#include <stdbool.h>
#include <stdint.h>

#include "esp_err.h"

esp_err_t dmd_board_init(void);
bool dmd_board_read_touch(uint16_t *x, uint16_t *y);
bool dmd_board_touch_available(void);
esp_err_t dmd_board_set_sd_enabled(bool enabled);
