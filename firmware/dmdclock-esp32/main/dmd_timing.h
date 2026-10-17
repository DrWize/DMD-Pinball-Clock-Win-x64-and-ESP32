#pragma once
#include <stdbool.h>
#include <stdint.h>
#include "dmd_scene.h"
#include "dmd_settings.h"

typedef struct {
    bool enabled;
    bool active;
    bool detailed;
    uint32_t steps;
} dmd_timing_status_t;

bool dmd_timing_handle_line(char *line);
void dmd_timing_get_status(dmd_timing_status_t *out);
bool dmd_timing_enabled(void);
void dmd_timing_apply_settings(dmd_settings_t *settings);
void dmd_timing_step(uint16_t step, const dmd_scene_step_info_t *info, int64_t loop, int64_t decoded);
void dmd_timing_painted(int64_t now);
void dmd_timing_finished(int64_t now);
