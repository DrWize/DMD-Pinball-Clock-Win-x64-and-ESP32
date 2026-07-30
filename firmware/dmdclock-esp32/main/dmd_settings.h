#pragma once

#include <stdbool.h>
#include <stdint.h>
#include <time.h>

#include "dmd_color.h"
#include "dmd_plasma.h"
#include "esp_err.h"

#define DMD_WIFI_SSID_MAX 32
#define DMD_WIFI_PASSWORD_MAX 64
#define DMD_TIMEZONE_MAX 64
#define DMD_SCHEDULE_DAY_COUNT 7
#define DMD_SCHEDULE_HOUR_COUNT 24
#define DMD_SCHEDULE_SLOT_COUNT \
    (DMD_SCHEDULE_DAY_COUNT * DMD_SCHEDULE_HOUR_COUNT)
#define DMD_SCHEDULE_BYTES ((DMD_SCHEDULE_SLOT_COUNT + 7) / 8)
#define DMD_GRADIENT_CUSTOM_COLOR_COUNT 2
#define DMD_RASTER_CUSTOM_COLOR_COUNT 4

typedef enum {
    DMD_INFORMATION_COLOR_GREY = 0,
    DMD_INFORMATION_COLOR_THEME = 1,
    DMD_INFORMATION_COLOR_CUSTOM = 2,
} dmd_information_color_mode_t;

typedef struct {
    uint8_t brightness;
    uint8_t glow_strength;
    dmd_plasma_palette_t plasma_palette;
    uint16_t plasma_cycle_ms;
    dmd_rgb_t plasma_custom[DMD_PLASMA_STOP_COUNT];
    dmd_rgb_t basic_custom;
    dmd_rgb_t gradient_custom[DMD_GRADIENT_CUSTOM_COLOR_COUNT];
    dmd_rgb_t raster_custom[DMD_RASTER_CUSTOM_COLOR_COUNT];
    bool use_24_hour;
    bool show_seconds;
    bool display_on;
    bool screen_schedule_enabled;
    uint8_t screen_off_schedule[DMD_SCHEDULE_BYTES];
    bool reboot_schedule_enabled;
    uint8_t reboot_weekday;
    uint8_t reboot_hour;
    uint8_t reboot_minute;
    bool play_scene;
    bool automatic_cycle;
    bool random_playback;
    bool playback_log_enabled;
    bool show_information;
    dmd_information_color_mode_t information_color_mode;
    dmd_rgb_t information_custom_color;
    uint16_t scene_index;
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
bool dmd_settings_screen_scheduled_off(
    const dmd_settings_t *settings,
    time_t now);
bool dmd_settings_claim_scheduled_reboot(
    const dmd_settings_t *settings,
    time_t now);
void dmd_settings_apply_timezone(const char *timezone);
esp_err_t dmd_settings_last_nvs_save_error(void);
esp_err_t dmd_settings_last_sd_save_error(void);
