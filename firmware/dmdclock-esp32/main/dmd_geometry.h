#pragma once

#include "sdkconfig.h"

#define DMD_WIDTH 128
#define DMD_HEIGHT 32
#define DMD_PIXEL_SIZE 4
#define DMD_PIXEL_COUNT (DMD_WIDTH * DMD_HEIGHT)

#define LCD_WIDTH CONFIG_DMD_DISPLAY_WIDTH
#define LCD_HEIGHT CONFIG_DMD_DISPLAY_HEIGHT
#define DMD_SCALE CONFIG_DMD_DMD_SCALE
#define DMD_VIEW_WIDTH (DMD_WIDTH * DMD_SCALE)
#define DMD_VIEW_HEIGHT (DMD_HEIGHT * DMD_SCALE)
#define DMD_VIEW_X ((LCD_WIDTH - DMD_VIEW_WIDTH) / 2)
#define DMD_VIEW_Y ((LCD_HEIGHT - DMD_VIEW_HEIGHT) / 2)

_Static_assert(DMD_WIDTH == 128, "The logical DMD width is fixed at 128 pixels");
_Static_assert(DMD_HEIGHT == 32, "The logical DMD height is fixed at 32 pixels");
_Static_assert(
    DMD_WIDTH == DMD_HEIGHT * 4,
    "The logical DMD aspect ratio must remain exactly 4:1");
_Static_assert(DMD_SCALE > 0, "The configured DMD scale must be positive");
_Static_assert(
    DMD_VIEW_WIDTH <= LCD_WIDTH,
    "The rendered DMD width exceeds the framebuffer");
_Static_assert(
    DMD_VIEW_HEIGHT <= LCD_HEIGHT,
    "The rendered DMD height exceeds the framebuffer");
_Static_assert(DMD_VIEW_X >= 0, "The rendered DMD starts before the framebuffer");
_Static_assert(DMD_VIEW_Y >= 0, "The rendered DMD starts before the framebuffer");
_Static_assert(
    DMD_VIEW_X + DMD_VIEW_WIDTH <= LCD_WIDTH,
    "The rendered DMD ends beyond the framebuffer width");
_Static_assert(
    DMD_VIEW_Y + DMD_VIEW_HEIGHT <= LCD_HEIGHT,
    "The rendered DMD ends beyond the framebuffer height");

#if CONFIG_DMD_BOARD_WAVESHARE_7
_Static_assert(LCD_WIDTH == 800, "Waveshare 7 requires an 800 pixel framebuffer width");
_Static_assert(LCD_HEIGHT == 480, "Waveshare 7 requires a 480 pixel framebuffer height");
_Static_assert(DMD_SCALE == 6, "Waveshare 7 requires a 6x DMD scale");
_Static_assert(DMD_VIEW_WIDTH == 768, "Waveshare 7 DMD width must be 768 pixels");
_Static_assert(DMD_VIEW_HEIGHT == 192, "Waveshare 7 DMD height must be 192 pixels");
_Static_assert(DMD_VIEW_X == 16, "Waveshare 7 DMD x position must remain centered");
_Static_assert(DMD_VIEW_Y == 144, "Waveshare 7 DMD y position must remain centered");
#elif CONFIG_DMD_BOARD_3_49_LANDSCAPE
_Static_assert(LCD_WIDTH == 640, "Landscape349 requires a 640 pixel framebuffer width");
_Static_assert(LCD_HEIGHT == 172, "Landscape349 requires a 172 pixel framebuffer height");
_Static_assert(DMD_SCALE == 5, "Landscape349 requires a 5x DMD scale");
_Static_assert(DMD_VIEW_WIDTH == 640, "Landscape349 DMD width must be 640 pixels");
_Static_assert(DMD_VIEW_HEIGHT == 160, "Landscape349 DMD height must be 160 pixels");
_Static_assert(DMD_VIEW_X == 0, "Landscape349 DMD x position must be zero");
_Static_assert(DMD_VIEW_Y == 6, "Landscape349 DMD y position must be six pixels");
#else
#error "Select exactly one supported DMD board target"
#endif
