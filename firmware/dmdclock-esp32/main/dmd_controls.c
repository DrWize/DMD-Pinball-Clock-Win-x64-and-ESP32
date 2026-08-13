#include "dmd_controls.h"

#include <stddef.h>

#include "dmd_layout.h"

int dmd_controls_top_button_x(int index)
{
    return DMD_CHROME_MARGIN +
           index * (DMD_TOP_BUTTON_WIDTH + DMD_CHROME_MARGIN);
}

int dmd_controls_top_button_width(int index)
{
    return index + 1 >= DMD_TOP_BUTTON_COUNT
        ? LCD_WIDTH - dmd_controls_top_button_x(index) - DMD_CHROME_MARGIN
        : DMD_TOP_BUTTON_WIDTH;
}

int dmd_controls_bottom_button_x(int index)
{
    return DMD_CHROME_MARGIN +
           index * (DMD_BOTTOM_BUTTON_WIDTH + DMD_CHROME_MARGIN);
}

bool dmd_controls_action_at(uint16_t x, uint16_t y, dmd_action_t *action)
{
    if (action == NULL || x >= LCD_WIDTH || y >= LCD_HEIGHT) {
        return false;
    }

    int top_zone_bottom =
        DMD_TOP_BUTTON_Y + DMD_TOP_BUTTON_HEIGHT + DMD_CHROME_MARGIN;
    int bottom_zone_top = DMD_BOTTOM_BUTTON_Y - DMD_CHROME_MARGIN;
    if (y < top_zone_bottom) {
        *action = x < dmd_controls_top_button_x(0) +
                      DMD_TOP_BUTTON_WIDTH + DMD_CHROME_MARGIN / 2
            ? DMD_ACTION_PINBALL_NEXT
            : (x < dmd_controls_top_button_x(1) +
                       DMD_TOP_BUTTON_WIDTH + DMD_CHROME_MARGIN / 2
                ? DMD_ACTION_SCENE_NEXT
                : DMD_ACTION_TOGGLE_RANDOM);
        return true;
    }
    if (y < bottom_zone_top) {
        return false;
    }

    if (x < dmd_controls_bottom_button_x(0) +
                DMD_BOTTOM_BUTTON_WIDTH + DMD_CHROME_MARGIN / 2) {
        *action = DMD_ACTION_COLOR_FAMILY_NEXT;
    } else if (x < dmd_controls_bottom_button_x(1) +
                       DMD_BOTTOM_BUTTON_WIDTH + DMD_CHROME_MARGIN / 2) {
        *action = DMD_ACTION_COLOR_THEME_NEXT;
    } else if (x < dmd_controls_bottom_button_x(2) +
                       DMD_BOTTOM_BUTTON_WIDTH + DMD_CHROME_MARGIN / 2) {
        *action = DMD_ACTION_TOGGLE_INFORMATION;
    } else if (x < dmd_controls_bottom_button_x(3) +
                       DMD_BOTTOM_BUTTON_WIDTH + DMD_CHROME_MARGIN / 2) {
        *action = DMD_ACTION_TOGGLE_GLOW;
    } else {
        *action = DMD_ACTION_SYNC_NTP;
    }
    return true;
}

static bool expect_action(int x, int y, dmd_action_t expected)
{
    dmd_action_t actual = DMD_ACTION_REBOOT;
    return dmd_controls_action_at((uint16_t)x, (uint16_t)y, &actual) &&
           actual == expected;
}

bool dmd_controls_layout_self_test(void)
{
    static const dmd_action_t TOP_ACTIONS[DMD_TOP_BUTTON_COUNT] = {
        DMD_ACTION_PINBALL_NEXT,
        DMD_ACTION_SCENE_NEXT,
        DMD_ACTION_TOGGLE_RANDOM,
    };
    static const dmd_action_t BOTTOM_ACTIONS[DMD_BOTTOM_BUTTON_COUNT] = {
        DMD_ACTION_COLOR_FAMILY_NEXT,
        DMD_ACTION_COLOR_THEME_NEXT,
        DMD_ACTION_TOGGLE_INFORMATION,
        DMD_ACTION_TOGGLE_GLOW,
        DMD_ACTION_SYNC_NTP,
    };

    for (int index = 0; index < DMD_TOP_BUTTON_COUNT; index++) {
        if (!expect_action(
                dmd_controls_top_button_x(index) +
                    dmd_controls_top_button_width(index) / 2,
                DMD_TOP_BUTTON_Y + DMD_TOP_BUTTON_HEIGHT / 2,
                TOP_ACTIONS[index])) {
            return false;
        }
    }
    for (int index = 0; index < DMD_BOTTOM_BUTTON_COUNT; index++) {
        if (!expect_action(
                dmd_controls_bottom_button_x(index) +
                    DMD_BOTTOM_BUTTON_WIDTH / 2,
                DMD_BOTTOM_BUTTON_Y + DMD_BOTTOM_BUTTON_HEIGHT / 2,
                BOTTOM_ACTIONS[index])) {
            return false;
        }
    }

    dmd_action_t unused;
    int middle_y =
        (DMD_TOP_BUTTON_Y + DMD_TOP_BUTTON_HEIGHT +
         DMD_BOTTOM_BUTTON_Y) / 2;
    return !dmd_controls_action_at(LCD_WIDTH / 2, middle_y, &unused) &&
           !dmd_controls_action_at(LCD_WIDTH, 0, &unused) &&
           !dmd_controls_action_at(0, LCD_HEIGHT, &unused);
}
