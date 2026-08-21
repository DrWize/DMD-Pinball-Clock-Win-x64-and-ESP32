#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "dmd_font.h"
#include "dmd_font_internal.h"

#define DMD_FONT_CATALOG_MAX 32
#define DMD_FONT_FILE_MAX (96U * 1024U)
#define DMD_FONT_GLYPH_MAX 256
#define DMD_FONT_ATLAS_WIDTH_MAX 4096
#define DMD_FONT_HEIGHT_MAX 32
#define DMD_FONT_ERROR_MAX 96

typedef struct {
    char id[DMD_FONT_ID_MAX];
    char display_name[DMD_FONT_NAME_MAX];
    char filename[DMD_FONT_FILENAME_MAX];
    size_t file_size;
} dmd_font_catalog_entry_t;

typedef struct {
    dmd_font_asset_t asset;
    char id[DMD_FONT_ID_MAX];
    char display_name[DMD_FONT_NAME_MAX];
    char filename[DMD_FONT_FILENAME_MAX];
    dmd_font_glyph_t *glyphs;
    uint8_t *intensities;
    uint8_t *mask;
} dmd_font_loaded_t;

bool dmd_font_loader_inspect(
    const char *path,
    const char *filename,
    dmd_font_catalog_entry_t *entry,
    char *error,
    size_t error_capacity);

bool dmd_font_loader_load(
    const char *path,
    const dmd_font_catalog_entry_t *entry,
    dmd_font_loaded_t *loaded,
    char *error,
    size_t error_capacity);

void dmd_font_loader_release(dmd_font_loaded_t *loaded);
