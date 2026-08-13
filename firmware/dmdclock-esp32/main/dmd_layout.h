#pragma once

#include "dmd_geometry.h"

#define DMD_TOP_BUTTON_COUNT 3
#define DMD_BOTTOM_BUTTON_COUNT 5
#define DMD_INFO_TEXT_SCALE 2
#define DMD_INFO_TEXT_HEIGHT (7 * DMD_INFO_TEXT_SCALE)
#define DMD_INFO_BACKING_PAD 3

#if CONFIG_DMD_BOARD_WAVESHARE_7
#define DMD_CHROME_MARGIN 10
#define DMD_TOP_BUTTON_HEIGHT 46
#define DMD_BOTTOM_BUTTON_HEIGHT 56
#define DMD_TOP_BUTTON_Y DMD_CHROME_MARGIN
#define DMD_BOTTOM_BUTTON_Y (LCD_HEIGHT - DMD_BOTTOM_BUTTON_HEIGHT - 24)
#define DMD_INFO_TEXT_Y (LCD_HEIGHT - DMD_INFO_TEXT_HEIGHT - 5)
#define DMD_CHROME_TEMPORARY_ONLY 0
#elif CONFIG_DMD_BOARD_3_49_LANDSCAPE
#define DMD_CHROME_MARGIN 4
#define DMD_TOP_BUTTON_HEIGHT 30
#define DMD_BOTTOM_BUTTON_HEIGHT 32
#define DMD_TOP_BUTTON_Y DMD_CHROME_MARGIN
#define DMD_BOTTOM_BUTTON_Y \
    (LCD_HEIGHT - DMD_BOTTOM_BUTTON_HEIGHT - DMD_CHROME_MARGIN)
#define DMD_INFO_TEXT_Y \
    (DMD_BOTTOM_BUTTON_Y - DMD_INFO_TEXT_HEIGHT - DMD_CHROME_MARGIN)
#define DMD_CHROME_TEMPORARY_ONLY 1
#else
#error "Select exactly one supported DMD board target"
#endif

#define DMD_TOP_BUTTON_WIDTH \
    ((LCD_WIDTH - (DMD_TOP_BUTTON_COUNT + 1) * DMD_CHROME_MARGIN) / \
     DMD_TOP_BUTTON_COUNT)
#define DMD_BOTTOM_BUTTON_WIDTH \
    ((LCD_WIDTH - (DMD_BOTTOM_BUTTON_COUNT + 1) * DMD_CHROME_MARGIN) / \
     DMD_BOTTOM_BUTTON_COUNT)
#define DMD_INFO_BACKING_Y (DMD_INFO_TEXT_Y - DMD_INFO_BACKING_PAD)
#define DMD_INFO_BACKING_HEIGHT \
    (DMD_INFO_TEXT_HEIGHT + 2 * DMD_INFO_BACKING_PAD)

_Static_assert(DMD_TOP_BUTTON_Y >= 0, "Top controls start above the framebuffer");
_Static_assert(
    DMD_TOP_BUTTON_Y + DMD_TOP_BUTTON_HEIGHT <= LCD_HEIGHT,
    "Top controls end below the framebuffer");
_Static_assert(
    DMD_BOTTOM_BUTTON_Y >= 0,
    "Bottom controls start above the framebuffer");
_Static_assert(
    DMD_BOTTOM_BUTTON_Y + DMD_BOTTOM_BUTTON_HEIGHT <= LCD_HEIGHT,
    "Bottom controls end below the framebuffer");
_Static_assert(DMD_TOP_BUTTON_WIDTH > 0, "Top controls require a positive width");
_Static_assert(
    DMD_BOTTOM_BUTTON_WIDTH > 0,
    "Bottom controls require a positive width");
_Static_assert(DMD_INFO_BACKING_Y >= 0, "Information text starts above the framebuffer");
_Static_assert(
    DMD_INFO_BACKING_Y + DMD_INFO_BACKING_HEIGHT <= LCD_HEIGHT,
    "Information text ends below the framebuffer");
