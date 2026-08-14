#pragma once

#include <stdbool.h>
#include <stdint.h>

#include "esp_err.h"

esp_err_t dmd_panel_init(void);
int dmd_panel_width(void);
int dmd_panel_height(void);
uint16_t *dmd_panel_begin_frame(void);
esp_err_t dmd_panel_present(uint16_t rotation);
esp_err_t dmd_panel_set_backlight(bool enabled);
bool dmd_panel_orientation_sensor_available(void);
bool dmd_panel_read_accelerometer(float *x, float *y, float *z);
