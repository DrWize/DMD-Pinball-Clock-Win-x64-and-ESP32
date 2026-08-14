#include "dmd_font.h"

#include <ctype.h>
#include <limits.h>
#include <stddef.h>
#include <string.h>
#include <strings.h>

#include "dmd_font_internal.h"
#include "generated/dmd_fonts_generated.h"

typedef struct {
    char character;
    uint8_t width;
    uint8_t rows[7];
} builtin_glyph_t;

static const builtin_glyph_t BUILTIN_GLYPHS[] = {
    {'0', 5, {0x1f, 0x11, 0x13, 0x15, 0x19, 0x11, 0x1f}},
    {'1', 5, {0x04, 0x0c, 0x04, 0x04, 0x04, 0x04, 0x0e}},
    {'2', 5, {0x1f, 0x01, 0x01, 0x1f, 0x10, 0x10, 0x1f}},
    {'3', 5, {0x1f, 0x01, 0x01, 0x0f, 0x01, 0x01, 0x1f}},
    {'4', 5, {0x11, 0x11, 0x11, 0x1f, 0x01, 0x01, 0x01}},
    {'5', 5, {0x1f, 0x10, 0x10, 0x1f, 0x01, 0x01, 0x1f}},
    {'6', 5, {0x1f, 0x10, 0x10, 0x1f, 0x11, 0x11, 0x1f}},
    {'7', 5, {0x1f, 0x01, 0x02, 0x04, 0x08, 0x08, 0x08}},
    {'8', 5, {0x1f, 0x11, 0x11, 0x1f, 0x11, 0x11, 0x1f}},
    {'9', 5, {0x1f, 0x11, 0x11, 0x1f, 0x01, 0x01, 0x1f}},
    {':', 1, {0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00}},
    {'.', 1, {0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01}},
    {'-', 3, {0x00, 0x00, 0x00, 0x07, 0x00, 0x00, 0x00}},
    {'/', 5, {0x01, 0x02, 0x02, 0x04, 0x08, 0x08, 0x10}},
    {' ', 3, {0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00}},
    {'A', 5, {0x0e, 0x11, 0x11, 0x1f, 0x11, 0x11, 0x11}},
    {'M', 5, {0x11, 0x1b, 0x15, 0x15, 0x11, 0x11, 0x11}},
    {'P', 5, {0x1e, 0x11, 0x11, 0x1e, 0x10, 0x10, 0x10}},
};

static const builtin_glyph_t *builtin_glyph(char character)
{
    character = (char)toupper((unsigned char)character);
    const builtin_glyph_t *fallback = NULL;
    for (size_t index = 0;
         index < sizeof(BUILTIN_GLYPHS) / sizeof(BUILTIN_GLYPHS[0]);
         index++) {
        if (BUILTIN_GLYPHS[index].character == ' ') {
            fallback = &BUILTIN_GLYPHS[index];
        }
        if (BUILTIN_GLYPHS[index].character == character) {
            return &BUILTIN_GLYPHS[index];
        }
    }
    return fallback;
}

static const dmd_font_asset_t *generated_font(dmd_font_id_t id)
{
    if (id <= DMD_FONT_BUILTIN_5X7 || id >= DMD_FONT_COUNT) {
        return NULL;
    }
    size_t index = (size_t)id - 1;
    return index < dmd_generated_font_count
        ? &dmd_generated_fonts[index]
        : NULL;
}

bool dmd_font_is_valid(uint8_t id)
{
    return id < DMD_FONT_COUNT;
}

const char *dmd_font_name(dmd_font_id_t id)
{
    if (id == DMD_FONT_BUILTIN_5X7) {
        return "builtin-5x7";
    }
    const dmd_font_asset_t *asset = generated_font(id);
    return asset != NULL ? asset->id : "builtin-5x7";
}

const char *dmd_font_display_name(dmd_font_id_t id)
{
    if (id == DMD_FONT_BUILTIN_5X7) {
        return "Built-in 5x7";
    }
    const dmd_font_asset_t *asset = generated_font(id);
    return asset != NULL ? asset->display_name : "Built-in 5x7";
}

bool dmd_font_from_name(const char *name, dmd_font_id_t *font)
{
    if (name == NULL || font == NULL) {
        return false;
    }
    if (strcasecmp(name, "builtin-5x7") == 0) {
        *font = DMD_FONT_BUILTIN_5X7;
        return true;
    }
    for (size_t index = 0; index < dmd_generated_font_count; index++) {
        if (strcasecmp(name, dmd_generated_fonts[index].id) == 0) {
            *font = (dmd_font_id_t)(index + 1);
            return true;
        }
    }
    return false;
}

static void render_builtin(
    uint8_t *buffer,
    uint8_t *mask,
    uint16_t buffer_width,
    uint16_t buffer_height,
    const char *text,
    int center_x,
    int center_y,
    uint8_t requested_scale)
{
    size_t length = strlen(text);
    int base_width = length > 0 ? (int)length - 1 : 0;
    for (size_t index = 0; index < length; index++) {
        base_width += builtin_glyph(text[index])->width;
    }
    int scale = requested_scale;
    if (scale > 4) scale = 4;
    if (scale < 1) scale = 1;
    int cursor_x = center_x - (base_width * scale) / 2;
    int origin_y = center_y - (7 * scale) / 2;

    for (size_t index = 0; index < length; index++) {
        const builtin_glyph_t *glyph = builtin_glyph(text[index]);
        for (int row = 0; row < 7; row++) {
            for (int column = 0; column < glyph->width; column++) {
                uint8_t bit = (uint8_t)(1U << (glyph->width - column - 1));
                if ((glyph->rows[row] & bit) == 0) continue;
                for (int sy = 0; sy < scale; sy++) {
                    int y = origin_y + row * scale + sy;
                    if (y < 0 || y >= buffer_height) continue;
                    for (int sx = 0; sx < scale; sx++) {
                        int x = cursor_x + column * scale + sx;
                        if (x >= 0 && x < buffer_width) {
                            buffer[y * buffer_width + x] = 15;
                            if (mask != NULL) {
                                mask[y * buffer_width + x] = 0;
                            }
                        }
                    }
                }
            }
        }
        cursor_x += (glyph->width + 1) * scale;
    }
}

static const dmd_font_glyph_t *asset_glyph(
    const dmd_font_asset_t *font,
    char character)
{
    uint8_t wanted = (uint8_t)toupper((unsigned char)character);
    for (uint16_t index = 0; index < font->glyph_count; index++) {
        if (font->glyphs[index].character == wanted) {
            return &font->glyphs[index];
        }
    }
    return NULL;
}

static uint8_t fallback_width(char character, uint8_t height)
{
    switch (character) {
        case ' ': return height / 4 > 3 ? height / 4 : 3;
        case '.': return 3;
        case '-': return height / 3 > 5 ? height / 3 : 5;
        case '/': return height / 2 > 7 ? height / 2 : 7;
        default: return height / 4 > 3 ? height / 4 : 3;
    }
}

static uint8_t fallback_intensity(char character, uint8_t width, uint8_t height, int x, int y)
{
    switch (character) {
        case '-': return y == height / 2 && x >= 1 && x < width - 1 ? 15 : 0;
        case '.':
            return x == width / 2 &&
                (y == height - 2 || (height >= 18 && y == height - 3))
                    ? 15 : 0;
        case '/': {
            if (y < 1 || y >= height - 1) return 0;
            int numerator = (width - 3) * y;
            int denominator = height - 2;
            int rounded = numerator / denominator;
            int remainder = numerator % denominator;
            if (remainder * 2 > denominator ||
                (remainder * 2 == denominator && (rounded & 1) != 0)) {
                rounded++;
            }
            int expected_x = width - 2 - rounded;
            return x == expected_x ? 15 : 0;
        }
        default: return 0;
    }
}

static uint8_t asset_intensity(
    const dmd_font_asset_t *font,
    const dmd_font_glyph_t *glyph,
    int x,
    int y)
{
    uint16_t atlas_x = glyph->offset + x;
    uint8_t packed = font->intensities[
        y * font->intensity_stride + atlas_x / 2];
    return atlas_x % 2 == 0 ? packed & 0x0f : (packed >> 4) & 0x0f;
}

static uint8_t asset_mask(
    const dmd_font_asset_t *font,
    const dmd_font_glyph_t *glyph,
    int x,
    int y)
{
    uint16_t atlas_x = glyph->offset + x;
    uint8_t packed = font->mask[y * font->mask_stride + atlas_x / 8];
    return (packed >> (atlas_x % 8)) & 1U;
}

static void render_generated(
    uint8_t *buffer,
    uint8_t *mask,
    uint16_t buffer_width,
    uint16_t buffer_height,
    const char *text,
    const dmd_font_asset_t *font,
    int center_x,
    int center_y)
{
    size_t length = strlen(text);
    int text_width = 0;
    for (size_t index = 0; index < length; index++) {
        const dmd_font_glyph_t *glyph = asset_glyph(font, text[index]);
        uint8_t width = glyph != NULL
            ? glyph->width
            : fallback_width(text[index], font->height);
        uint8_t kerning = glyph != NULL ? glyph->kerning : 1;
        text_width += width;
        if (index + 1 < length) text_width -= kerning;
    }

    int cursor_x = center_x - (text_width + 1) / 2;
    int origin_y = center_y - (font->height + 1) / 2;
    int previous_glyph_end = INT_MIN;
    for (size_t index = 0; index < length; index++) {
        const dmd_font_glyph_t *glyph = asset_glyph(font, text[index]);
        uint8_t width = glyph != NULL
            ? glyph->width
            : fallback_width(text[index], font->height);
        uint8_t kerning = glyph != NULL ? glyph->kerning : 1;
        for (int y = 0; y < font->height; y++) {
            int target_y = origin_y + y;
            if (target_y < 0 || target_y >= buffer_height) continue;
            for (int x = 0; x < width; x++) {
                int target_x = cursor_x + x;
                if (target_x < 0 || target_x >= buffer_width) continue;
                size_t target = (size_t)target_y * buffer_width + target_x;
                uint8_t intensity = glyph != NULL
                    ? asset_intensity(font, glyph, x, y)
                    : fallback_intensity(text[index], width, font->height, x, y);
                buffer[target] = intensity;
                if (mask != NULL) {
                    uint8_t source_mask = glyph != NULL
                        ? asset_mask(font, glyph, x, y)
                        : (intensity == 0 ? 1 : 0);
                    mask[target] = target_x < previous_glyph_end
                        ? mask[target] & source_mask
                        : source_mask;
                }
            }
        }
        previous_glyph_end = cursor_x + width;
        cursor_x += width - kerning;
    }
}

void dmd_font_render(
    uint8_t *buffer,
    uint16_t buffer_width,
    uint16_t buffer_height,
    const char *text,
    dmd_font_id_t font,
    int center_x,
    int center_y)
{
    dmd_font_render_frame(
        buffer,
        NULL,
        buffer_width,
        buffer_height,
        text,
        font,
        center_x,
        center_y,
        3);
}

void dmd_font_render_frame(
    uint8_t *buffer,
    uint8_t *mask,
    uint16_t buffer_width,
    uint16_t buffer_height,
    const char *text,
    dmd_font_id_t font,
    int center_x,
    int center_y,
    uint8_t builtin_scale)
{
    if (buffer == NULL || buffer_width == 0 || buffer_height == 0 || text == NULL) {
        return;
    }
    memset(buffer, 0, (size_t)buffer_width * buffer_height);
    if (mask != NULL) {
        memset(mask, 1, (size_t)buffer_width * buffer_height);
    }
    const dmd_font_asset_t *asset = generated_font(font);
    if (asset == NULL) {
        render_builtin(
            buffer,
            mask,
            buffer_width,
            buffer_height,
            text,
            center_x,
            center_y,
            builtin_scale);
    } else {
        render_generated(
            buffer,
            mask,
            buffer_width,
            buffer_height,
            text,
            asset,
            center_x,
            center_y);
    }
}
