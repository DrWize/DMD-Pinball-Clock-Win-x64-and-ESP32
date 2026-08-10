#pragma once

#include <stdbool.h>
#include <stdint.h>

#include "esp_err.h"

typedef enum {
    DMD_SCENE_PACK_IDLE,
    DMD_SCENE_PACK_FETCHING_CATALOG,
    DMD_SCENE_PACK_DOWNLOADING,
    DMD_SCENE_PACK_VERIFYING,
    DMD_SCENE_PACK_EXTRACTING,
    DMD_SCENE_PACK_ACTIVATING,
    DMD_SCENE_PACK_COMPLETE,
    DMD_SCENE_PACK_CANCELLED,
    DMD_SCENE_PACK_FAILED,
} dmd_scene_pack_phase_t;

typedef struct {
    dmd_scene_pack_phase_t phase;
    uint64_t completed_bytes;
    uint64_t total_bytes;
    uint16_t extracted_scenes;
    uint16_t expected_scenes;
    bool running;
    bool cancel_requested;
    bool restart_required;
    char operation[12];
    char message[128];
} dmd_scene_pack_status_t;

esp_err_t dmd_scene_pack_init(void);
esp_err_t dmd_scene_pack_start(const char *operation);
esp_err_t dmd_scene_pack_cancel(void);
void dmd_scene_pack_get_status(dmd_scene_pack_status_t *status);
const char *dmd_scene_pack_phase_name(dmd_scene_pack_phase_t phase);
