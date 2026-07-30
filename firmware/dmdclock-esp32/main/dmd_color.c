#include "dmd_color.h"

#include <stddef.h>

#define RGB(r, g, b) {r, g, b}

typedef struct {
    dmd_color_preset_t preset;
    const char *name;
    dmd_rgb_t low;
    dmd_rgb_t high;
} gradient_t;

typedef struct {
    dmd_color_preset_t preset;
    const char *name;
    uint8_t count;
    dmd_rgb_t bands[11];
} raster_t;

#define C64_WHITE RGB(0xff, 0xff, 0xff)
#define C64_RED RGB(0x68, 0x37, 0x2b)
#define C64_CYAN RGB(0x70, 0xa4, 0xb2)
#define C64_PURPLE RGB(0x6f, 0x3d, 0x86)
#define C64_GREEN RGB(0x58, 0x8d, 0x43)
#define C64_BLUE RGB(0x35, 0x28, 0x79)
#define C64_YELLOW RGB(0xb8, 0xc7, 0x6f)
#define C64_ORANGE RGB(0x6f, 0x4f, 0x25)
#define C64_BROWN RGB(0x43, 0x39, 0x00)
#define C64_LIGHT_RED RGB(0x9a, 0x67, 0x59)
#define C64_DARK_GRAY RGB(0x44, 0x44, 0x44)
#define C64_GRAY RGB(0x6c, 0x6c, 0x6c)
#define C64_LIGHT_GREEN RGB(0x9a, 0xd2, 0x84)
#define C64_LIGHT_BLUE RGB(0x6c, 0x5e, 0xb5)
#define C64_LIGHT_GRAY RGB(0x95, 0x95, 0x95)

static const gradient_t GRADIENTS[] = {
    {DMD_COLOR_NEON_SUNSET, "Neon sunset", RGB(255, 43, 214), RGB(255, 209, 102)},
    {DMD_COLOR_CYBER_OCEAN, "Cyber ocean", RGB(38, 123, 255), RGB(94, 255, 255)},
    {DMD_COLOR_TOXIC_ARCADE, "Toxic arcade", RGB(46, 255, 106), RGB(245, 255, 87)},
    {DMD_COLOR_VAPORWAVE, "Vaporwave", RGB(138, 77, 255), RGB(255, 92, 225)},
    {DMD_COLOR_AURORA, "Aurora", RGB(52, 255, 190), RGB(180, 112, 255)},
    {DMD_COLOR_FIRESTORM, "Firestorm", RGB(255, 50, 24), RGB(255, 210, 63)},
    {DMD_COLOR_ELECTRIC_VIOLET, "Electric violet", RGB(79, 70, 229), RGB(255, 53, 200)},
    {DMD_COLOR_ARCTIC_GLOW, "Arctic glow", RGB(32, 207, 255), RGB(232, 255, 255)},
};

static const raster_t RASTERS[] = {
    {DMD_COLOR_C64_BLUE_HALO, "Blue halo", 7,
     {C64_BLUE, C64_LIGHT_BLUE, C64_CYAN, C64_WHITE, C64_CYAN, C64_LIGHT_BLUE, C64_BLUE}},
    {DMD_COLOR_C64_RED_HALO, "Red halo", 9,
     {C64_RED, C64_LIGHT_RED, C64_ORANGE, C64_YELLOW, C64_WHITE, C64_YELLOW, C64_ORANGE, C64_LIGHT_RED, C64_RED}},
    {DMD_COLOR_C64_EARTHTONE, "Earthtone", 9,
     {C64_BROWN, C64_RED, C64_ORANGE, C64_LIGHT_RED, C64_YELLOW, C64_LIGHT_RED, C64_ORANGE, C64_RED, C64_BROWN}},
    {DMD_COLOR_C64_METAL, "Metal", 7,
     {C64_DARK_GRAY, C64_GRAY, C64_LIGHT_GRAY, C64_WHITE, C64_LIGHT_GRAY, C64_GRAY, C64_DARK_GRAY}},
    {DMD_COLOR_C64_INTERLACED_BLUE, "Interlaced blue", 11,
     {C64_BLUE, C64_LIGHT_BLUE, C64_BLUE, C64_CYAN, C64_BLUE, C64_WHITE, C64_BLUE, C64_CYAN, C64_BLUE, C64_LIGHT_BLUE, C64_BLUE}},
    {DMD_COLOR_C64_EXTRUDED_CYAN, "Extruded cyan", 11,
     {C64_BLUE, C64_CYAN, C64_WHITE, C64_CYAN, C64_BLUE, C64_LIGHT_BLUE, C64_BLUE, C64_CYAN, C64_LIGHT_BLUE, C64_CYAN, C64_BLUE}},
    {DMD_COLOR_C64_RAINBOW, "Rainbow", 10,
     {C64_RED, C64_ORANGE, C64_YELLOW, C64_LIGHT_GREEN, C64_GREEN, C64_CYAN, C64_LIGHT_BLUE, C64_BLUE, C64_PURPLE, C64_LIGHT_RED}},
    {DMD_COLOR_C64_PURPLE_HALO, "Purple halo", 7,
     {C64_BLUE, C64_PURPLE, C64_LIGHT_RED, C64_WHITE, C64_LIGHT_RED, C64_PURPLE, C64_BLUE}},
    {DMD_COLOR_RASTER_GREEN_HALO, "Green halo", 7,
     {C64_GREEN, C64_LIGHT_GREEN, C64_YELLOW, C64_WHITE, C64_YELLOW, C64_LIGHT_GREEN, C64_GREEN}},
    {DMD_COLOR_RASTER_AMBER_HALO, "Amber halo", 7,
     {C64_BROWN, C64_ORANGE, C64_YELLOW, C64_WHITE, C64_YELLOW, C64_ORANGE, C64_BROWN}},
    {DMD_COLOR_RASTER_PURPLE_PULSE, "Purple pulse", 7,
     {C64_PURPLE, C64_LIGHT_RED, C64_PURPLE, C64_WHITE, C64_PURPLE, C64_LIGHT_RED, C64_PURPLE}},
    {DMD_COLOR_RASTER_OCEAN_DEPTH, "Ocean depth", 8,
     {C64_BLUE, C64_LIGHT_BLUE, C64_CYAN, C64_LIGHT_BLUE, C64_WHITE, C64_LIGHT_BLUE, C64_CYAN, C64_BLUE}},
    {DMD_COLOR_RASTER_SUNSET_BANDS, "Sunset bands", 7,
     {C64_PURPLE, C64_RED, C64_LIGHT_RED, C64_ORANGE, C64_YELLOW, C64_LIGHT_RED, C64_RED}},
    {DMD_COLOR_RASTER_FOREST_LAYERS, "Forest layers", 7,
     {C64_BROWN, C64_GREEN, C64_LIGHT_GREEN, C64_YELLOW, C64_LIGHT_GREEN, C64_GREEN, C64_BROWN}},
    {DMD_COLOR_RASTER_ARCTIC_BANDS, "Arctic bands", 7,
     {C64_BLUE, C64_CYAN, C64_LIGHT_GRAY, C64_WHITE, C64_LIGHT_GRAY, C64_CYAN, C64_BLUE}},
    {DMD_COLOR_RASTER_CANDY_STRIPE, "Candy stripe", 7,
     {C64_RED, C64_LIGHT_RED, C64_WHITE, C64_CYAN, C64_WHITE, C64_LIGHT_RED, C64_PURPLE}},
};

static const gradient_t *find_gradient(dmd_color_preset_t preset)
{
    for (size_t index = 0; index < sizeof(GRADIENTS) / sizeof(GRADIENTS[0]); index++) {
        if (GRADIENTS[index].preset == preset) {
            return &GRADIENTS[index];
        }
    }
    return NULL;
}

static const raster_t *find_raster(dmd_color_preset_t preset)
{
    for (size_t index = 0; index < sizeof(RASTERS) / sizeof(RASTERS[0]); index++) {
        if (RASTERS[index].preset == preset) {
            return &RASTERS[index];
        }
    }
    return NULL;
}

static dmd_rgb_t solid_color(dmd_color_preset_t preset)
{
    switch (preset) {
        case DMD_COLOR_RED: return (dmd_rgb_t)RGB(255, 32, 16);
        case DMD_COLOR_MONOCHROME: return (dmd_rgb_t)RGB(235, 235, 235);
        case DMD_COLOR_AMBER: return (dmd_rgb_t)RGB(255, 176, 0);
        case DMD_COLOR_GREEN: return (dmd_rgb_t)RGB(57, 255, 90);
        case DMD_COLOR_BLUE: return (dmd_rgb_t)RGB(58, 123, 255);
        case DMD_COLOR_CYAN: return (dmd_rgb_t)RGB(37, 230, 255);
        case DMD_COLOR_MAGENTA: return (dmd_rgb_t)RGB(255, 63, 203);
        default: return (dmd_rgb_t)RGB(255, 112, 14);
    }
}

bool dmd_color_is_valid(uint8_t preset)
{
    dmd_color_preset_t value = (dmd_color_preset_t)preset;
    return value == DMD_COLOR_ORANGE ||
           value == DMD_COLOR_RED ||
           value == DMD_COLOR_PLASMA ||
           value == DMD_COLOR_MONOCHROME ||
           value == DMD_COLOR_AMBER ||
           value == DMD_COLOR_GREEN ||
           value == DMD_COLOR_BLUE ||
           value == DMD_COLOR_CYAN ||
           value == DMD_COLOR_MAGENTA ||
           value == DMD_COLOR_BASIC_CUSTOM ||
           value == DMD_COLOR_GRADIENT_CUSTOM ||
           value == DMD_COLOR_RASTER_CUSTOM ||
           find_gradient(value) != NULL ||
           find_raster(value) != NULL;
}

const char *dmd_color_name(dmd_color_preset_t preset)
{
    const gradient_t *gradient = find_gradient(preset);
    if (gradient != NULL) {
        return gradient->name;
    }
    const raster_t *raster = find_raster(preset);
    if (raster != NULL) {
        return raster->name;
    }
    switch (preset) {
        case DMD_COLOR_RED: return "Pinball red";
        case DMD_COLOR_PLASMA: return "Plasma";
        case DMD_COLOR_MONOCHROME: return "Warm white";
        case DMD_COLOR_AMBER: return "Golden amber";
        case DMD_COLOR_GREEN: return "Arcade green";
        case DMD_COLOR_BLUE: return "Electric blue";
        case DMD_COLOR_CYAN: return "Ice cyan";
        case DMD_COLOR_MAGENTA: return "Hot magenta";
        case DMD_COLOR_BASIC_CUSTOM:
        case DMD_COLOR_GRADIENT_CUSTOM:
        case DMD_COLOR_RASTER_CUSTOM:
            return "Custom";
        default: return "Classic orange";
    }
}

const char *dmd_color_family(dmd_color_preset_t preset)
{
    if (preset == DMD_COLOR_PLASMA) {
        return "Plasma";
    }
    if (find_gradient(preset) != NULL) {
        return "Gradient";
    }
    if (find_raster(preset) != NULL) {
        return "Raster";
    }
    if (preset == DMD_COLOR_GRADIENT_CUSTOM) {
        return "Gradient";
    }
    if (preset == DMD_COLOR_RASTER_CUSTOM) {
        return "Raster";
    }
    return "Basic";
}

dmd_rgb_t dmd_color_at(dmd_color_preset_t preset, uint8_t x, uint8_t y)
{
    const gradient_t *gradient = find_gradient(preset);
    if (gradient != NULL) {
        dmd_rgb_t result;
        uint16_t inverse = (uint16_t)(127 - x);
        result.red = (uint8_t)(
            (gradient->low.red * inverse + gradient->high.red * x + 63) / 127);
        result.green = (uint8_t)(
            (gradient->low.green * inverse + gradient->high.green * x + 63) / 127);
        result.blue = (uint8_t)(
            (gradient->low.blue * inverse + gradient->high.blue * x + 63) / 127);
        return result;
    }

    const raster_t *raster = find_raster(preset);
    if (raster != NULL) {
        uint8_t band = (uint8_t)(((uint16_t)y * raster->count) / 32);
        if (band >= raster->count) {
            band = raster->count - 1;
        }
        return raster->bands[band];
    }
    return solid_color(preset);
}

dmd_rgb_t dmd_color_custom_at(
    dmd_color_preset_t preset,
    const dmd_rgb_t *custom_colors,
    uint8_t custom_color_count,
    uint8_t x,
    uint8_t y)
{
    if (custom_colors == NULL || custom_color_count == 0) {
        return dmd_color_at(preset, x, y);
    }
    if (preset == DMD_COLOR_BASIC_CUSTOM) {
        return custom_colors[0];
    }
    if (preset == DMD_COLOR_GRADIENT_CUSTOM) {
        if (custom_color_count < 2) {
            return custom_colors[0];
        }
        uint16_t inverse = (uint16_t)(127 - x);
        return (dmd_rgb_t) {
            .red = (uint8_t)(
                (custom_colors[0].red * inverse +
                 custom_colors[1].red * x + 63) / 127),
            .green = (uint8_t)(
                (custom_colors[0].green * inverse +
                 custom_colors[1].green * x + 63) / 127),
            .blue = (uint8_t)(
                (custom_colors[0].blue * inverse +
                 custom_colors[1].blue * x + 63) / 127),
        };
    }
    if (preset == DMD_COLOR_RASTER_CUSTOM) {
        uint8_t band = (uint8_t)(((uint16_t)y * custom_color_count) / 32);
        if (band >= custom_color_count) {
            band = custom_color_count - 1;
        }
        return custom_colors[band];
    }
    return dmd_color_at(preset, x, y);
}
