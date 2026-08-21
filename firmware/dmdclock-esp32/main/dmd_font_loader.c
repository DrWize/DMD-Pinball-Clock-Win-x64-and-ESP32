#include "dmd_font_loader.h"

#include <ctype.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef ESP_PLATFORM
#include "esp_heap_caps.h"
#endif

typedef struct {
    const uint8_t *data;
    size_t length;
    size_t offset;
} reader_t;

typedef struct {
    char id[DMD_FONT_ID_MAX];
    char display_name[DMD_FONT_NAME_MAX];
    uint16_t glyph_count;
    dmd_font_glyph_t glyphs[DMD_FONT_GLYPH_MAX];
    uint16_t atlas_width;
    uint8_t height;
    uint16_t intensity_stride;
    uint16_t mask_stride;
    const uint8_t *intensities;
    const uint8_t *mask;
} parsed_font_t;

static void set_error(char *error, size_t capacity, const char *format, ...)
{
    if (error == NULL || capacity == 0) return;
    va_list arguments;
    va_start(arguments, format);
    vsnprintf(error, capacity, format, arguments);
    va_end(arguments);
}

static void *font_alloc(size_t size)
{
#ifdef ESP_PLATFORM
    void *result = heap_caps_malloc(size, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    return result != NULL ? result : malloc(size);
#else
    return malloc(size);
#endif
}

static bool read_bytes(reader_t *reader, size_t count, const uint8_t **value)
{
    if (count > reader->length - reader->offset) return false;
    *value = reader->data + reader->offset;
    reader->offset += count;
    return true;
}

static bool read_u16(reader_t *reader, uint16_t *value)
{
    const uint8_t *bytes;
    if (!read_bytes(reader, 2, &bytes)) return false;
    *value = (uint16_t)(bytes[0] | ((uint16_t)bytes[1] << 8));
    return true;
}

static bool read_7bit_length(reader_t *reader, size_t *value)
{
    size_t result = 0;
    unsigned shift = 0;
    for (unsigned index = 0; index < 5; index++) {
        const uint8_t *byte;
        if (!read_bytes(reader, 1, &byte)) return false;
        if (shift >= sizeof(size_t) * 8 ||
            (size_t)(byte[0] & 0x7f) > (SIZE_MAX >> shift)) {
            return false;
        }
        result |= (size_t)(byte[0] & 0x7f) << shift;
        if ((byte[0] & 0x80) == 0) {
            *value = result;
            return true;
        }
        shift += 7;
    }
    return false;
}

static bool valid_utf8(const uint8_t *text, size_t length)
{
    size_t offset = 0;
    while (offset < length) {
        uint8_t first = text[offset++];
        if (first < 0x80) continue;
        unsigned continuation;
        uint32_t value;
        uint32_t minimum;
        if ((first & 0xe0) == 0xc0) {
            continuation = 1; value = first & 0x1f; minimum = 0x80;
        } else if ((first & 0xf0) == 0xe0) {
            continuation = 2; value = first & 0x0f; minimum = 0x800;
        } else if ((first & 0xf8) == 0xf0) {
            continuation = 3; value = first & 0x07; minimum = 0x10000;
        } else {
            return false;
        }
        if (continuation > length - offset) return false;
        for (unsigned index = 0; index < continuation; index++) {
            uint8_t next = text[offset++];
            if ((next & 0xc0) != 0x80) return false;
            value = (value << 6) | (next & 0x3f);
        }
        if (value < minimum || value > 0x10ffff ||
            (value >= 0xd800 && value <= 0xdfff)) return false;
    }
    return true;
}

static bool normalize_id(
    const uint8_t *name,
    size_t length,
    char output[DMD_FONT_ID_MAX])
{
    size_t written = 0;
    bool separator = false;
    for (size_t index = 0; index < length; index++) {
        uint8_t value = name[index];
        if ((value >= 'A' && value <= 'Z') ||
            (value >= 'a' && value <= 'z') ||
            (value >= '0' && value <= '9')) {
            if (separator && written > 0) {
                if (written + 1 >= DMD_FONT_ID_MAX) return false;
                output[written++] = '-';
            }
            separator = false;
            if (written + 1 >= DMD_FONT_ID_MAX) return false;
            output[written++] = (char)tolower(value);
        } else {
            separator = true;
        }
    }
    output[written] = '\0';
    return written > 0 && strcmp(output, "builtin-5x7") != 0;
}

static bool parse_font(
    const uint8_t *data,
    size_t length,
    parsed_font_t *parsed,
    char *error,
    size_t error_capacity)
{
    memset(parsed, 0, sizeof(*parsed));
    reader_t reader = {.data = data, .length = length};
    uint16_t version;
    if (!read_u16(&reader, &version)) {
        set_error(error, error_capacity, "truncated version");
        return false;
    }
    if (version != 1) {
        set_error(error, error_capacity, "unsupported DotClk version %u", version);
        return false;
    }

    size_t name_length;
    const uint8_t *name;
    if (!read_7bit_length(&reader, &name_length) || name_length == 0 ||
        name_length >= DMD_FONT_NAME_MAX ||
        !read_bytes(&reader, name_length, &name) ||
        !valid_utf8(name, name_length)) {
        set_error(error, error_capacity, "invalid font name");
        return false;
    }
    memcpy(parsed->display_name, name, name_length);
    parsed->display_name[name_length] = '\0';
    if (!normalize_id(name, name_length, parsed->id)) {
        set_error(error, error_capacity, "invalid or reserved font ID");
        return false;
    }

    if (!read_u16(&reader, &parsed->glyph_count) ||
        parsed->glyph_count == 0 || parsed->glyph_count > DMD_FONT_GLYPH_MAX) {
        set_error(error, error_capacity, "invalid glyph count");
        return false;
    }
    bool seen[128] = {false};
    uint32_t atlas_width = 0;
    for (uint16_t index = 0; index < parsed->glyph_count; index++) {
        const uint8_t *character;
        uint16_t width;
        uint16_t kerning;
        if (!read_bytes(&reader, 1, &character) || character[0] >= 0x80 ||
            !read_u16(&reader, &width) || !read_u16(&reader, &kerning)) {
            set_error(error, error_capacity, "invalid ASCII glyph %u", index);
            return false;
        }
        if (seen[character[0]]) {
            set_error(error, error_capacity, "duplicate glyph 0x%02x", character[0]);
            return false;
        }
        if (width == 0 || width > 255 || kerning >= width || kerning > 255 ||
            atlas_width + width > DMD_FONT_ATLAS_WIDTH_MAX) {
            set_error(error, error_capacity, "invalid glyph metrics");
            return false;
        }
        seen[character[0]] = true;
        parsed->glyphs[index] = (dmd_font_glyph_t){
            .character = character[0],
            .width = (uint8_t)width,
            .kerning = (uint8_t)kerning,
            .offset = (uint16_t)atlas_width,
        };
        atlas_width += width;
    }
    static const char REQUIRED[] = "0123456789:AMP";
    for (size_t index = 0; index < sizeof(REQUIRED) - 1; index++) {
        if (!seen[(uint8_t)REQUIRED[index]]) {
            set_error(error, error_capacity, "missing required glyph '%c'", REQUIRED[index]);
            return false;
        }
    }

    uint16_t stored_atlas_width;
    uint16_t height;
    uint16_t bits_per_pixel;
    uint16_t has_mask;
    if (!read_u16(&reader, &stored_atlas_width) ||
        !read_u16(&reader, &height) ||
        !read_u16(&reader, &bits_per_pixel) ||
        !read_u16(&reader, &has_mask) ||
        stored_atlas_width != atlas_width || height == 0 ||
        height > DMD_FONT_HEIGHT_MAX || bits_per_pixel != 4 || has_mask != 1) {
        set_error(error, error_capacity, "invalid atlas header");
        return false;
    }
    parsed->atlas_width = stored_atlas_width;
    parsed->height = (uint8_t)height;
    parsed->intensity_stride = (uint16_t)((stored_atlas_width + 1U) / 2U);
    parsed->mask_stride = (uint16_t)((stored_atlas_width + 7U) / 8U);
    size_t intensity_bytes = (size_t)parsed->intensity_stride * height;
    size_t mask_bytes = (size_t)parsed->mask_stride * height;
    if (!read_bytes(&reader, intensity_bytes, &parsed->intensities) ||
        !read_bytes(&reader, mask_bytes, &parsed->mask)) {
        set_error(error, error_capacity, "truncated atlas payload");
        return false;
    }
    if (reader.offset != reader.length) {
        set_error(error, error_capacity, "unexpected trailing data");
        return false;
    }
    return true;
}

static bool read_file(
    const char *path,
    uint8_t **data,
    size_t *length,
    char *error,
    size_t error_capacity)
{
    FILE *file = fopen(path, "rb");
    if (file == NULL) {
        set_error(error, error_capacity, "unreadable file");
        return false;
    }
    if (fseek(file, 0, SEEK_END) != 0) {
        fclose(file);
        set_error(error, error_capacity, "could not measure file");
        return false;
    }
    long measured = ftell(file);
    if (measured <= 0 || (unsigned long)measured > DMD_FONT_FILE_MAX ||
        fseek(file, 0, SEEK_SET) != 0) {
        fclose(file);
        set_error(error, error_capacity, "file size outside 1..%u bytes", DMD_FONT_FILE_MAX);
        return false;
    }
    *length = (size_t)measured;
    *data = font_alloc(*length);
    if (*data == NULL) {
        fclose(file);
        set_error(error, error_capacity, "out of memory");
        return false;
    }
    size_t read = fread(*data, 1, *length, file);
    int close_result = fclose(file);
    if (read != *length || close_result != 0) {
        free(*data);
        *data = NULL;
        set_error(error, error_capacity, "incomplete file read");
        return false;
    }
    return true;
}

bool dmd_font_loader_inspect(
    const char *path,
    const char *filename,
    dmd_font_catalog_entry_t *entry,
    char *error,
    size_t error_capacity)
{
    if (path == NULL || filename == NULL || entry == NULL ||
        filename[0] == '\0' || strlen(filename) >= DMD_FONT_FILENAME_MAX ||
        strchr(filename, '/') != NULL || strchr(filename, '\\') != NULL ||
        strcmp(filename, ".") == 0 || strcmp(filename, "..") == 0) {
        set_error(error, error_capacity, "invalid filename");
        return false;
    }
    uint8_t *data = NULL;
    size_t length = 0;
    if (!read_file(path, &data, &length, error, error_capacity)) return false;
    parsed_font_t *parsed = font_alloc(sizeof(*parsed));
    if (parsed == NULL) {
        free(data);
        set_error(error, error_capacity, "out of memory parsing font");
        return false;
    }
    bool valid = parse_font(data, length, parsed, error, error_capacity);
    if (valid) {
        memset(entry, 0, sizeof(*entry));
        memcpy(entry->id, parsed->id, sizeof(entry->id));
        memcpy(entry->display_name, parsed->display_name, sizeof(entry->display_name));
        snprintf(entry->filename, sizeof(entry->filename), "%s", filename);
        entry->file_size = length;
    }
    free(parsed);
    free(data);
    return valid;
}

bool dmd_font_loader_load(
    const char *path,
    const dmd_font_catalog_entry_t *entry,
    dmd_font_loaded_t *loaded,
    char *error,
    size_t error_capacity)
{
    if (path == NULL || entry == NULL || loaded == NULL) {
        set_error(error, error_capacity, "invalid load request");
        return false;
    }
    memset(loaded, 0, sizeof(*loaded));
    uint8_t *data = NULL;
    size_t length = 0;
    if (!read_file(path, &data, &length, error, error_capacity)) return false;
    parsed_font_t *parsed = font_alloc(sizeof(*parsed));
    if (parsed == NULL) {
        free(data);
        set_error(error, error_capacity, "out of memory parsing font");
        return false;
    }
    if (!parse_font(data, length, parsed, error, error_capacity) ||
        strcmp(parsed->id, entry->id) != 0 ||
        strcmp(parsed->display_name, entry->display_name) != 0) {
        if (error != NULL && error[0] == '\0') {
            set_error(error, error_capacity, "font changed after boot scan");
        }
        free(parsed);
        free(data);
        return false;
    }
    size_t intensity_bytes = (size_t)parsed->intensity_stride * parsed->height;
    size_t mask_bytes = (size_t)parsed->mask_stride * parsed->height;
    loaded->glyphs = font_alloc((size_t)parsed->glyph_count * sizeof(*loaded->glyphs));
    loaded->intensities = font_alloc(intensity_bytes);
    loaded->mask = font_alloc(mask_bytes);
    if (loaded->glyphs == NULL || loaded->intensities == NULL || loaded->mask == NULL) {
        free(data);
        free(parsed);
        dmd_font_loader_release(loaded);
        set_error(error, error_capacity, "out of memory loading atlas");
        return false;
    }
    memcpy(loaded->glyphs, parsed->glyphs,
        (size_t)parsed->glyph_count * sizeof(*loaded->glyphs));
    memcpy(loaded->intensities, parsed->intensities, intensity_bytes);
    memcpy(loaded->mask, parsed->mask, mask_bytes);
    memcpy(loaded->id, parsed->id, sizeof(loaded->id));
    memcpy(loaded->display_name, parsed->display_name, sizeof(loaded->display_name));
    memcpy(loaded->filename, entry->filename, sizeof(loaded->filename));
    loaded->asset = (dmd_font_asset_t){
        .id = loaded->id,
        .display_name = loaded->display_name,
        .source_file = loaded->filename,
        .source_sha256 = NULL,
        .height = parsed->height,
        .atlas_width = parsed->atlas_width,
        .intensity_stride = parsed->intensity_stride,
        .mask_stride = parsed->mask_stride,
        .glyph_count = parsed->glyph_count,
        .glyphs = loaded->glyphs,
        .intensities = loaded->intensities,
        .mask = loaded->mask,
    };
    free(parsed);
    free(data);
    return true;
}

void dmd_font_loader_release(dmd_font_loaded_t *loaded)
{
    if (loaded == NULL) return;
    free(loaded->glyphs);
    free(loaded->intensities);
    free(loaded->mask);
    memset(loaded, 0, sizeof(*loaded));
}
