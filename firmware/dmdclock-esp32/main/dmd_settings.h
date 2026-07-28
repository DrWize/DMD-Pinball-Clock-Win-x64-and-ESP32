#pragma once

#include <stdbool.h>
#include <stdint.h>

#include "dmd_color.h"
#include "dmd_plasma.h"
#include "esp_err.h"

#define DMD_WIFI_SSID_MAX 32
#define DMD_WIFI_PASSWORD_MAX 64
#define DMD_TIMEZONE_MAX 64

typedef struct {
    uint8_t brightness;
    uint8_t glow_strength;
    dmd_plasma_palette_t plasma_palette;
    uint16_t plasma_cycle_ms;
    dmd_rgb_t plasma_custom[DMD_PLASMA_STOP_COUNT];
    bool use_24_hour;
    bool show_seconds;
    bool display_on;
    bool play_scene;
    bool automatic_cycle;
    bool random_playback;
    bool show_information;
    uint8_t scene_index;
    uint8_t animations_per_cycle;
    uint16_t clock_display_seconds;
    uint16_t animation_gap_seconds;
    dmd_color_preset_t color_preset;
    char timezone[DMD_TIMEZONE_MAX];
    char wifi_ssid[DMD_WIFI_SSID_MAX + 1];
    char wifi_password[DMD_WIFI_PASSWORD_MAX + 1];
    uint32_t revision;
} dmd_settings_t;

esp_err_t dmd_settings_init(void);
void dmd_settings_get(dmd_settings_t *out);
esp_err_t dmd_settings_update(const dmd_settings_t *settings);
bool dmd_settings_time_is_valid(void);
void dmd_settings_apply_timezone(const char *timezone);
