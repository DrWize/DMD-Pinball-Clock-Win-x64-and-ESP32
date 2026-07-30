#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "esp_err.h"
#include "dmd_scene_metadata.h"

#define DMD_SCENE_PIXEL_COUNT (128 * 32)
#define DMD_QEMU_SCENE_COUNT 11
#define DMD_SCENE_MAX_COUNT 4096
#define DMD_SCENE_FILE_NAME_MAX 64

typedef struct {
    uint16_t index;
    uint16_t frame_count;
    uint16_t step_count;
    uint16_t first_delay_ms;
    uint16_t normal_delay_ms;
    uint16_t final_hold_ms;
    bool clock_above_first;
    bool blank_first;
    bool clock_above_frames;
    bool clock_above_last;
    bool blank_last;
    uint8_t clock_style;
    uint8_t clock_x;
    uint8_t clock_y;
    size_t source_size;
    char file_name[DMD_SCENE_FILE_NAME_MAX];
    char display_name[DMD_SCENE_DISPLAY_NAME_MAX];
} dmd_scene_info_t;

typedef struct {
    uint16_t frame_index;
    uint16_t duration_ms;
    bool blank;
    bool clock_above;
} dmd_scene_step_info_t;

esp_err_t dmd_scene_init(void);
esp_err_t dmd_scene_select(uint16_t index);
uint16_t dmd_scene_count(void);
const char *dmd_scene_file_name(uint16_t index);
const char *dmd_scene_display_name(uint16_t index);
void dmd_scene_get_metadata(uint16_t index, dmd_scene_metadata_t *metadata);
uint16_t dmd_scene_next_game(uint16_t current);
uint16_t dmd_scene_next_in_game(uint16_t current);
void dmd_scene_get_info(dmd_scene_info_t *info);
esp_err_t dmd_scene_decode_step(
    uint16_t step,
    uint8_t output[DMD_SCENE_PIXEL_COUNT],
    uint8_t mask[DMD_SCENE_PIXEL_COUNT],
    dmd_scene_step_info_t *step_info);
