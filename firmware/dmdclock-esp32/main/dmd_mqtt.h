#pragma once

#include <stdbool.h>
#include <stdint.h>

#include "esp_err.h"

typedef struct {
    bool enabled;
    bool configured;
    bool connected;
    uint32_t connect_count;
    uint32_t disconnect_count;
    uint32_t command_count;
    uint32_t error_count;
} dmd_mqtt_info_t;

esp_err_t dmd_mqtt_init(void);
void dmd_mqtt_get_info(dmd_mqtt_info_t *info);
