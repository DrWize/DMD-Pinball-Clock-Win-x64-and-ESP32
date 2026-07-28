#include "dmd_actions.h"

#include "dmd_color.h"
#include "dmd_display.h"
#include "dmd_network.h"
#include "dmd_scene.h"
#include "dmd_settings.h"

static dmd_color_preset_t adjacent_color(
    dmd_color_preset_t current,
    int direction)
{
    int value = (int)current;
    for (int attempts = 0; attempts < 64; attempts++) {
        value += direction;
        if (value < 0) {
            value = DMD_COLOR_PRESET_MAX;
        } else if (value > DMD_COLOR_PRESET_MAX) {
            value = 0;
        }
        if (dmd_color_is_valid((uint8_t)value)) {
            return (dmd_color_preset_t)value;
        }
    }
    return DMD_COLOR_ORANGE;
}

esp_err_t dmd_action_execute(dmd_action_t action)
{
    if (action == DMD_ACTION_SYNC_NTP) {
        return dmd_network_request_ntp_sync();
    }
    if (action == DMD_ACTION_SHOW_CLOCK) {
        dmd_display_show_clock();
        return ESP_OK;
    }

    dmd_settings_t settings;
    dmd_settings_get(&settings);
    switch (action) {
    case DMD_ACTION_COLOR_PREVIOUS:
        settings.color_preset = adjacent_color(settings.color_preset, -1);
        break;
    case DMD_ACTION_COLOR_NEXT:
        settings.color_preset = adjacent_color(settings.color_preset, 1);
        break;
    case DMD_ACTION_TOGGLE_INFORMATION:
        settings.show_information = !settings.show_information;
        break;
    case DMD_ACTION_TOGGLE_GLOW:
        settings.glow_strength = settings.glow_strength == 0 ? 35 : 0;
        break;
    case DMD_ACTION_SCENE_PREVIOUS:
        settings.scene_index =
            (settings.scene_index + dmd_scene_count() - 1) % dmd_scene_count();
        settings.play_scene = true;
        break;
    case DMD_ACTION_SCENE_NEXT:
        settings.scene_index =
            (settings.scene_index + 1) % dmd_scene_count();
        settings.play_scene = true;
        break;
    default:
        return ESP_ERR_INVALID_ARG;
    }

    esp_err_t error = dmd_settings_update(&settings);
    if (error == ESP_OK &&
        (action == DMD_ACTION_SCENE_PREVIOUS ||
         action == DMD_ACTION_SCENE_NEXT)) {
        dmd_display_play_scene(settings.scene_index);
    }
    return error;
}
