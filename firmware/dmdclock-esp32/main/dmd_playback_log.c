#include "dmd_playback_log.h"

#include <stdio.h>
#include <string.h>
#include <time.h>

#include "dmd_color.h"
#include "dmd_plasma.h"
#include "dmd_scene.h"
#include "dmd_scene_metadata.h"
#include "dmd_storage.h"
#include "esp_log.h"
#include "esp_timer.h"

#define PLAYBACK_LOG_MAX_BYTES (256 * 1024)
#define PLAYBACK_LOG_PREVIOUS_PATH DMD_STORAGE_LOGS "/playback.previous.log"

static const char *TAG = "dmd_playback_log";

static bool logging_enabled(void)
{
    dmd_settings_t settings;
    dmd_settings_get(&settings);
    return settings.playback_log_enabled && dmd_storage_available();
}

static void timestamp(char *output, size_t capacity)
{
    time_t now = time(NULL);
    if (now >= 1704067200) {
        struct tm local;
        localtime_r(&now, &local);
        strftime(output, capacity, "%Y-%m-%dT%H:%M:%S%z", &local);
    } else {
        snprintf(
            output,
            capacity,
            "uptime:%llu",
            (unsigned long long)(esp_timer_get_time() / 1000000));
    }
}

static FILE *open_log(void)
{
    FILE *file = fopen(DMD_PLAYBACK_LOG_PATH, "ab+");
    if (file == NULL) {
        ESP_LOGW(TAG, "Could not open %s", DMD_PLAYBACK_LOG_PATH);
        return NULL;
    }
    if (fseek(file, 0, SEEK_END) == 0 &&
        ftell(file) > PLAYBACK_LOG_MAX_BYTES) {
        fclose(file);
        remove(PLAYBACK_LOG_PREVIOUS_PATH);
        rename(DMD_PLAYBACK_LOG_PATH, PLAYBACK_LOG_PREVIOUS_PATH);
        file = fopen(DMD_PLAYBACK_LOG_PATH, "ab+");
    }
    return file;
}

static void clean_field(char *value)
{
    for (; *value != '\0'; value++) {
        if (*value == '\t' || *value == '\r' || *value == '\n') {
            *value = ' ';
        }
    }
}

void dmd_playback_log_scene(uint16_t scene_index)
{
    if (!logging_enabled()) {
        return;
    }
    dmd_scene_metadata_t metadata;
    dmd_scene_get_metadata(scene_index, &metadata);
    clean_field(metadata.game);
    clean_field(metadata.title);
    char when[40];
    timestamp(when, sizeof(when));
    FILE *file = open_log();
    if (file == NULL) {
        return;
    }
    fprintf(
        file,
        "%s\tSCENE\t%u\t%s\t%s\t%s\n",
        when,
        scene_index,
        dmd_scene_file_name(scene_index),
        metadata.game,
        metadata.title);
    fclose(file);
}

void dmd_playback_log_theme(const dmd_settings_t *settings)
{
    if (settings == NULL || !logging_enabled()) {
        return;
    }
    char when[40];
    timestamp(when, sizeof(when));
    FILE *file = open_log();
    if (file == NULL) {
        return;
    }
    const char *subtheme = settings->color_preset == DMD_COLOR_PLASMA
        ? dmd_plasma_palette_name(settings->plasma_palette)
        : dmd_color_name(settings->color_preset);
    fprintf(
        file,
        "%s\tTHEME\t%s\t%s\n",
        when,
        dmd_color_family(settings->color_preset),
        subtheme);
    fclose(file);
}
