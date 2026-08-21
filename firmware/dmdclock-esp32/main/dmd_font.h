#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define DMD_FONT_BUILTIN_ID "builtin-5x7"
#define DMD_FONT_ID_MAX 48
#define DMD_FONT_NAME_MAX 64
#define DMD_FONT_FILENAME_MAX 128

typedef struct {
    char id[DMD_FONT_ID_MAX];
    char display_name[DMD_FONT_NAME_MAX];
    char filename[DMD_FONT_FILENAME_MAX];
    bool builtin;
} dmd_font_info_t;

bool dmd_font_init(void);
bool dmd_font_init_directory(const char *directory);
size_t dmd_font_count(void);
bool dmd_font_get(size_t index, dmd_font_info_t *info);
bool dmd_font_is_available(const char *id);
const char *dmd_font_canonical_id(const char *id);
bool dmd_font_activate(const char *id);
const char *dmd_font_display_name(const char *id);
const char *dmd_font_active_id(void);
const char *dmd_font_active_display_name(void);
const char *dmd_font_last_error(void);

void dmd_font_render(
    uint8_t *buffer,
    uint16_t buffer_width,
    uint16_t buffer_height,
    const char *text,
    const char *font_id,
    int center_x,
    int center_y);

void dmd_font_render_frame(
    uint8_t *buffer,
    uint8_t *mask,
    uint16_t buffer_width,
    uint16_t buffer_height,
    const char *text,
    const char *font_id,
    int center_x,
    int center_y,
    uint8_t builtin_scale);
