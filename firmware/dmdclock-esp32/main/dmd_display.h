#pragma once

#include <stdbool.h>
#include <stdint.h>

#include "esp_err.h"

typedef struct {
    bool playing_scene;
    bool waiting_for_scene;
    uint16_t scene_index;
    uint16_t scene_step;
    uint16_t scene_frame;
    uint8_t animations_remaining;
    uint8_t plasma_phase;
    uint32_t plasma_frames_rendered;
    uint32_t display_frames_rendered;
    uint32_t schedule_override_seconds_remaining;
    bool touch_test_running;
} dmd_display_state_t;

esp_err_t dmd_display_init(void);
void dmd_display_task(void *context);
void dmd_display_play_scene(uint16_t scene_index);
void dmd_display_show_clock(void);
void dmd_display_start_touch_test(void);
void dmd_display_get_state(dmd_display_state_t *state);
