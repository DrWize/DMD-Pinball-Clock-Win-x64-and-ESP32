#pragma once

#include "esp_err.h"

typedef enum {
    DMD_ACTION_COLOR_FAMILY_NEXT,
    DMD_ACTION_COLOR_THEME_NEXT,
    DMD_ACTION_TOGGLE_INFORMATION,
    DMD_ACTION_TOGGLE_GLOW,
    DMD_ACTION_SYNC_NTP,
    DMD_ACTION_PINBALL_NEXT,
    DMD_ACTION_SCENE_NEXT,
    DMD_ACTION_SHOW_CLOCK,
    DMD_ACTION_TOUCH_TEST,
    DMD_ACTION_REBOOT,
} dmd_action_t;

esp_err_t dmd_action_execute(dmd_action_t action);
