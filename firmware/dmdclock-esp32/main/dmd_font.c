#include "dmd_font.h"

#include <ctype.h>
#include <dirent.h>
#include <limits.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <string.h>
#include <strings.h>

#include "dmd_font_loader.h"
#include "dmd_font_internal.h"

#ifdef ESP_PLATFORM
#include "dmd_storage.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
static const char *TAG = "dmd_font";
static SemaphoreHandle_t s_font_lock;
#define FONT_LOCK() xSemaphoreTake(s_font_lock, portMAX_DELAY)
#define FONT_UNLOCK() xSemaphoreGive(s_font_lock)
#define FONT_LOGI(...) ESP_LOGI(TAG, __VA_ARGS__)
#define FONT_LOGW(...) ESP_LOGW(TAG, __VA_ARGS__)
#else
#define FONT_LOCK() ((void)0)
#define FONT_UNLOCK() ((void)0)
#define FONT_LOGI(...) ((void)0)
#define FONT_LOGW(...) ((void)0)
#endif

#define DMD_FONT_SCAN_MAX 128
#define DMD_FONT_DIRECTORY_MAX 320
#define DMD_FONT_PATH_MAX 512

typedef struct {
    char filename[DMD_FONT_FILENAME_MAX];
} font_candidate_t;

static dmd_font_catalog_entry_t s_catalog[DMD_FONT_CATALOG_MAX];
static size_t s_catalog_count;
static dmd_font_loaded_t s_loaded;
static char s_font_directory[DMD_FONT_DIRECTORY_MAX];
static char s_active_id[DMD_FONT_ID_MAX] = DMD_FONT_BUILTIN_ID;
static char s_active_name[DMD_FONT_NAME_MAX] = "Built-in 5x7";
static char s_last_error[DMD_FONT_ERROR_MAX];

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

static int compare_candidates(const void *left, const void *right)
{
    const font_candidate_t *a = left;
    const font_candidate_t *b = right;
    return strcasecmp(a->filename, b->filename);
}

static int compare_catalog(const void *left, const void *right)
{
    const dmd_font_catalog_entry_t *a = left;
    const dmd_font_catalog_entry_t *b = right;
    int by_name = strcasecmp(a->display_name, b->display_name);
    return by_name != 0 ? by_name : strcasecmp(a->filename, b->filename);
}

static bool font_filename(const char *name)
{
    size_t length = strlen(name);
    if (length <= 4 || length >= DMD_FONT_FILENAME_MAX ||
        name[0] == '.' || name[0] == '~' ||
        strcasecmp(name + length - 4, ".fnt") != 0) return false;
    return strstr(name, ".tmp.") == NULL && strstr(name, ".part.") == NULL;
}

static const dmd_font_catalog_entry_t *catalog_entry(const char *id)
{
    if (id == NULL) return NULL;
    for (size_t index = 0; index < s_catalog_count; index++) {
        if (strcasecmp(id, s_catalog[index].id) == 0) return &s_catalog[index];
    }
    return NULL;
}

bool dmd_font_init_directory(const char *directory)
{
#ifdef ESP_PLATFORM
    if (s_font_lock == NULL) {
        s_font_lock = xSemaphoreCreateMutex();
        if (s_font_lock == NULL) return false;
    }
#endif
    s_catalog_count = 0;
    s_last_error[0] = '\0';
    if (directory == NULL || strlen(directory) >= sizeof(s_font_directory)) {
        snprintf(s_last_error, sizeof(s_last_error), "Invalid font directory");
        return false;
    }
    snprintf(s_font_directory, sizeof(s_font_directory), "%s", directory);

    DIR *opened = opendir(directory);
    if (opened == NULL) {
        FONT_LOGW("Font directory %s is unavailable; using built-in 5x7", directory);
        return true;
    }

    font_candidate_t *candidates = calloc(DMD_FONT_SCAN_MAX, sizeof(*candidates));
    if (candidates == NULL) {
        closedir(opened);
        snprintf(s_last_error, sizeof(s_last_error), "Out of memory scanning fonts");
        return false;
    }
    size_t candidate_count = 0;
    struct dirent *item;
    while ((item = readdir(opened)) != NULL) {
        if (!font_filename(item->d_name)) continue;
        size_t filename_length = strlen(item->d_name);
        if (filename_length >= sizeof(candidates[0].filename)) continue;
        char path[DMD_FONT_PATH_MAX];
        int length = snprintf(path, sizeof(path), "%s/%s", directory, item->d_name);
        struct stat status;
        if (length <= 0 || (size_t)length >= sizeof(path) ||
            stat(path, &status) != 0 || !S_ISREG(status.st_mode)) continue;
        if (candidate_count >= DMD_FONT_SCAN_MAX) {
            FONT_LOGW("Font scan limit %u reached; remaining entries skipped", DMD_FONT_SCAN_MAX);
            break;
        }
        memcpy(
            candidates[candidate_count].filename,
            item->d_name,
            filename_length + 1);
        candidate_count++;
    }
    closedir(opened);
    qsort(candidates, candidate_count, sizeof(*candidates), compare_candidates);

    dmd_font_catalog_entry_t *valid = calloc(DMD_FONT_SCAN_MAX, sizeof(*valid));
    if (valid == NULL) {
        free(candidates);
        snprintf(s_last_error, sizeof(s_last_error), "Out of memory validating fonts");
        return false;
    }
    size_t valid_count = 0;
    for (size_t index = 0; index < candidate_count; index++) {
        char path[DMD_FONT_PATH_MAX];
        snprintf(path, sizeof(path), "%s/%s", directory, candidates[index].filename);
        char reason[DMD_FONT_ERROR_MAX] = {0};
        dmd_font_catalog_entry_t entry;
        if (!dmd_font_loader_inspect(
                path, candidates[index].filename, &entry, reason, sizeof(reason))) {
            FONT_LOGW("Rejected font %s: %s", candidates[index].filename, reason);
            continue;
        }
        valid[valid_count++] = entry;
    }
    free(candidates);
    qsort(valid, valid_count, sizeof(*valid), compare_catalog);
    for (size_t index = 0; index < valid_count; index++) {
        bool duplicate = false;
        for (size_t accepted = 0; accepted < s_catalog_count; accepted++) {
            if (strcasecmp(valid[index].id, s_catalog[accepted].id) == 0) {
                FONT_LOGW("Rejected duplicate font ID %s from %s; keeping %s",
                    valid[index].id, valid[index].filename,
                    s_catalog[accepted].filename);
                duplicate = true;
                break;
            }
        }
        if (duplicate) continue;
        if (s_catalog_count >= DMD_FONT_CATALOG_MAX) {
            FONT_LOGW("Valid font catalog limit %u reached; %s skipped",
                DMD_FONT_CATALOG_MAX, valid[index].filename);
            continue;
        }
        s_catalog[s_catalog_count++] = valid[index];
    }
    free(valid);
    FONT_LOGI("Discovered %u valid SD font(s) in %s",
        (unsigned)s_catalog_count, directory);
    return true;
}

bool dmd_font_init(void)
{
#ifdef ESP_PLATFORM
    if (!dmd_storage_available()) {
        FONT_LOGI("No SD storage; using built-in 5x7 font");
        return dmd_font_init_directory(DMD_STORAGE_FONTS);
    }
    return dmd_font_init_directory(DMD_STORAGE_FONTS);
#else
    return dmd_font_init_directory("fonts");
#endif
}

size_t dmd_font_count(void)
{
    return s_catalog_count + 1;
}

bool dmd_font_get(size_t index, dmd_font_info_t *info)
{
    if (info == NULL || index >= dmd_font_count()) return false;
    memset(info, 0, sizeof(*info));
    if (index == 0) {
        snprintf(info->id, sizeof(info->id), "%s", DMD_FONT_BUILTIN_ID);
        snprintf(info->display_name, sizeof(info->display_name), "Built-in 5x7");
        info->builtin = true;
        return true;
    }
    const dmd_font_catalog_entry_t *entry = &s_catalog[index - 1];
    memcpy(info->id, entry->id, sizeof(info->id));
    memcpy(info->display_name, entry->display_name, sizeof(info->display_name));
    memcpy(info->filename, entry->filename, sizeof(info->filename));
    return true;
}

bool dmd_font_is_available(const char *id)
{
    return dmd_font_canonical_id(id) != NULL;
}

const char *dmd_font_canonical_id(const char *id)
{
    if (id == NULL) return NULL;
    if (strcasecmp(id, DMD_FONT_BUILTIN_ID) == 0) return DMD_FONT_BUILTIN_ID;
    const dmd_font_catalog_entry_t *entry = catalog_entry(id);
    return entry != NULL ? entry->id : NULL;
}

bool dmd_font_activate(const char *id)
{
    if (id == NULL) return false;
    if (strcasecmp(id, DMD_FONT_BUILTIN_ID) == 0) {
        FONT_LOCK();
        dmd_font_loaded_t previous = s_loaded;
        memset(&s_loaded, 0, sizeof(s_loaded));
        snprintf(s_active_id, sizeof(s_active_id), "%s", DMD_FONT_BUILTIN_ID);
        snprintf(s_active_name, sizeof(s_active_name), "Built-in 5x7");
        s_last_error[0] = '\0';
        FONT_UNLOCK();
        dmd_font_loader_release(&previous);
        return true;
    }
    const dmd_font_catalog_entry_t *entry = catalog_entry(id);
    if (entry == NULL) {
        snprintf(s_last_error, sizeof(s_last_error), "Requested font is unavailable");
        return false;
    }
    char path[DMD_FONT_PATH_MAX];
    snprintf(path, sizeof(path), "%s/%s", s_font_directory, entry->filename);
    dmd_font_loaded_t candidate;
    char reason[DMD_FONT_ERROR_MAX] = {0};
    FONT_LOGI("Loading SD font %s from %s", entry->id, path);
    if (!dmd_font_loader_load(path, entry, &candidate, reason, sizeof(reason))) {
        snprintf(s_last_error, sizeof(s_last_error), "%s", reason);
        FONT_LOGW("Could not activate font %s: %s", entry->filename, reason);
        return false;
    }
    FONT_LOGI("Loaded SD font %s; waiting to activate", entry->id);
    FONT_LOCK();
    dmd_font_loaded_t previous = s_loaded;
    s_loaded = candidate;
    s_loaded.asset.id = s_loaded.id;
    s_loaded.asset.display_name = s_loaded.display_name;
    s_loaded.asset.source_file = s_loaded.filename;
    s_loaded.asset.glyphs = s_loaded.glyphs;
    s_loaded.asset.intensities = s_loaded.intensities;
    s_loaded.asset.mask = s_loaded.mask;
    snprintf(s_active_id, sizeof(s_active_id), "%s", entry->id);
    snprintf(s_active_name, sizeof(s_active_name), "%s", entry->display_name);
    s_last_error[0] = '\0';
    FONT_UNLOCK();
    FONT_LOGI("SD font %s activation swap completed", entry->id);
    dmd_font_loader_release(&previous);
    FONT_LOGI("Activated SD font %s from %s", entry->display_name, entry->filename);
    return true;
}

const char *dmd_font_display_name(const char *id)
{
    if (id != NULL && strcasecmp(id, DMD_FONT_BUILTIN_ID) == 0) {
        return "Built-in 5x7";
    }
    const dmd_font_catalog_entry_t *entry = catalog_entry(id);
    return entry != NULL ? entry->display_name : "Built-in 5x7";
}

const char *dmd_font_active_id(void)
{
    return s_active_id;
}

const char *dmd_font_active_display_name(void)
{
    return s_active_name;
}

const char *dmd_font_last_error(void)
{
    return s_last_error;
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
    const char *font_id,
    int center_x,
    int center_y)
{
    dmd_font_render_frame(
        buffer,
        NULL,
        buffer_width,
        buffer_height,
        text,
        font_id,
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
    const char *font_id,
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
    FONT_LOCK();
    const dmd_font_asset_t *asset =
        font_id != NULL && strcasecmp(font_id, s_active_id) == 0 &&
        s_loaded.asset.glyphs != NULL
            ? &s_loaded.asset
            : NULL;
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
    FONT_UNLOCK();
}
