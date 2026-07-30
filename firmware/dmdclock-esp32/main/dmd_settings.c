#include "dmd_settings.h"

#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "dmd_scene.h"
#include "dmd_settings_json.h"
#include "dmd_storage.h"
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
static esp_err_t s_last_nvs_save_error = ESP_OK;
static esp_err_t s_last_sd_save_error = ESP_OK;

static void set_defaults(void)
{
    memset(&s_settings, 0, sizeof(s_settings));
    s_settings.brightness = 100;
    s_settings.glow_strength = 35;
    s_settings.plasma_palette = DMD_PLASMA_NEON;
    s_settings.plasma_cycle_ms = DMD_PLASMA_CYCLE_DEFAULT_MS;
    dmd_plasma_default_stops(DMD_PLASMA_NEON, s_settings.plasma_custom);
    s_settings.basic_custom = (dmd_rgb_t){255, 112, 14};
    s_settings.gradient_custom[0] = (dmd_rgb_t){255, 43, 214};
    s_settings.gradient_custom[1] = (dmd_rgb_t){255, 209, 102};
    s_settings.raster_custom[0] = (dmd_rgb_t){53, 40, 121};
    s_settings.raster_custom[1] = (dmd_rgb_t){112, 164, 178};
    s_settings.raster_custom[2] = (dmd_rgb_t){255, 255, 255};
    s_settings.raster_custom[3] = (dmd_rgb_t){111, 61, 134};
    s_settings.use_24_hour = true;
    s_settings.show_seconds = false;
    s_settings.display_on = true;
    s_settings.reboot_weekday = 0;
    s_settings.reboot_hour = 4;
    s_settings.reboot_minute = 0;
    s_settings.play_scene = true;
    s_settings.automatic_cycle = true;
    s_settings.random_playback = false;
    s_settings.playback_log_enabled = false;
    s_settings.show_information = true;
    s_settings.information_color_mode = DMD_INFORMATION_COLOR_GREY;
    s_settings.information_custom_color = (dmd_rgb_t){144, 144, 144};
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
    s_settings.lan_only_web = true;
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

static esp_err_t finalize_settings_init(void)
{
    esp_err_t sd_error = dmd_settings_json_load(&s_settings);
    bool persist =
        sd_error == ESP_OK ||
        (sd_error == ESP_ERR_NOT_FOUND && dmd_storage_available());
    if (sd_error == ESP_OK) {
        ESP_LOGI(
            TAG,
            "Loaded editable settings from %s/settings.json",
            DMD_STORAGE_CONFIG);
    } else if (sd_error != ESP_ERR_NOT_FOUND &&
               sd_error != ESP_ERR_NOT_SUPPORTED) {
        ESP_LOGW(
            TAG,
            "SD settings ignored; keeping NVS values: %s",
            esp_err_to_name(sd_error));
    }

    if (s_settings.timezone[0] == '\0') {
        strlcpy(
            s_settings.timezone,
            "CET-1CEST,M3.5.0,M10.5.0/3",
            sizeof(s_settings.timezone));
    }
    dmd_settings_apply_timezone(s_settings.timezone);
    if (DMD_BOOTSTRAP_WIFI_SSID[0] != '\0' &&
        (strcmp(s_settings.wifi_ssid, DMD_BOOTSTRAP_WIFI_SSID) != 0 ||
         strcmp(s_settings.wifi_password, DMD_BOOTSTRAP_WIFI_PASSWORD) != 0)) {
        strlcpy(
            s_settings.wifi_ssid,
            DMD_BOOTSTRAP_WIFI_SSID,
            sizeof(s_settings.wifi_ssid));
        strlcpy(
            s_settings.wifi_password,
            DMD_BOOTSTRAP_WIFI_PASSWORD,
            sizeof(s_settings.wifi_password));
        ESP_LOGI(TAG, "Applying updated one-time bootstrap Wi-Fi credentials");
        persist = true;
    }
    if (persist) {
        esp_err_t persist_error = dmd_settings_update(&s_settings);
        if (persist_error != ESP_OK) {
            ESP_LOGW(
                TAG,
                "Boot continues without a complete settings mirror: %s",
                esp_err_to_name(persist_error));
        }
    }
    return ESP_OK;
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
        return finalize_settings_init();
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
    if (nvs_get_u8(handle, "lan_web", &value) == ESP_OK) {
        s_settings.lan_only_web = value != 0;
    }
    if (nvs_get_u8(handle, "sched_on", &value) == ESP_OK) {
        s_settings.screen_schedule_enabled = value != 0;
    }
    size_t schedule_size = sizeof(s_settings.screen_off_schedule);
    if (nvs_get_blob(
            handle,
            "sched_off",
            s_settings.screen_off_schedule,
            &schedule_size) != ESP_OK ||
        schedule_size != sizeof(s_settings.screen_off_schedule)) {
        memset(
            s_settings.screen_off_schedule,
            0,
            sizeof(s_settings.screen_off_schedule));
    }
    if (nvs_get_u8(handle, "reboot_on", &value) == ESP_OK) {
        s_settings.reboot_schedule_enabled = value != 0;
    }
    if (nvs_get_u8(handle, "reboot_day", &value) == ESP_OK &&
        value < DMD_SCHEDULE_DAY_COUNT) {
        s_settings.reboot_weekday = value;
    }
    if (nvs_get_u8(handle, "reboot_hr", &value) == ESP_OK &&
        value < DMD_SCHEDULE_HOUR_COUNT) {
        s_settings.reboot_hour = value;
    }
    if (nvs_get_u8(handle, "reboot_min", &value) == ESP_OK &&
        value < 60) {
        s_settings.reboot_minute = value;
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
    if (nvs_get_u8(handle, "play_log", &value) == ESP_OK) {
        s_settings.playback_log_enabled = value != 0;
    }
    if (nvs_get_u8(handle, "show_info", &value) == ESP_OK) {
        s_settings.show_information = value != 0;
    }
    if (nvs_get_u8(handle, "info_mode", &value) == ESP_OK &&
        value <= DMD_INFORMATION_COLOR_CUSTOM) {
        s_settings.information_color_mode =
            (dmd_information_color_mode_t)value;
    }
    size_t information_color_size =
        sizeof(s_settings.information_custom_color);
    nvs_get_blob(
        handle,
        "info_rgb",
        &s_settings.information_custom_color,
        &information_color_size);
    uint16_t word = 0;
    if (nvs_get_u16(handle, "scene_sel", &word) == ESP_OK &&
        word < DMD_SCENE_MAX_COUNT) {
        s_settings.scene_index = word;
    } else if (nvs_get_u8(handle, "scene_sel", &value) == ESP_OK) {
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
    size_t basic_custom_size = sizeof(s_settings.basic_custom);
    nvs_get_blob(
        handle,
        "basic_rgb",
        &s_settings.basic_custom,
        &basic_custom_size);
    size_t gradient_custom_size = sizeof(s_settings.gradient_custom);
    nvs_get_blob(
        handle,
        "grad_rgb",
        s_settings.gradient_custom,
        &gradient_custom_size);
    size_t raster_custom_size = sizeof(s_settings.raster_custom);
    nvs_get_blob(
        handle,
        "raster_rgb",
        s_settings.raster_custom,
        &raster_custom_size);
    load_string(handle, "timezone", s_settings.timezone, sizeof(s_settings.timezone));
    load_string(handle, "wifi_ssid", s_settings.wifi_ssid, sizeof(s_settings.wifi_ssid));
    load_string(handle, "wifi_pass", s_settings.wifi_password, sizeof(s_settings.wifi_password));
    nvs_close(handle);

    return finalize_settings_init();
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
    if (normalized.information_color_mode >
        DMD_INFORMATION_COLOR_CUSTOM) {
        normalized.information_color_mode =
            DMD_INFORMATION_COLOR_GREY;
    }
    if (normalized.scene_index >= DMD_SCENE_MAX_COUNT) {
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
    if (normalized.reboot_weekday >= DMD_SCHEDULE_DAY_COUNT) {
        normalized.reboot_weekday = 0;
    }
    if (normalized.reboot_hour >= DMD_SCHEDULE_HOUR_COUNT) {
        normalized.reboot_hour = 4;
    }
    if (normalized.reboot_minute >= 60) {
        normalized.reboot_minute = 0;
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
        s_last_nvs_save_error = error;
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
        (error = nvs_set_blob(
            handle,
            "basic_rgb",
            &normalized.basic_custom,
            sizeof(normalized.basic_custom))) == ESP_OK &&
        (error = nvs_set_blob(
            handle,
            "grad_rgb",
            normalized.gradient_custom,
            sizeof(normalized.gradient_custom))) == ESP_OK &&
        (error = nvs_set_blob(
            handle,
            "raster_rgb",
            normalized.raster_custom,
            sizeof(normalized.raster_custom))) == ESP_OK &&
        (error = nvs_set_u8(handle, "hour24", normalized.use_24_hour)) == ESP_OK &&
        (error = nvs_set_u8(handle, "seconds", normalized.show_seconds)) == ESP_OK &&
        (error = nvs_set_u8(handle, "display", normalized.display_on)) == ESP_OK &&
        (error = nvs_set_u8(handle, "lan_web", normalized.lan_only_web)) == ESP_OK &&
        (error = nvs_set_u8(
            handle,
            "sched_on",
            normalized.screen_schedule_enabled)) == ESP_OK &&
        (error = nvs_set_blob(
            handle,
            "sched_off",
            normalized.screen_off_schedule,
            sizeof(normalized.screen_off_schedule))) == ESP_OK &&
        (error = nvs_set_u8(
            handle,
            "reboot_on",
            normalized.reboot_schedule_enabled)) == ESP_OK &&
        (error = nvs_set_u8(
            handle,
            "reboot_day",
            normalized.reboot_weekday)) == ESP_OK &&
        (error = nvs_set_u8(
            handle,
            "reboot_hr",
            normalized.reboot_hour)) == ESP_OK &&
        (error = nvs_set_u8(
            handle,
            "reboot_min",
            normalized.reboot_minute)) == ESP_OK &&
        (error = nvs_set_u8(handle, "scene", normalized.play_scene)) == ESP_OK &&
        (error = nvs_set_u8(handle, "auto_cycle", normalized.automatic_cycle)) == ESP_OK &&
        (error = nvs_set_u8(handle, "random", normalized.random_playback)) == ESP_OK &&
        (error = nvs_set_u8(
            handle,
            "play_log",
            normalized.playback_log_enabled)) == ESP_OK &&
        (error = nvs_set_u8(handle, "show_info", normalized.show_information)) == ESP_OK &&
        (error = nvs_set_u8(
            handle,
            "info_mode",
            normalized.information_color_mode)) == ESP_OK &&
        (error = nvs_set_blob(
            handle,
            "info_rgb",
            &normalized.information_custom_color,
            sizeof(normalized.information_custom_color))) == ESP_OK &&
        (error = nvs_set_u16(handle, "scene_sel", normalized.scene_index)) == ESP_OK &&
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
    s_last_nvs_save_error = error;
    if (error != ESP_OK) {
        ESP_LOGE(TAG, "Could not persist settings: %s", esp_err_to_name(error));
        return error;
    }
    esp_err_t sd_error = dmd_settings_json_save(&normalized);
    s_last_sd_save_error = sd_error == ESP_ERR_NOT_SUPPORTED
        ? ESP_OK
        : sd_error;
    if (sd_error != ESP_OK && sd_error != ESP_ERR_NOT_SUPPORTED) {
        ESP_LOGE(
            TAG,
            "Could not persist SD settings: %s",
            esp_err_to_name(sd_error));
        return sd_error;
    }
    return ESP_OK;
}

esp_err_t dmd_settings_last_nvs_save_error(void)
{
    return s_last_nvs_save_error;
}

esp_err_t dmd_settings_last_sd_save_error(void)
{
    return s_last_sd_save_error;
}

bool dmd_settings_time_is_valid(void)
{
    time_t now = time(NULL);
    struct tm value;
    localtime_r(&now, &value);
    return value.tm_year + 1900 >= 2024;
}

bool dmd_settings_screen_scheduled_off(
    const dmd_settings_t *settings,
    time_t now)
{
    if (settings == NULL ||
        !settings->screen_schedule_enabled) {
        return false;
    }

    struct tm local;
    localtime_r(&now, &local);
    if (local.tm_year + 1900 < 2024) {
        return false;
    }
    size_t slot =
        (size_t)local.tm_wday * DMD_SCHEDULE_HOUR_COUNT +
        (size_t)local.tm_hour;
    return (
        settings->screen_off_schedule[slot / 8] &
        (uint8_t)(1U << (slot % 8))) != 0;
}

bool dmd_settings_claim_scheduled_reboot(
    const dmd_settings_t *settings,
    time_t now)
{
    if (settings == NULL ||
        !settings->reboot_schedule_enabled) {
        return false;
    }

    struct tm local;
    localtime_r(&now, &local);
    if (local.tm_year + 1900 < 2024 ||
        local.tm_wday != settings->reboot_weekday ||
        local.tm_hour != settings->reboot_hour ||
        local.tm_min != settings->reboot_minute) {
        return false;
    }

    uint32_t today =
        (uint32_t)(local.tm_year + 1900) * 10000U +
        (uint32_t)(local.tm_mon + 1) * 100U +
        (uint32_t)local.tm_mday;
    nvs_handle_t handle;
    if (nvs_open(NAMESPACE, NVS_READWRITE, &handle) != ESP_OK) {
        return false;
    }
    uint32_t previous = 0;
    if (nvs_get_u32(handle, "reboot_mark", &previous) == ESP_OK &&
        previous == today) {
        nvs_close(handle);
        return false;
    }
    esp_err_t error = nvs_set_u32(handle, "reboot_mark", today);
    if (error == ESP_OK) {
        error = nvs_commit(handle);
    }
    nvs_close(handle);
    if (error != ESP_OK) {
        ESP_LOGE(
            TAG,
            "Could not persist scheduled reboot marker: %s",
            esp_err_to_name(error));
        return false;
    }
    return true;
}

void dmd_settings_apply_timezone(const char *timezone)
{
    const char *value = (timezone != NULL && timezone[0] != '\0')
        ? timezone
        : "UTC0";
    setenv("TZ", value, 1);
    tzset();
}
