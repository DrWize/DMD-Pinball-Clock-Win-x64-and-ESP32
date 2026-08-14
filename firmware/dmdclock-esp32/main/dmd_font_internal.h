#pragma once

#include <stddef.h>
#include <stdint.h>

typedef struct {
    uint8_t character;
    uint8_t width;
    uint8_t kerning;
    uint16_t offset;
} dmd_font_glyph_t;

typedef struct {
    const char *id;
    const char *display_name;
    const char *source_file;
    const char *source_sha256;
    uint8_t height;
    uint16_t atlas_width;
    uint16_t intensity_stride;
    uint16_t mask_stride;
    uint16_t glyph_count;
    const dmd_font_glyph_t *glyphs;
    const uint8_t *intensities;
    const uint8_t *mask;
} dmd_font_asset_t;
