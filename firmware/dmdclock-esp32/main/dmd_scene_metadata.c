#include "dmd_scene_metadata.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

#include "cJSON.h"
#include "dmd_storage.h"
#include "esp_log.h"
#include "sdkconfig.h"

#define DMD_SCENE_METADATA_PATH DMD_STORAGE_SCENES "/scene-metadata.json"

struct dmd_scene_metadata_catalog {
    cJSON *root;
};

static const char *TAG = "dmd_scene_metadata";

#if CONFIG_DMD_QEMU
extern const uint8_t scene_metadata_start[]
    asm("_binary_scene_metadata_json_start");
extern const uint8_t scene_metadata_end[]
    asm("_binary_scene_metadata_json_end");
#endif

static const char *json_string(const cJSON *object, const char *name)
{
    if (object == NULL) {
        return NULL;
    }
    const cJSON *item = cJSON_GetObjectItemCaseSensitive(object, name);
    return cJSON_IsString(item) && item->valuestring != NULL
        ? item->valuestring
        : NULL;
}

static uint16_t json_year(const cJSON *object)
{
    if (object == NULL) {
        return 0;
    }
    const cJSON *item = cJSON_GetObjectItemCaseSensitive(object, "year");
    return cJSON_IsNumber(item) && item->valueint >= 1930 &&
                   item->valueint <= 2200
        ? (uint16_t)item->valueint
        : 0;
}

static void copy_if_set(char *target, size_t capacity, const char *value)
{
    if (value != NULL && value[0] != '\0') {
        strlcpy(target, value, capacity);
    }
}

static void base_name_without_extension(
    const char *file_name,
    char *buffer,
    size_t capacity)
{
    const char *slash = strrchr(file_name, '/');
    const char *base = slash == NULL ? file_name : slash + 1;
    strlcpy(buffer, base, capacity);
    char *extension = strrchr(buffer, '.');
    if (extension != NULL) {
        *extension = '\0';
    }
}

static bool starts_with_case_insensitive(const char *value, const char *prefix)
{
    size_t prefix_length = strlen(prefix);
    return strncasecmp(value, prefix, prefix_length) == 0;
}

static esp_err_t load_text(const char **text, size_t *length, char **owned)
{
#if CONFIG_DMD_QEMU
    *text = (const char *)scene_metadata_start;
    *length = (size_t)(scene_metadata_end - scene_metadata_start);
    if (*length > 0 && (*text)[*length - 1] == '\0') {
        (*length)--;
    }
    *owned = NULL;
    return ESP_OK;
#else
    FILE *file = fopen(DMD_SCENE_METADATA_PATH, "rb");
    if (file == NULL) {
        return ESP_ERR_NOT_FOUND;
    }
    if (fseek(file, 0, SEEK_END) != 0) {
        fclose(file);
        return ESP_FAIL;
    }
    long file_length = ftell(file);
    if (file_length <= 0 || fseek(file, 0, SEEK_SET) != 0) {
        fclose(file);
        return ESP_ERR_INVALID_SIZE;
    }
    char *buffer = malloc((size_t)file_length + 1);
    if (buffer == NULL) {
        fclose(file);
        return ESP_ERR_NO_MEM;
    }
    size_t read = fread(buffer, 1, (size_t)file_length, file);
    fclose(file);
    if (read != (size_t)file_length) {
        free(buffer);
        return ESP_FAIL;
    }
    buffer[file_length] = '\0';
    *text = buffer;
    *length = (size_t)file_length;
    *owned = buffer;
    return ESP_OK;
#endif
}

esp_err_t dmd_scene_metadata_load(dmd_scene_metadata_catalog_t **catalog)
{
    if (catalog == NULL) {
        return ESP_ERR_INVALID_ARG;
    }
    *catalog = NULL;
    const char *text = NULL;
    size_t length = 0;
    char *owned = NULL;
    esp_err_t error = load_text(&text, &length, &owned);
    if (error != ESP_OK) {
        ESP_LOGW(
            TAG,
            "%s unavailable; scene filenames remain usable",
            DMD_SCENE_METADATA_PATH);
        return error;
    }

    cJSON *root = cJSON_ParseWithLength(text, length);
    free(owned);
    if (root == NULL) {
        ESP_LOGW(TAG, "Scene metadata JSON is invalid");
        return ESP_ERR_INVALID_RESPONSE;
    }
    const cJSON *schema =
        cJSON_GetObjectItemCaseSensitive(root, "schemaVersion");
    if (!cJSON_IsNumber(schema) || schema->valueint != 1) {
        cJSON_Delete(root);
        ESP_LOGW(TAG, "Unsupported scene metadata schema");
        return ESP_ERR_INVALID_VERSION;
    }
    dmd_scene_metadata_catalog_t *loaded = malloc(sizeof(*loaded));
    if (loaded == NULL) {
        cJSON_Delete(root);
        return ESP_ERR_NO_MEM;
    }
    loaded->root = root;
    *catalog = loaded;
    ESP_LOGI(TAG, "Shared scene metadata schema 1 loaded");
    return ESP_OK;
}

void dmd_scene_metadata_resolve(
    const dmd_scene_metadata_catalog_t *catalog,
    const char *file_name,
    dmd_scene_metadata_t *metadata)
{
    if (file_name == NULL || metadata == NULL) {
        return;
    }
    memset(metadata, 0, sizeof(*metadata));
    char base_name[DMD_SCENE_TITLE_MAX];
    base_name_without_extension(file_name, base_name, sizeof(base_name));
    strlcpy(metadata->display_name, base_name, sizeof(metadata->display_name));
    if (catalog == NULL || catalog->root == NULL) {
        return;
    }

    const cJSON *file_match = NULL;
    const cJSON *files =
        cJSON_GetObjectItemCaseSensitive(catalog->root, "files");
    const cJSON *entry = NULL;
    cJSON_ArrayForEach(entry, files) {
        const char *path = json_string(entry, "path");
        if (path != NULL && strcasecmp(path, file_name) == 0) {
            file_match = entry;
            break;
        }
    }

    const cJSON *prefix_match = NULL;
    size_t longest_prefix = 0;
    const cJSON *prefixes =
        cJSON_GetObjectItemCaseSensitive(catalog->root, "prefixes");
    cJSON_ArrayForEach(entry, prefixes) {
        const char *prefix = json_string(entry, "prefix");
        if (prefix != NULL && strlen(prefix) > longest_prefix &&
            starts_with_case_insensitive(base_name, prefix)) {
            prefix_match = entry;
            longest_prefix = strlen(prefix);
        }
    }

    copy_if_set(
        metadata->title,
        sizeof(metadata->title),
        json_string(file_match, "title"));
    const char *game = json_string(file_match, "game");
    if (game == NULL) {
        game = json_string(prefix_match, "game");
    }
    copy_if_set(metadata->game, sizeof(metadata->game), game);
    const char *manufacturer = json_string(file_match, "manufacturer");
    if (manufacturer == NULL) {
        manufacturer = json_string(prefix_match, "manufacturer");
    }
    copy_if_set(
        metadata->manufacturer,
        sizeof(metadata->manufacturer),
        manufacturer);
    metadata->year = json_year(file_match);
    if (metadata->year == 0) {
        metadata->year = json_year(prefix_match);
    }
    metadata->catalog_match = file_match != NULL || prefix_match != NULL;

    if (metadata->title[0] != '\0') {
        strlcpy(
            metadata->display_name,
            metadata->title,
            sizeof(metadata->display_name));
    } else if (metadata->game[0] != '\0') {
        snprintf(
            metadata->display_name,
            sizeof(metadata->display_name),
            "%s — %s",
            metadata->game,
            base_name);
    }
}

void dmd_scene_metadata_free(dmd_scene_metadata_catalog_t *catalog)
{
    if (catalog == NULL) {
        return;
    }
    cJSON_Delete(catalog->root);
    free(catalog);
}
