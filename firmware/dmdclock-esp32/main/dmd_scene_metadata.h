#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "esp_err.h"

#define DMD_SCENE_TITLE_MAX 64
#define DMD_SCENE_GAME_MAX 80
#define DMD_SCENE_MANUFACTURER_MAX 128
#define DMD_SCENE_DISPLAY_NAME_MAX 160
#define DMD_SCENE_SHA256_HEX_LENGTH 64

typedef struct {
    char display_name[DMD_SCENE_DISPLAY_NAME_MAX];
    char title[DMD_SCENE_TITLE_MAX];
    char game[DMD_SCENE_GAME_MAX];
    char manufacturer[DMD_SCENE_MANUFACTURER_MAX];
    uint16_t year;
    bool catalog_match;
    bool intensity_present;
    bool intensity_verified;
    uint16_t intensity_frame_count;
    uint16_t intensity_used_values_mask;
    char intensity_sha256[DMD_SCENE_SHA256_HEX_LENGTH + 1];
    uint8_t intensity_lut[16];
} dmd_scene_metadata_t;

typedef struct dmd_scene_metadata_catalog dmd_scene_metadata_catalog_t;

esp_err_t dmd_scene_metadata_load(dmd_scene_metadata_catalog_t **catalog);
void dmd_scene_metadata_resolve(
    const dmd_scene_metadata_catalog_t *catalog,
    const char *file_name,
    dmd_scene_metadata_t *metadata);
void dmd_scene_metadata_verify_intensity(
    dmd_scene_metadata_t *metadata,
    const uint8_t *scene_data,
    size_t scene_size,
    uint16_t frame_count,
    uint16_t used_values_mask);
void dmd_scene_metadata_free(dmd_scene_metadata_catalog_t *catalog);
