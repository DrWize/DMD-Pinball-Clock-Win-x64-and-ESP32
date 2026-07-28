#pragma once

#include <stdbool.h>
#include <stdint.h>

#include "dmd_color.h"

#define DMD_PLASMA_PALETTE_SIZE 128
#define DMD_PLASMA_STOP_COUNT 4
#define DMD_PLASMA_CYCLE_DEFAULT_MS 8000
#define DMD_PLASMA_CYCLE_MIN_MS 1000
#define DMD_PLASMA_CYCLE_MAX_MS 60000
#define DMD_PLASMA_CYCLE_STEP_MS 250

typedef enum {
    DMD_PLASMA_NEON = 0,
    DMD_PLASMA_LAVA = 1,
    DMD_PLASMA_OCEAN = 2,
    DMD_PLASMA_AURORA = 3,
    DMD_PLASMA_CUSTOM = 4,
    DMD_PLASMA_TOXIC = 5,
    DMD_PLASMA_VAPOR = 6,
    DMD_PLASMA_SOLAR = 7,
    DMD_PLASMA_ARCTIC = 8,
} dmd_plasma_palette_t;

bool dmd_plasma_palette_is_valid(uint8_t palette);
const char *dmd_plasma_palette_name(dmd_plasma_palette_t palette);
void dmd_plasma_default_stops(
    dmd_plasma_palette_t palette,
    dmd_rgb_t output[DMD_PLASMA_STOP_COUNT]);
void dmd_plasma_build_palette(
    dmd_plasma_palette_t palette,
    const dmd_rgb_t custom[DMD_PLASMA_STOP_COUNT],
    dmd_rgb_t output[DMD_PLASMA_PALETTE_SIZE]);
uint8_t dmd_plasma_phase_at_ms(uint64_t elapsed_ms, uint16_t cycle_ms);
uint8_t dmd_plasma_palette_index(uint8_t x, uint8_t y, uint8_t phase);
bool dmd_plasma_self_test(void);
