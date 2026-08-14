#pragma once

#include <stdbool.h>
#include <stdint.h>

typedef enum {
    DMD_FONT_BUILTIN_5X7 = 0,
    DMD_FONT_ALTERN8 = 1,
    DMD_FONT_FISHY = 2,
    DMD_FONT_TREK = 3,
    DMD_FONT_TWILIGHT = 4,
    DMD_FONT_COUNT,
} dmd_font_id_t;

bool dmd_font_is_valid(uint8_t id);
const char *dmd_font_name(dmd_font_id_t id);
const char *dmd_font_display_name(dmd_font_id_t id);
bool dmd_font_from_name(const char *name, dmd_font_id_t *font);

void dmd_font_render(
    uint8_t *buffer,
    uint16_t buffer_width,
    uint16_t buffer_height,
    const char *text,
    dmd_font_id_t font,
    int center_x,
    int center_y);

void dmd_font_render_frame(
    uint8_t *buffer,
    uint8_t *mask,
    uint16_t buffer_width,
    uint16_t buffer_height,
    const char *text,
    dmd_font_id_t font,
    int center_x,
    int center_y,
    uint8_t builtin_scale);
