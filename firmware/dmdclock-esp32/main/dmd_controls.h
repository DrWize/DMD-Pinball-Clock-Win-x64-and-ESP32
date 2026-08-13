#pragma once

#include <stdbool.h>
#include <stdint.h>

#include "dmd_actions.h"

int dmd_controls_top_button_x(int index);
int dmd_controls_top_button_width(int index);
int dmd_controls_bottom_button_x(int index);
bool dmd_controls_action_at(uint16_t x, uint16_t y, dmd_action_t *action);
bool dmd_controls_layout_self_test(void);
