#include "dmd_plasma.h"

#include <stdlib.h>

static const int8_t SINE[256] = {
    0, 3, 6, 9, 12, 16, 19, 22, 25, 28, 31, 34, 37, 40, 43, 46,
    49, 51, 54, 57, 60, 63, 65, 68, 71, 73, 76, 78, 81, 83, 85, 88,
    90, 92, 94, 96, 98, 100, 102, 104, 106, 107, 109, 111, 112, 113, 115, 116,
    117, 118, 120, 121, 122, 122, 123, 124, 125, 125, 126, 126, 126, 127, 127, 127,
    127, 127, 127, 127, 126, 126, 126, 125, 125, 124, 123, 122, 122, 121, 120, 118,
    117, 116, 115, 113, 112, 111, 109, 107, 106, 104, 102, 100, 98, 96, 94, 92,
    90, 88, 85, 83, 81, 78, 76, 73, 71, 68, 65, 63, 60, 57, 54, 51,
    49, 46, 43, 40, 37, 34, 31, 28, 25, 22, 19, 16, 12, 9, 6, 3,
    0, -3, -6, -9, -12, -16, -19, -22, -25, -28, -31, -34, -37, -40, -43, -46,
    -49, -51, -54, -57, -60, -63, -65, -68, -71, -73, -76, -78, -81, -83, -85, -88,
    -90, -92, -94, -96, -98, -100, -102, -104, -106, -107, -109, -111, -112, -113, -115, -116,
    -117, -118, -120, -121, -122, -122, -123, -124, -125, -125, -126, -126, -126, -127, -127, -127,
    -127, -127, -127, -127, -126, -126, -126, -125, -125, -124, -123, -122, -122, -121, -120, -118,
    -117, -116, -115, -113, -112, -111, -109, -107, -106, -104, -102, -100, -98, -96, -94, -92,
    -90, -88, -85, -83, -81, -78, -76, -73, -71, -68, -65, -63, -60, -57, -54, -51,
    -49, -46, -43, -40, -37, -34, -31, -28, -25, -22, -19, -16, -12, -9, -6, -3,
};

static const dmd_rgb_t PRESET_STOPS[9][DMD_PLASMA_STOP_COUNT] = {
    {{0x2d, 0x0c, 0x6e}, {0x32, 0x50, 0xff}, {0x1e, 0xeb, 0xff}, {0xff, 0x41, 0xdc}},
    {{0x4a, 0x00, 0x10}, {0xe0, 0x20, 0x20}, {0xff, 0x7a, 0x00}, {0xff, 0xe0, 0x60}},
    {{0x00, 0x10, 0x40}, {0x00, 0x55, 0xd8}, {0x00, 0xc8, 0xff}, {0xb8, 0xff, 0xff}},
    {{0x18, 0x00, 0x50}, {0x7a, 0x38, 0xff}, {0x20, 0xe8, 0xa0}, {0xd8, 0xff, 0x70}},
    {{0x2d, 0x0c, 0x6e}, {0x32, 0x50, 0xff}, {0x1e, 0xeb, 0xff}, {0xff, 0x41, 0xdc}},
    {{0x08, 0x2a, 0x12}, {0x16, 0xa3, 0x4a}, {0xa3, 0xff, 0x12}, {0xf5, 0xff, 0x75}},
    {{0x24, 0x00, 0x5e}, {0x7a, 0x38, 0xff}, {0xff, 0x41, 0xdc}, {0x41, 0xe9, 0xff}},
    {{0x3d, 0x05, 0x00}, {0xd8, 0x29, 0x00}, {0xff, 0x8a, 0x00}, {0xff, 0xf0, 0xa0}},
    {{0x00, 0x1b, 0x3d}, {0x00, 0x77, 0xb6}, {0x48, 0xca, 0xe4}, {0xe0, 0xfb, 0xff}},
};

static uint8_t round_even_div32(uint16_t numerator)
{
    uint8_t quotient = (uint8_t)(numerator / 32U);
    uint8_t remainder = (uint8_t)(numerator % 32U);
    if (remainder > 16U || (remainder == 16U && (quotient & 1U) != 0)) {
        quotient++;
    }
    return quotient;
}

static uint8_t interpolate(uint8_t start, uint8_t end, uint8_t offset)
{
    uint16_t numerator =
        (uint16_t)start * (32U - offset) + (uint16_t)end * offset;
    return round_even_div32(numerator);
}

bool dmd_plasma_palette_is_valid(uint8_t palette)
{
    return palette <= DMD_PLASMA_ARCTIC;
}

const char *dmd_plasma_palette_name(dmd_plasma_palette_t palette)
{
    switch (palette) {
    case DMD_PLASMA_LAVA: return "Lava flow";
    case DMD_PLASMA_OCEAN: return "Deep ocean";
    case DMD_PLASMA_AURORA: return "Aurora drift";
    case DMD_PLASMA_CUSTOM: return "Custom";
    case DMD_PLASMA_TOXIC: return "Toxic slime";
    case DMD_PLASMA_VAPOR: return "Vapor dream";
    case DMD_PLASMA_SOLAR: return "Solar flare";
    case DMD_PLASMA_ARCTIC: return "Arctic ice";
    default: return "Neon pulse";
    }
}

void dmd_plasma_default_stops(
    dmd_plasma_palette_t palette,
    dmd_rgb_t output[DMD_PLASMA_STOP_COUNT])
{
    uint8_t index = dmd_plasma_palette_is_valid((uint8_t)palette)
        ? (uint8_t)palette
        : DMD_PLASMA_NEON;
    for (uint8_t stop = 0; stop < DMD_PLASMA_STOP_COUNT; stop++) {
        output[stop] = PRESET_STOPS[index][stop];
    }
}

void dmd_plasma_build_palette(
    dmd_plasma_palette_t palette,
    const dmd_rgb_t custom[DMD_PLASMA_STOP_COUNT],
    dmd_rgb_t output[DMD_PLASMA_PALETTE_SIZE])
{
    dmd_rgb_t stops[DMD_PLASMA_STOP_COUNT];
    if (palette == DMD_PLASMA_CUSTOM && custom != NULL) {
        for (uint8_t stop = 0; stop < DMD_PLASMA_STOP_COUNT; stop++) {
            stops[stop] = custom[stop];
        }
    } else {
        dmd_plasma_default_stops(palette, stops);
    }

    for (uint8_t index = 0; index < DMD_PLASMA_PALETTE_SIZE; index++) {
        uint8_t segment = index / 32U;
        uint8_t offset = index % 32U;
        uint8_t next = (uint8_t)((segment + 1U) % DMD_PLASMA_STOP_COUNT);
        output[index].red = interpolate(stops[segment].red, stops[next].red, offset);
        output[index].green = interpolate(stops[segment].green, stops[next].green, offset);
        output[index].blue = interpolate(stops[segment].blue, stops[next].blue, offset);
    }
}

uint8_t dmd_plasma_phase_at_ms(uint64_t elapsed_ms, uint16_t cycle_ms)
{
    uint16_t normalized =
        cycle_ms < DMD_PLASMA_CYCLE_MIN_MS ||
        cycle_ms > DMD_PLASMA_CYCLE_MAX_MS
            ? DMD_PLASMA_CYCLE_DEFAULT_MS
            : cycle_ms;
    return (uint8_t)(((elapsed_ms % normalized) * 256ULL) / normalized);
}

uint8_t dmd_plasma_palette_index(uint8_t x, uint8_t y, uint8_t phase)
{
    int horizontal = SINE[((uint16_t)x * 5U + phase) & 0xffU];
    int vertical = SINE[((int)y * 11 - phase) & 0xff];
    int diagonal = SINE[
        (((uint16_t)x + y) * 3U + (phase >> 1U)) & 0xffU];
    int dx = abs((int)x * 2 - 127);
    int dy = abs((int)y * 2 - 31);
    int maximum = dx > dy ? dx : dy;
    int minimum = dx < dy ? dx : dy;
    int radius = maximum + (minimum >> 1);
    int radial = SINE[(radius * 3 - phase) & 0xff];
    int sum = horizontal + vertical + diagonal + radial;
    return (uint8_t)(((sum + 508) * 127) / 1016);
}

bool dmd_plasma_self_test(void)
{
    return dmd_plasma_palette_index(0, 0, 0) == 49 &&
           dmd_plasma_palette_index(37, 11, 42) == 55 &&
           dmd_plasma_palette_index(127, 31, 255) == 78 &&
           dmd_plasma_palette_index(64, 16, 128) == 75 &&
           dmd_plasma_phase_at_ms(4000, 8000) == 128 &&
           dmd_plasma_phase_at_ms(8000, 8000) == 0;
}
