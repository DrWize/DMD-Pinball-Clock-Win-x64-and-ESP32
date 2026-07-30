#include "dmd_settings_json.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "cJSON.h"
#include "dmd_storage.h"

#define SETTINGS_PATH DMD_STORAGE_CONFIG "/settings.json"
#define SETTINGS_TEMP_PATH DMD_STORAGE_CONFIG "/settings.tmp"
#define SETTINGS_SCHEMA_VERSION 1
#define SETTINGS_MAX_BYTES (16 * 1024)

static bool parse_rgb(const char *text, dmd_rgb_t *output)
{
    unsigned red;
    unsigned green;
    unsigned blue;
    if (text == NULL || output == NULL || strlen(text) != 7 ||
        sscanf(text, "#%02x%02x%02x", &red, &green, &blue) != 3) {
        return false;
    }
    output->red = (uint8_t)red;
    output->green = (uint8_t)green;
    output->blue = (uint8_t)blue;
    return true;
}

static void add_rgb(cJSON *json, const char *name, dmd_rgb_t color)
{
    char value[8];
    snprintf(
        value,
        sizeof(value),
        "#%02X%02X%02X",
        color.red,
        color.green,
        color.blue);
    cJSON_AddStringToObject(json, name, value);
}

static void add_rgb_array(
    cJSON *json,
    const char *name,
    const dmd_rgb_t *colors,
    uint8_t count)
{
    cJSON *array = cJSON_AddArrayToObject(json, name);
    for (uint8_t index = 0; index < count; index++) {
        char value[8];
        snprintf(
            value,
            sizeof(value),
            "#%02X%02X%02X",
            colors[index].red,
            colors[index].green,
            colors[index].blue);
        cJSON_AddItemToArray(array, cJSON_CreateString(value));
    }
}

static void load_bool(cJSON *json, const char *name, bool *value)
{
    cJSON *item = cJSON_GetObjectItemCaseSensitive(json, name);
    if (cJSON_IsBool(item)) {
        *value = cJSON_IsTrue(item);
    }
}

static void load_u8(cJSON *json, const char *name, uint8_t *value)
{
    cJSON *item = cJSON_GetObjectItemCaseSensitive(json, name);
    if (cJSON_IsNumber(item) &&
        item->valueint >= 0 &&
        item->valueint <= UINT8_MAX) {
        *value = (uint8_t)item->valueint;
    }
}

static void load_u16(cJSON *json, const char *name, uint16_t *value)
{
    cJSON *item = cJSON_GetObjectItemCaseSensitive(json, name);
    if (cJSON_IsNumber(item) &&
        item->valueint >= 0 &&
        item->valueint <= UINT16_MAX) {
        *value = (uint16_t)item->valueint;
    }
}

static void load_string(
    cJSON *json,
    const char *name,
    char *value,
    size_t capacity)
{
    cJSON *item = cJSON_GetObjectItemCaseSensitive(json, name);
    if (cJSON_IsString(item)) {
        strlcpy(value, item->valuestring, capacity);
    }
}

static void load_rgb(cJSON *json, const char *name, dmd_rgb_t *value)
{
    cJSON *item = cJSON_GetObjectItemCaseSensitive(json, name);
    dmd_rgb_t parsed;
    if (cJSON_IsString(item) && parse_rgb(item->valuestring, &parsed)) {
        *value = parsed;
    }
}

static void load_rgb_array(
    cJSON *json,
    const char *name,
    dmd_rgb_t *colors,
    uint8_t count)
{
    cJSON *array = cJSON_GetObjectItemCaseSensitive(json, name);
    if (!cJSON_IsArray(array) || cJSON_GetArraySize(array) != count) {
        return;
    }
    dmd_rgb_t parsed[DMD_PLASMA_STOP_COUNT];
    if (count > DMD_PLASMA_STOP_COUNT) {
        return;
    }
    for (uint8_t index = 0; index < count; index++) {
        cJSON *item = cJSON_GetArrayItem(array, index);
        if (!cJSON_IsString(item) ||
            !parse_rgb(item->valuestring, &parsed[index])) {
            return;
        }
    }
    memcpy(colors, parsed, count * sizeof(colors[0]));
}

static void load_schedule(cJSON *json, uint8_t *schedule)
{
    cJSON *array =
        cJSON_GetObjectItemCaseSensitive(json, "screenOffSchedule");
    if (!cJSON_IsArray(array) ||
        cJSON_GetArraySize(array) != DMD_SCHEDULE_DAY_COUNT) {
        return;
    }
    uint8_t parsed[DMD_SCHEDULE_BYTES] = {0};
    for (uint8_t day = 0; day < DMD_SCHEDULE_DAY_COUNT; day++) {
        cJSON *row = cJSON_GetArrayItem(array, day);
        if (!cJSON_IsString(row) ||
            strlen(row->valuestring) != DMD_SCHEDULE_HOUR_COUNT) {
            return;
        }
        for (uint8_t hour = 0; hour < DMD_SCHEDULE_HOUR_COUNT; hour++) {
            char value = row->valuestring[hour];
            if (value != '0' && value != '1') {
                return;
            }
            if (value == '1') {
                size_t slot =
                    (size_t)day * DMD_SCHEDULE_HOUR_COUNT + hour;
                parsed[slot / 8] |= (uint8_t)(1U << (slot % 8));
            }
        }
    }
    memcpy(schedule, parsed, sizeof(parsed));
}

static cJSON *settings_to_json(const dmd_settings_t *settings)
{
    cJSON *json = cJSON_CreateObject();
    if (json == NULL) {
        return NULL;
    }
    cJSON_AddNumberToObject(json, "schemaVersion", SETTINGS_SCHEMA_VERSION);
    cJSON_AddStringToObject(
        json,
        "_notice",
        "Editable DMDClock backup. Contains the Wi-Fi password in plain text.");
    cJSON_AddNumberToObject(json, "brightness", settings->brightness);
    cJSON_AddNumberToObject(json, "glowStrength", settings->glow_strength);
    cJSON_AddNumberToObject(json, "colorPreset", settings->color_preset);
    cJSON_AddNumberToObject(json, "plasmaPalette", settings->plasma_palette);
    cJSON_AddNumberToObject(
        json,
        "plasmaCycleMilliseconds",
        settings->plasma_cycle_ms);
    add_rgb_array(
        json,
        "plasmaCustomColors",
        settings->plasma_custom,
        DMD_PLASMA_STOP_COUNT);
    add_rgb_array(json, "basicCustomColors", &settings->basic_custom, 1);
    add_rgb_array(
        json,
        "gradientCustomColors",
        settings->gradient_custom,
        DMD_GRADIENT_CUSTOM_COLOR_COUNT);
    add_rgb_array(
        json,
        "rasterCustomColors",
        settings->raster_custom,
        DMD_RASTER_CUSTOM_COLOR_COUNT);
    cJSON_AddBoolToObject(json, "use24Hour", settings->use_24_hour);
    cJSON_AddBoolToObject(json, "showSeconds", settings->show_seconds);
    cJSON_AddBoolToObject(json, "displayOn", settings->display_on);
    cJSON_AddBoolToObject(json, "playScene", settings->play_scene);
    cJSON_AddNumberToObject(json, "sceneIndex", settings->scene_index);
    cJSON_AddBoolToObject(
        json,
        "automaticCycle",
        settings->automatic_cycle);
    cJSON_AddBoolToObject(
        json,
        "randomPlayback",
        settings->random_playback);
    cJSON_AddBoolToObject(
        json,
        "playbackLogEnabled",
        settings->playback_log_enabled);
    cJSON_AddNumberToObject(
        json,
        "animationsPerCycle",
        settings->animations_per_cycle);
    cJSON_AddNumberToObject(
        json,
        "clockDisplaySeconds",
        settings->clock_display_seconds);
    cJSON_AddNumberToObject(
        json,
        "animationGapSeconds",
        settings->animation_gap_seconds);
    cJSON_AddBoolToObject(
        json,
        "showInformation",
        settings->show_information);
    cJSON_AddNumberToObject(
        json,
        "informationColorMode",
        settings->information_color_mode);
    add_rgb(
        json,
        "informationCustomColor",
        settings->information_custom_color);
    cJSON_AddBoolToObject(
        json,
        "screenScheduleEnabled",
        settings->screen_schedule_enabled);
    cJSON *schedule = cJSON_AddArrayToObject(json, "screenOffSchedule");
    for (uint8_t day = 0; day < DMD_SCHEDULE_DAY_COUNT; day++) {
        char row[DMD_SCHEDULE_HOUR_COUNT + 1];
        for (uint8_t hour = 0; hour < DMD_SCHEDULE_HOUR_COUNT; hour++) {
            size_t slot =
                (size_t)day * DMD_SCHEDULE_HOUR_COUNT + hour;
            row[hour] =
                (settings->screen_off_schedule[slot / 8] &
                 (uint8_t)(1U << (slot % 8))) != 0
                    ? '1'
                    : '0';
        }
        row[DMD_SCHEDULE_HOUR_COUNT] = '\0';
        cJSON_AddItemToArray(schedule, cJSON_CreateString(row));
    }
    cJSON_AddBoolToObject(
        json,
        "rebootScheduleEnabled",
        settings->reboot_schedule_enabled);
    cJSON_AddNumberToObject(
        json,
        "rebootWeekday",
        settings->reboot_weekday);
    cJSON_AddNumberToObject(json, "rebootHour", settings->reboot_hour);
    cJSON_AddNumberToObject(json, "rebootMinute", settings->reboot_minute);
    cJSON_AddStringToObject(json, "timezone", settings->timezone);
    cJSON_AddStringToObject(json, "wifiSsid", settings->wifi_ssid);
    cJSON_AddStringToObject(json, "wifiPassword", settings->wifi_password);
    return json;
}

esp_err_t dmd_settings_json_load(dmd_settings_t *settings)
{
    if (settings == NULL) {
        return ESP_ERR_INVALID_ARG;
    }
    if (!dmd_storage_available()) {
        return ESP_ERR_NOT_SUPPORTED;
    }
    FILE *file = fopen(SETTINGS_PATH, "rb");
    if (file == NULL) {
        return ESP_ERR_NOT_FOUND;
    }
    if (fseek(file, 0, SEEK_END) != 0) {
        fclose(file);
        return ESP_FAIL;
    }
    long length = ftell(file);
    if (length <= 0 || length > SETTINGS_MAX_BYTES ||
        fseek(file, 0, SEEK_SET) != 0) {
        fclose(file);
        return ESP_ERR_INVALID_SIZE;
    }
    char *text = malloc((size_t)length + 1);
    if (text == NULL) {
        fclose(file);
        return ESP_ERR_NO_MEM;
    }
    size_t read = fread(text, 1, (size_t)length, file);
    fclose(file);
    if (read != (size_t)length) {
        free(text);
        return ESP_FAIL;
    }
    text[length] = '\0';
    cJSON *json = cJSON_ParseWithLength(text, (size_t)length);
    free(text);
    if (json == NULL) {
        return ESP_ERR_INVALID_RESPONSE;
    }
    cJSON *schema = cJSON_GetObjectItemCaseSensitive(json, "schemaVersion");
    if (!cJSON_IsNumber(schema) ||
        schema->valueint != SETTINGS_SCHEMA_VERSION) {
        cJSON_Delete(json);
        return ESP_ERR_INVALID_VERSION;
    }

    load_u8(json, "brightness", &settings->brightness);
    load_u8(json, "glowStrength", &settings->glow_strength);
    uint8_t color_preset = (uint8_t)settings->color_preset;
    load_u8(json, "colorPreset", &color_preset);
    settings->color_preset = (dmd_color_preset_t)color_preset;
    uint8_t plasma_palette = (uint8_t)settings->plasma_palette;
    load_u8(json, "plasmaPalette", &plasma_palette);
    settings->plasma_palette = (dmd_plasma_palette_t)plasma_palette;
    load_u16(
        json,
        "plasmaCycleMilliseconds",
        &settings->plasma_cycle_ms);
    load_rgb_array(
        json,
        "plasmaCustomColors",
        settings->plasma_custom,
        DMD_PLASMA_STOP_COUNT);
    load_rgb_array(json, "basicCustomColors", &settings->basic_custom, 1);
    load_rgb_array(
        json,
        "gradientCustomColors",
        settings->gradient_custom,
        DMD_GRADIENT_CUSTOM_COLOR_COUNT);
    load_rgb_array(
        json,
        "rasterCustomColors",
        settings->raster_custom,
        DMD_RASTER_CUSTOM_COLOR_COUNT);
    load_bool(json, "use24Hour", &settings->use_24_hour);
    load_bool(json, "showSeconds", &settings->show_seconds);
    load_bool(json, "displayOn", &settings->display_on);
    load_bool(json, "playScene", &settings->play_scene);
    load_u16(json, "sceneIndex", &settings->scene_index);
    load_bool(json, "automaticCycle", &settings->automatic_cycle);
    load_bool(json, "randomPlayback", &settings->random_playback);
    load_bool(
        json,
        "playbackLogEnabled",
        &settings->playback_log_enabled);
    load_u8(
        json,
        "animationsPerCycle",
        &settings->animations_per_cycle);
    load_u16(
        json,
        "clockDisplaySeconds",
        &settings->clock_display_seconds);
    load_u16(
        json,
        "animationGapSeconds",
        &settings->animation_gap_seconds);
    load_bool(json, "showInformation", &settings->show_information);
    uint8_t information_color_mode =
        (uint8_t)settings->information_color_mode;
    load_u8(
        json,
        "informationColorMode",
        &information_color_mode);
    settings->information_color_mode =
        (dmd_information_color_mode_t)information_color_mode;
    load_rgb(
        json,
        "informationCustomColor",
        &settings->information_custom_color);
    load_bool(
        json,
        "screenScheduleEnabled",
        &settings->screen_schedule_enabled);
    load_schedule(json, settings->screen_off_schedule);
    load_bool(
        json,
        "rebootScheduleEnabled",
        &settings->reboot_schedule_enabled);
    load_u8(json, "rebootWeekday", &settings->reboot_weekday);
    load_u8(json, "rebootHour", &settings->reboot_hour);
    load_u8(json, "rebootMinute", &settings->reboot_minute);
    load_string(
        json,
        "timezone",
        settings->timezone,
        sizeof(settings->timezone));
    load_string(
        json,
        "wifiSsid",
        settings->wifi_ssid,
        sizeof(settings->wifi_ssid));
    load_string(
        json,
        "wifiPassword",
        settings->wifi_password,
        sizeof(settings->wifi_password));
    cJSON_Delete(json);
    return ESP_OK;
}

esp_err_t dmd_settings_json_save(const dmd_settings_t *settings)
{
    if (settings == NULL) {
        return ESP_ERR_INVALID_ARG;
    }
    if (!dmd_storage_available()) {
        return ESP_ERR_NOT_SUPPORTED;
    }
    cJSON *json = settings_to_json(settings);
    if (json == NULL) {
        return ESP_ERR_NO_MEM;
    }
    char *text = cJSON_Print(json);
    cJSON_Delete(json);
    if (text == NULL) {
        return ESP_ERR_NO_MEM;
    }
    FILE *file = fopen(SETTINGS_TEMP_PATH, "wb");
    if (file == NULL) {
        free(text);
        return ESP_FAIL;
    }
    size_t length = strlen(text);
    bool written =
        fwrite(text, 1, length, file) == length &&
        fwrite("\n", 1, 1, file) == 1 &&
        fflush(file) == 0;
    free(text);
    if (fclose(file) != 0 || !written) {
        remove(SETTINGS_TEMP_PATH);
        return ESP_FAIL;
    }
    if (rename(SETTINGS_TEMP_PATH, SETTINGS_PATH) != 0) {
        remove(SETTINGS_PATH);
        if (rename(SETTINGS_TEMP_PATH, SETTINGS_PATH) != 0) {
            remove(SETTINGS_TEMP_PATH);
            return ESP_FAIL;
        }
    }
    return ESP_OK;
}
