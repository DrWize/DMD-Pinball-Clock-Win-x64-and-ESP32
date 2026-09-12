#include "dmd_scene_metadata.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

#include "cJSON.h"
#include "dmd_storage.h"
#include "esp_log.h"
#include "mbedtls/sha256.h"
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

static bool valid_sha256(const char *value)
{
    if (value == NULL || strlen(value) != DMD_SCENE_SHA256_HEX_LENGTH) return false;
    for (size_t index = 0; index < DMD_SCENE_SHA256_HEX_LENGTH; index++) {
        if (!((value[index] >= '0' && value[index] <= '9') ||
              (value[index] >= 'a' && value[index] <= 'f') ||
              (value[index] >= 'A' && value[index] <= 'F'))) return false;
    }
    return true;
}

static void resolve_intensity(const cJSON *entry, dmd_scene_metadata_t *metadata)
{
    for (uint8_t value = 0; value < 16; value++) metadata->intensity_lut[value] = value;
    const cJSON *intensity = cJSON_GetObjectItemCaseSensitive(entry, "intensity");
    const char *mapping = json_string(intensity, "mapping");
    if (!cJSON_IsObject(intensity) || mapping == NULL || strcmp(mapping, "evenly-spaced-v1") != 0) return;
    const char *sha256 = json_string(intensity, "sha256");
    const cJSON *frame_count = cJSON_GetObjectItemCaseSensitive(intensity, "frameCount");
    const cJSON *used_values = cJSON_GetObjectItemCaseSensitive(intensity, "usedValues");
    const cJSON *output_values = cJSON_GetObjectItemCaseSensitive(intensity, "outputValues");
    if (!valid_sha256(sha256) || !cJSON_IsNumber(frame_count) || frame_count->valueint < 1 ||
        frame_count->valueint > UINT16_MAX || !cJSON_IsArray(used_values) || !cJSON_IsArray(output_values)) return;
    int count = cJSON_GetArraySize(used_values);
    if (count < 1 || count > 16 || cJSON_GetArraySize(output_values) != count) return;
    uint16_t used_mask = 0;
    int previous = -1;
    for (int index = 0; index < count; index++) {
        const cJSON *used = cJSON_GetArrayItem(used_values, index);
        const cJSON *output = cJSON_GetArrayItem(output_values, index);
        if (!cJSON_IsNumber(used) || !cJSON_IsNumber(output) ||
            used->valuedouble != used->valueint || output->valuedouble != output->valueint ||
            used->valueint < 0 || used->valueint > 15 || used->valueint <= previous ||
            output->valueint < 0 || output->valueint > 255) return;
        previous = used->valueint;
        used_mask |= (uint16_t)(1U << used->valueint);
        metadata->intensity_lut[used->valueint] = (uint8_t)((output->valueint * 15 + 127) / 255);
    }
    strlcpy(metadata->intensity_sha256, sha256, sizeof(metadata->intensity_sha256));
    metadata->intensity_frame_count = (uint16_t)frame_count->valueint;
    metadata->intensity_used_values_mask = used_mask;
    metadata->intensity_present = true;
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
    if (dmd_storage_available()) {
        FILE *file = fopen(DMD_SCENE_METADATA_PATH, "rb");
        if (file != NULL) {
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
        }
    }
#if CONFIG_DMD_QEMU
    *text = (const char *)scene_metadata_start;
    *length = (size_t)(scene_metadata_end - scene_metadata_start);
    if (*length > 0 && (*text)[*length - 1] == '\0') {
        (*length)--;
    }
    *owned = NULL;
    return ESP_OK;
#else
    return ESP_ERR_NOT_FOUND;
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
    if (file_match != NULL) resolve_intensity(file_match, metadata);

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

void dmd_scene_metadata_verify_intensity(dmd_scene_metadata_t *metadata, const uint8_t *scene_data,
                                         size_t scene_size, uint16_t frame_count, uint16_t used_values_mask)
{
    if (metadata == NULL || !metadata->intensity_present || scene_data == NULL ||
        metadata->intensity_frame_count != frame_count || metadata->intensity_used_values_mask != used_values_mask) return;
    uint8_t digest[32];
    char hex[DMD_SCENE_SHA256_HEX_LENGTH + 1];
    if (mbedtls_sha256(scene_data, scene_size, digest, 0) != 0) return;
    for (size_t index = 0; index < sizeof(digest); index++) {
        snprintf(hex + index * 2, sizeof(hex) - index * 2, "%02x", digest[index]);
    }
    metadata->intensity_verified = strcasecmp(hex, metadata->intensity_sha256) == 0;
    if (metadata->intensity_verified) ESP_LOGI(TAG, "Verified intensity mapping for %s", metadata->display_name);
}

void dmd_scene_metadata_free(dmd_scene_metadata_catalog_t *catalog)
{
    if (catalog == NULL) {
        return;
    }
    cJSON_Delete(catalog->root);
    free(catalog);
}
