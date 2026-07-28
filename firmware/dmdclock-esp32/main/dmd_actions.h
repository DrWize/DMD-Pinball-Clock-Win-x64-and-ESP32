#pragma once

#include "esp_err.h"

typedef enum {
    DMD_ACTION_COLOR_PREVIOUS,
    DMD_ACTION_COLOR_NEXT,
    DMD_ACTION_TOGGLE_INFORMATION,
    DMD_ACTION_TOGGLE_GLOW,
    DMD_ACTION_SYNC_NTP,
    DMD_ACTION_SCENE_PREVIOUS,
    DMD_ACTION_SCENE_NEXT,
    DMD_ACTION_SHOW_CLOCK,
} dmd_action_t;

esp_err_t dmd_action_execute(dmd_action_t action);
