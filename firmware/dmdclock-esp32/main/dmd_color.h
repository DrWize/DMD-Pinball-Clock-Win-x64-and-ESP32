#pragma once

#include <stdbool.h>
#include <stdint.h>

typedef enum {
    DMD_COLOR_ORANGE = 0,
    DMD_COLOR_RED = 1,
    DMD_COLOR_PLASMA = 2,
    DMD_COLOR_MONOCHROME = 3,
    DMD_COLOR_NEON_SUNSET = 4,
    DMD_COLOR_CYBER_OCEAN = 5,
    DMD_COLOR_TOXIC_ARCADE = 6,
    DMD_COLOR_VAPORWAVE = 7,
    DMD_COLOR_AURORA = 8,
    DMD_COLOR_C64_BLUE_HALO = 9,
    DMD_COLOR_C64_RED_HALO = 10,
    DMD_COLOR_C64_EARTHTONE = 11,
    DMD_COLOR_C64_METAL = 12,
    DMD_COLOR_C64_INTERLACED_BLUE = 13,
    DMD_COLOR_C64_EXTRUDED_CYAN = 14,
    DMD_COLOR_C64_RAINBOW = 15,
    DMD_COLOR_AMBER = 16,
    DMD_COLOR_GREEN = 17,
    DMD_COLOR_BLUE = 18,
    DMD_COLOR_CYAN = 19,
    DMD_COLOR_MAGENTA = 20,
    DMD_COLOR_FIRESTORM = 21,
    DMD_COLOR_ELECTRIC_VIOLET = 22,
    DMD_COLOR_ARCTIC_GLOW = 23,
    DMD_COLOR_C64_PURPLE_HALO = 24,
    DMD_COLOR_RASTER_GREEN_HALO = 25,
    DMD_COLOR_RASTER_AMBER_HALO = 26,
    DMD_COLOR_RASTER_PURPLE_PULSE = 27,
    DMD_COLOR_RASTER_OCEAN_DEPTH = 28,
    DMD_COLOR_RASTER_SUNSET_BANDS = 29,
    DMD_COLOR_RASTER_FOREST_LAYERS = 30,
    DMD_COLOR_RASTER_ARCTIC_BANDS = 31,
    DMD_COLOR_RASTER_CANDY_STRIPE = 32,
} dmd_color_preset_t;

#define DMD_COLOR_PRESET_MAX DMD_COLOR_RASTER_CANDY_STRIPE

typedef struct {
    uint8_t red;
    uint8_t green;
    uint8_t blue;
} dmd_rgb_t;

bool dmd_color_is_valid(uint8_t preset);
const char *dmd_color_name(dmd_color_preset_t preset);
const char *dmd_color_family(dmd_color_preset_t preset);
dmd_rgb_t dmd_color_at(
    dmd_color_preset_t preset,
    uint8_t x,
    uint8_t y);
