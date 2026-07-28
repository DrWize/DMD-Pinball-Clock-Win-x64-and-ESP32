#include "dmd_settings.h"

#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "dmd_scene.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "nvs.h"

#if DMD_HAS_BOOTSTRAP_WIFI
#include "dmd_bootstrap_wifi.h"
#else
#define DMD_BOOTSTRAP_WIFI_SSID ""
#define DMD_BOOTSTRAP_WIFI_PASSWORD ""
#endif

static const char *TAG = "dmd_settings";
static const char *NAMESPACE = "dmdclock";
static SemaphoreHandle_t s_lock;
static dmd_settings_t s_settings;

static void set_defaults(void)
{
    memset(&s_settings, 0, sizeof(s_settings));
    s_settings.brightness = 100;
    s_settings.glow_strength = 35;
    s_settings.plasma_palette = DMD_PLASMA_NEON;
    s_settings.plasma_cycle_ms = DMD_PLASMA_CYCLE_DEFAULT_MS;
    dmd_plasma_default_stops(DMD_PLASMA_NEON, s_settings.plasma_custom);
    s_settings.use_24_hour = true;
    s_settings.show_seconds = false;
    s_settings.display_on = true;
    s_settings.play_scene = true;
    s_settings.automatic_cycle = true;
    s_settings.random_playback = false;
    s_settings.show_information = true;
    s_settings.scene_index = 0;
    s_settings.animations_per_cycle = 1;
    s_settings.clock_display_seconds = 30;
    s_settings.animation_gap_seconds = 0;
    s_settings.color_preset = DMD_COLOR_ORANGE;
    strlcpy(
        s_settings.timezone,
        "CET-1CEST,M3.5.0,M10.5.0/3",
        sizeof(s_settings.timezone));
    strlcpy(
        s_settings.wifi_ssid,
        DMD_BOOTSTRAP_WIFI_SSID,
        sizeof(s_settings.wifi_ssid));
    strlcpy(
        s_settings.wifi_password,
        DMD_BOOTSTRAP_WIFI_PASSWORD,
        sizeof(s_settings.wifi_password));
    s_settings.revision = 1;
}

static void load_string(nvs_handle_t handle, const char *key, char *value, size_t capacity)
{
    size_t required = capacity;
    esp_err_t error = nvs_get_str(handle, key, value, &required);
    if (error != ESP_OK) {
        value[0] = '\0';
    }
}

esp_err_t dmd_settings_init(void)
{
    s_lock = xSemaphoreCreateMutex();
    if (s_lock == NULL) {
        return ESP_ERR_NO_MEM;
    }

    set_defaults();
    nvs_handle_t handle;
    esp_err_t error = nvs_open(NAMESPACE, NVS_READONLY, &handle);
    if (error == ESP_ERR_NVS_NOT_FOUND) {
        dmd_settings_apply_timezone(s_settings.timezone);
        if (s_settings.wifi_ssid[0] != '\0') {
            ESP_LOGI(TAG, "Persisting one-time bootstrap Wi-Fi credentials");
            return dmd_settings_update(&s_settings);
        }
        return ESP_OK;
    }
    if (error != ESP_OK) {
        return error;
    }

    uint8_t value = 0;
    if (nvs_get_u8(handle, "brightness", &value) == ESP_OK) {
        s_settings.brightness = value <= 100 ? value : 100;
    }
    if (nvs_get_u8(handle, "glow", &value) == ESP_OK) {
        s_settings.glow_strength = value <= 100 ? value : 35;
    }
    if (nvs_get_u8(handle, "plasma_pal", &value) == ESP_OK &&
        dmd_plasma_palette_is_valid(value)) {
        s_settings.plasma_palette = (dmd_plasma_palette_t)value;
    }
    if (nvs_get_u8(handle, "hour24", &value) == ESP_OK) {
        s_settings.use_24_hour = value != 0;
    }
    if (nvs_get_u8(handle, "seconds", &value) == ESP_OK) {
        s_settings.show_seconds = value != 0;
    }
    if (nvs_get_u8(handle, "display", &value) == ESP_OK) {
        s_settings.display_on = value != 0;
    }
    if (nvs_get_u8(handle, "scene", &value) == ESP_OK) {
        s_settings.play_scene = value != 0;
    }
    if (nvs_get_u8(handle, "auto_cycle", &value) == ESP_OK) {
        s_settings.automatic_cycle = value != 0;
    }
    if (nvs_get_u8(handle, "random", &value) == ESP_OK) {
        s_settings.random_playback = value != 0;
    }
    if (nvs_get_u8(handle, "show_info", &value) == ESP_OK) {
        s_settings.show_information = value != 0;
    }
    if (nvs_get_u8(handle, "scene_sel", &value) == ESP_OK &&
        value < DMD_SCENE_COUNT) {
        s_settings.scene_index = value;
    }
    if (nvs_get_u8(handle, "color", &value) == ESP_OK &&
        dmd_color_is_valid(value)) {
        s_settings.color_preset = (dmd_color_preset_t)value;
    }
    if (nvs_get_u8(handle, "anim_count", &value) == ESP_OK) {
        s_settings.animations_per_cycle =
            value >= 1 && value <= 20 ? value : 1;
    }
    uint16_t word = 0;
    if (nvs_get_u16(handle, "clock_secs", &word) == ESP_OK) {
        s_settings.clock_display_seconds =
            word >= 5 && word <= 3600 ? word : 30;
    }
    if (nvs_get_u16(handle, "anim_gap", &word) == ESP_OK) {
        s_settings.animation_gap_seconds = word <= 3600 ? word : 0;
    }
    if (nvs_get_u16(handle, "plasma_ms", &word) == ESP_OK) {
        s_settings.plasma_cycle_ms =
            word >= DMD_PLASMA_CYCLE_MIN_MS &&
            word <= DMD_PLASMA_CYCLE_MAX_MS
                ? word
                : DMD_PLASMA_CYCLE_DEFAULT_MS;
    }
    size_t plasma_custom_size = sizeof(s_settings.plasma_custom);
    nvs_get_blob(
        handle,
        "plasma_rgb",
        s_settings.plasma_custom,
        &plasma_custom_size);
    load_string(handle, "timezone", s_settings.timezone, sizeof(s_settings.timezone));
    load_string(handle, "wifi_ssid", s_settings.wifi_ssid, sizeof(s_settings.wifi_ssid));
    load_string(handle, "wifi_pass", s_settings.wifi_password, sizeof(s_settings.wifi_password));
    nvs_close(handle);

    if (s_settings.timezone[0] == '\0') {
        strlcpy(
            s_settings.timezone,
            "CET-1CEST,M3.5.0,M10.5.0/3",
            sizeof(s_settings.timezone));
    }
    dmd_settings_apply_timezone(s_settings.timezone);
    if (s_settings.wifi_ssid[0] == '\0' &&
        DMD_BOOTSTRAP_WIFI_SSID[0] != '\0') {
        strlcpy(
            s_settings.wifi_ssid,
            DMD_BOOTSTRAP_WIFI_SSID,
            sizeof(s_settings.wifi_ssid));
        strlcpy(
            s_settings.wifi_password,
            DMD_BOOTSTRAP_WIFI_PASSWORD,
            sizeof(s_settings.wifi_password));
        ESP_LOGI(TAG, "Applying one-time bootstrap Wi-Fi credentials");
        return dmd_settings_update(&s_settings);
    }
    return ESP_OK;
}

void dmd_settings_get(dmd_settings_t *out)
{
    if (out == NULL || s_lock == NULL) {
        return;
    }
    xSemaphoreTake(s_lock, portMAX_DELAY);
    *out = s_settings;
    xSemaphoreGive(s_lock);
}

esp_err_t dmd_settings_update(const dmd_settings_t *settings)
{
    if (settings == NULL || s_lock == NULL) {
        return ESP_ERR_INVALID_ARG;
    }

    dmd_settings_t normalized = *settings;
    if (normalized.brightness > 100) {
        normalized.brightness = 100;
    }
    if (normalized.glow_strength > 100) {
        normalized.glow_strength = 100;
    }
    if (!dmd_plasma_palette_is_valid((uint8_t)normalized.plasma_palette)) {
        normalized.plasma_palette = DMD_PLASMA_NEON;
    }
    if (normalized.plasma_cycle_ms < DMD_PLASMA_CYCLE_MIN_MS) {
        normalized.plasma_cycle_ms = DMD_PLASMA_CYCLE_MIN_MS;
    } else if (normalized.plasma_cycle_ms > DMD_PLASMA_CYCLE_MAX_MS) {
        normalized.plasma_cycle_ms = DMD_PLASMA_CYCLE_MAX_MS;
    }
    normalized.plasma_cycle_ms = (uint16_t)(
        ((normalized.plasma_cycle_ms + DMD_PLASMA_CYCLE_STEP_MS / 2) /
         DMD_PLASMA_CYCLE_STEP_MS) *
        DMD_PLASMA_CYCLE_STEP_MS);
    if (!dmd_color_is_valid((uint8_t)normalized.color_preset)) {
        normalized.color_preset = DMD_COLOR_ORANGE;
    }
    if (normalized.scene_index >= DMD_SCENE_COUNT) {
        normalized.scene_index = 0;
    }
    if (normalized.animations_per_cycle < 1) {
        normalized.animations_per_cycle = 1;
    } else if (normalized.animations_per_cycle > 20) {
        normalized.animations_per_cycle = 20;
    }
    if (normalized.clock_display_seconds < 5) {
        normalized.clock_display_seconds = 5;
    } else if (normalized.clock_display_seconds > 3600) {
        normalized.clock_display_seconds = 3600;
    }
    if (normalized.animation_gap_seconds > 3600) {
        normalized.animation_gap_seconds = 3600;
    }
    normalized.timezone[DMD_TIMEZONE_MAX - 1] = '\0';
    normalized.wifi_ssid[DMD_WIFI_SSID_MAX] = '\0';
    normalized.wifi_password[DMD_WIFI_PASSWORD_MAX] = '\0';

    xSemaphoreTake(s_lock, portMAX_DELAY);
    normalized.revision = s_settings.revision + 1;
    s_settings = normalized;
    xSemaphoreGive(s_lock);

    dmd_settings_apply_timezone(normalized.timezone);

    nvs_handle_t handle;
    esp_err_t error = nvs_open(NAMESPACE, NVS_READWRITE, &handle);
    if (error != ESP_OK) {
        return error;
    }
    if ((error = nvs_set_u8(handle, "brightness", normalized.brightness)) == ESP_OK &&
        (error = nvs_set_u8(handle, "glow", normalized.glow_strength)) == ESP_OK &&
        (error = nvs_set_u8(handle, "plasma_pal", normalized.plasma_palette)) == ESP_OK &&
        (error = nvs_set_u16(handle, "plasma_ms", normalized.plasma_cycle_ms)) == ESP_OK &&
        (error = nvs_set_blob(
            handle,
            "plasma_rgb",
            normalized.plasma_custom,
            sizeof(normalized.plasma_custom))) == ESP_OK &&
        (error = nvs_set_u8(handle, "hour24", normalized.use_24_hour)) == ESP_OK &&
        (error = nvs_set_u8(handle, "seconds", normalized.show_seconds)) == ESP_OK &&
        (error = nvs_set_u8(handle, "display", normalized.display_on)) == ESP_OK &&
        (error = nvs_set_u8(handle, "scene", normalized.play_scene)) == ESP_OK &&
        (error = nvs_set_u8(handle, "auto_cycle", normalized.automatic_cycle)) == ESP_OK &&
        (error = nvs_set_u8(handle, "random", normalized.random_playback)) == ESP_OK &&
        (error = nvs_set_u8(handle, "show_info", normalized.show_information)) == ESP_OK &&
        (error = nvs_set_u8(handle, "scene_sel", normalized.scene_index)) == ESP_OK &&
        (error = nvs_set_u8(handle, "anim_count", normalized.animations_per_cycle)) == ESP_OK &&
        (error = nvs_set_u16(handle, "clock_secs", normalized.clock_display_seconds)) == ESP_OK &&
        (error = nvs_set_u16(handle, "anim_gap", normalized.animation_gap_seconds)) == ESP_OK &&
        (error = nvs_set_u8(handle, "color", normalized.color_preset)) == ESP_OK &&
        (error = nvs_set_str(handle, "timezone", normalized.timezone)) == ESP_OK &&
        (error = nvs_set_str(handle, "wifi_ssid", normalized.wifi_ssid)) == ESP_OK &&
        (error = nvs_set_str(handle, "wifi_pass", normalized.wifi_password)) == ESP_OK) {
        error = nvs_commit(handle);
    }
    nvs_close(handle);
    if (error != ESP_OK) {
        ESP_LOGE(TAG, "Could not persist settings: %s", esp_err_to_name(error));
    }
    return error;
}

bool dmd_settings_time_is_valid(void)
{
    time_t now = time(NULL);
    struct tm value;
    localtime_r(&now, &value);
    return value.tm_year + 1900 >= 2024;
}

void dmd_settings_apply_timezone(const char *timezone)
{
    const char *value = (timezone != NULL && timezone[0] != '\0')
        ? timezone
        : "UTC0";
    setenv("TZ", value, 1);
    tzset();
}
