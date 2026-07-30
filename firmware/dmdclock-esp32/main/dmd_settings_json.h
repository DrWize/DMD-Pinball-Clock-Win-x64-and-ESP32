#pragma once

#include "dmd_settings.h"
#include "esp_err.h"

esp_err_t dmd_settings_json_load(dmd_settings_t *settings);
esp_err_t dmd_settings_json_save(const dmd_settings_t *settings);
