#pragma once

#include <stdint.h>

#include "dmd_settings.h"
#include "dmd_storage.h"

#define DMD_PLAYBACK_LOG_PATH DMD_STORAGE_LOGS "/playback.log"

void dmd_playback_log_scene(uint16_t scene_index);
void dmd_playback_log_theme(const dmd_settings_t *settings);
