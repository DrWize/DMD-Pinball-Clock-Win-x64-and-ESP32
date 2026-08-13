#pragma once

#include <stdbool.h>
#include <stdint.h>

#include "esp_err.h"

esp_err_t dmd_panel_init(void);
int dmd_panel_width(void);
int dmd_panel_height(void);
uint16_t *dmd_panel_begin_frame(void);
esp_err_t dmd_panel_present(void);
esp_err_t dmd_panel_set_backlight(bool enabled);
