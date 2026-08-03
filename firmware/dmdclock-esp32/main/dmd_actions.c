#include "dmd_actions.h"

#include <string.h>

#include "esp_system.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#include "dmd_color.h"
#include "dmd_display.h"
#include "dmd_network.h"
#include "dmd_scene.h"
#include "dmd_settings.h"

static void delayed_reboot_task(void *context)
{
    (void)context;
    vTaskDelay(pdMS_TO_TICKS(500));
    esp_restart();
}

static dmd_color_preset_t first_family_preset(const char *family)
{
    for (uint8_t value = 0; value <= DMD_COLOR_PRESET_MAX; value++) {
        if (dmd_color_is_valid(value) &&
            strcmp(
                dmd_color_family((dmd_color_preset_t)value),
                family) == 0) {
            return (dmd_color_preset_t)value;
        }
    }
    return DMD_COLOR_ORANGE;
}

static dmd_color_preset_t next_family(dmd_color_preset_t current)
{
    const char *family = dmd_color_family(current);
    if (strcmp(family, "Basic") == 0) {
        return first_family_preset("Gradient");
    }
    if (strcmp(family, "Gradient") == 0) {
        return first_family_preset("Raster");
    }
    if (strcmp(family, "Raster") == 0) {
        return DMD_COLOR_PLASMA;
    }
    return first_family_preset("Basic");
}

static dmd_color_preset_t next_theme(dmd_color_preset_t current)
{
    const char *family = dmd_color_family(current);
    if (strcmp(family, "Plasma") == 0) {
        return current;
    }
    for (int offset = 1; offset <= DMD_COLOR_PRESET_MAX + 1; offset++) {
        uint8_t value =
            (uint8_t)(((int)current + offset) % (DMD_COLOR_PRESET_MAX + 1));
        if (dmd_color_is_valid(value) &&
            strcmp(dmd_color_family((dmd_color_preset_t)value), family) == 0) {
            return (dmd_color_preset_t)value;
        }
    }
    return current;
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
    if (action == DMD_ACTION_TOUCH_TEST) {
        dmd_display_start_touch_test();
        return ESP_OK;
    }
    if (action == DMD_ACTION_SETUP_QR) {
        dmd_display_show_setup_qr();
        return ESP_OK;
    }
    if (action == DMD_ACTION_REBOOT) {
        return xTaskCreate(
                   delayed_reboot_task,
                   "dmd_reboot",
                   2048,
                   NULL,
                   5,
                   NULL) == pdPASS
            ? ESP_OK
            : ESP_ERR_NO_MEM;
    }

    dmd_settings_t settings;
    dmd_settings_get(&settings);
    dmd_display_state_t display;
    dmd_display_get_state(&display);
    uint16_t current_scene = display.scene_index < dmd_scene_count()
        ? display.scene_index
        : settings.scene_index;
    switch (action) {
    case DMD_ACTION_COLOR_FAMILY_NEXT:
        settings.color_preset = next_family(settings.color_preset);
        break;
    case DMD_ACTION_COLOR_THEME_NEXT:
        if (settings.color_preset == DMD_COLOR_PLASMA) {
            uint8_t palette = (uint8_t)settings.plasma_palette;
            do {
                palette = (uint8_t)((palette + 1) % 9);
            } while (!dmd_plasma_palette_is_valid(palette));
            settings.plasma_palette = (dmd_plasma_palette_t)palette;
        } else {
            settings.color_preset = next_theme(settings.color_preset);
        }
        break;
    case DMD_ACTION_TOGGLE_INFORMATION:
        settings.show_information = !settings.show_information;
        break;
    case DMD_ACTION_TOGGLE_GLOW:
        settings.glow_strength = settings.glow_strength == 0 ? 35 : 0;
        break;
    case DMD_ACTION_PINBALL_NEXT:
        if (dmd_scene_count() == 0) {
            return ESP_ERR_NOT_FOUND;
        }
        settings.scene_index = dmd_scene_next_game(current_scene);
        settings.play_scene = true;
        break;
    case DMD_ACTION_SCENE_NEXT:
        if (dmd_scene_count() == 0) {
            return ESP_ERR_NOT_FOUND;
        }
        settings.scene_index = dmd_scene_next_in_game(current_scene);
        settings.play_scene = true;
        break;
    case DMD_ACTION_TOGGLE_RANDOM:
        settings.random_playback = !settings.random_playback;
        break;
    default:
        return ESP_ERR_INVALID_ARG;
    }

    esp_err_t error = dmd_settings_update(&settings);
    if (error == ESP_OK &&
        (action == DMD_ACTION_PINBALL_NEXT ||
         action == DMD_ACTION_SCENE_NEXT)) {
        dmd_display_play_scene(settings.scene_index);
    }
    return error;
}
