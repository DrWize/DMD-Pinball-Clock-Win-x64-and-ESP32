#include "dmd_scene_pack.h"

#include <dirent.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include <unistd.h>

#include "cJSON.h"
#include "dmd_storage.h"
#include "esp_check.h"
#include "esp_crt_bundle.h"
#include "esp_http_client.h"
#include "esp_heap_caps.h"
#include "esp_log.h"
#include "esp_system.h"
#include "esp_vfs_fat.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"
#include "mbedtls/sha256.h"
#include "sdkconfig.h"
#include "zlib.h"

#define CATALOG_URL \
    "https://raw.githubusercontent.com/DrWize/" \
    "DMD-Pinball-Clock-Win-x64-and-ESP32/master/scenes/catalog.json"
#define CATALOG_FALLBACK_URL \
    "https://github.com/DrWize/DMD-Pinball-Clock-Win-x64-and-ESP32/" \
    "releases/download/scene-pack-v2026.08.10/DMDClock-scene-packs-catalog.json"
#define ORIGINAL_PACK_ID "dotclk-original"
#define LARGE_PACK_ID "drwize-complete"
#define ORIGINAL_DISPLAY_NAME "Original DotCLK-Orig"
#define LARGE_DISPLAY_NAME "DMD-Large"
#define ORIGINAL_VERSION "11211af"
#define LARGE_VERSION "2026.08.10"
#define WORK_DIR DMD_STORAGE_ROOT "/scene-pack"
#define ARCHIVE_PATH WORK_DIR "/download.zip.part"
#define STAGING_DIR DMD_STORAGE_ROOT "/scenes.new"
#define BACKUP_DIR DMD_STORAGE_ROOT "/scenes.previous"
#define MANAGED_SCENES_FILE "managed-scenes.txt"
#define INSTALLED_PACK_PATH DMD_STORAGE_CONFIG "/scene-pack-installed.json"
#define INSTALLED_PACK_TEMP DMD_STORAGE_CONFIG "/scene-pack-installed.tmp"
#define MAX_CATALOG_BYTES (1024 * 1024)
#define MAX_ARCHIVE_BYTES (512ULL * 1024 * 1024)
#define MAX_ENTRY_BYTES (16U * 1024 * 1024)
#define IO_BUFFER_SIZE 16384
#define ZIP_LOCAL_HEADER 0x04034b50U
#define ZIP_CENTRAL_HEADER 0x02014b50U
#define SCN_HEADER_SIZE 6
#define SCN_STORYBOARD_SIZE 36
#define SCN_FRAME_HEADER_SIZE 8
#define SCN_PACKED_PIXEL_SIZE (128U * 32U / 2U)
#define SCN_MASK_SIZE (128U * 32U / 8U)
#define SCN_MAX_FRAMES 512

typedef struct {
    char pack_id[32];
    char display_name[48];
    char version[24];
    char url[512];
    char sha256[65];
    uint64_t archive_bytes;
    uint64_t installed_bytes;
    uint16_t scene_count;
    bool requires_packaged_metadata;
} pack_info_t;

static const char *TAG = "dmd_scene_pack";
static SemaphoreHandle_t s_lock;
static dmd_scene_pack_status_t s_status;

static uint16_t read_u16(const uint8_t *value)
{
    return (uint16_t)(value[0] | ((uint16_t)value[1] << 8));
}

static uint32_t read_u32(const uint8_t *value)
{
    return (uint32_t)value[0] |
           ((uint32_t)value[1] << 8) |
           ((uint32_t)value[2] << 16) |
           ((uint32_t)value[3] << 24);
}

static void set_status(
    dmd_scene_pack_phase_t phase,
    const char *message,
    uint64_t completed,
    uint64_t total,
    uint16_t scenes,
    uint16_t expected)
{
    xSemaphoreTake(s_lock, portMAX_DELAY);
    s_status.phase = phase;
    s_status.completed_bytes = completed;
    s_status.total_bytes = total;
    s_status.extracted_scenes = scenes;
    s_status.expected_scenes = expected;
    strlcpy(s_status.message, message, sizeof(s_status.message));
    xSemaphoreGive(s_lock);
}

static bool cancelled(void)
{
    xSemaphoreTake(s_lock, portMAX_DELAY);
    bool value = s_status.cancel_requested;
    xSemaphoreGive(s_lock);
    return value;
}

static void finish(dmd_scene_pack_phase_t phase, const char *message)
{
    xSemaphoreTake(s_lock, portMAX_DELAY);
    s_status.phase = phase;
    s_status.running = false;
    s_status.restart_required = phase == DMD_SCENE_PACK_COMPLETE;
    strlcpy(s_status.message, message, sizeof(s_status.message));
    xSemaphoreGive(s_lock);
}

const char *dmd_scene_pack_phase_name(dmd_scene_pack_phase_t phase)
{
    switch (phase) {
    case DMD_SCENE_PACK_FETCHING_CATALOG: return "fetching-catalog";
    case DMD_SCENE_PACK_DOWNLOADING: return "downloading";
    case DMD_SCENE_PACK_VERIFYING: return "verifying";
    case DMD_SCENE_PACK_EXTRACTING: return "extracting";
    case DMD_SCENE_PACK_ACTIVATING: return "activating";
    case DMD_SCENE_PACK_COMPLETE: return "complete";
    case DMD_SCENE_PACK_CANCELLED: return "cancelled";
    case DMD_SCENE_PACK_FAILED: return "failed";
    default: return "idle";
    }
}

static esp_err_t remove_flat_directory(const char *path)
{
    DIR *directory = opendir(path);
    if (directory == NULL) {
        return errno == ENOENT ? ESP_OK : ESP_FAIL;
    }
    struct dirent *entry;
    char child[192];
    while ((entry = readdir(directory)) != NULL) {
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) {
            continue;
        }
        int length = snprintf(child, sizeof(child), "%s/%s", path, entry->d_name);
        if (length <= 0 || length >= sizeof(child) || unlink(child) != 0) {
            closedir(directory);
            return ESP_FAIL;
        }
    }
    closedir(directory);
    return rmdir(path) == 0 || errno == ENOENT ? ESP_OK : ESP_FAIL;
}

static bool directory_has_scene(const char *path)
{
    DIR *directory = opendir(path);
    if (directory == NULL) return false;
    bool found = false;
    struct dirent *entry;
    while ((entry = readdir(directory)) != NULL) {
        size_t length = strlen(entry->d_name);
        if (length >= 4 && !strcasecmp(entry->d_name + length - 4, ".scn")) {
            found = true;
            break;
        }
    }
    closedir(directory);
    return found;
}

static esp_err_t recover_activation(void)
{
    struct stat active;
    struct stat backup;
    bool has_active = stat(DMD_STORAGE_SCENES, &active) == 0;
    bool has_backup = stat(BACKUP_DIR, &backup) == 0;
    if (has_backup && (!has_active || !directory_has_scene(DMD_STORAGE_SCENES))) {
        ESP_LOGW(TAG, "Recovering previous scene directory after interrupted activation");
        if (has_active && rmdir(DMD_STORAGE_SCENES) != 0) return ESP_FAIL;
        return rename(BACKUP_DIR, DMD_STORAGE_SCENES) == 0 ? ESP_OK : ESP_FAIL;
    }
    return ESP_OK;
}

static bool redirect_status(int status)
{
    return status == 301 || status == 302 || status == 303 ||
        status == 307 || status == 308;
}

static esp_err_t open_following_redirects(
    esp_http_client_handle_t client,
    int64_t *content_length,
    int *status)
{
    for (uint8_t redirect = 0; redirect <= 5; redirect++) {
        esp_err_t error = esp_http_client_open(client, 0);
        if (error != ESP_OK) return error;
        *content_length = esp_http_client_fetch_headers(client);
        *status = esp_http_client_get_status_code(client);
        if (!redirect_status(*status)) return ESP_OK;
        if (redirect == 5) {
            esp_http_client_close(client);
            return ESP_ERR_HTTP_MAX_REDIRECT;
        }
        error = esp_http_client_set_redirection(client);
        esp_http_client_close(client);
        if (error != ESP_OK) return error;
    }
    return ESP_ERR_HTTP_MAX_REDIRECT;
}

static esp_err_t http_read_all(const char *url, char **body, size_t *length)
{
    esp_http_client_config_t config = {
        .url = url,
        .crt_bundle_attach = esp_crt_bundle_attach,
        .timeout_ms = 20000,
        .buffer_size = 4096,
        .buffer_size_tx = 4096,
    };
    esp_http_client_handle_t client = esp_http_client_init(&config);
    if (client == NULL) return ESP_ERR_NO_MEM;
    int64_t content_length = 0;
    int status = 0;
    esp_err_t error = open_following_redirects(client, &content_length, &status);
    if (error != ESP_OK) goto cleanup;
    if (status != 200 ||
        content_length > MAX_CATALOG_BYTES) {
        error = ESP_ERR_INVALID_RESPONSE;
        goto close;
    }
    size_t capacity = content_length > 0
        ? (size_t)content_length
        : MAX_CATALOG_BYTES;
    char *result = heap_caps_malloc(
        capacity + 1,
        MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    if (result == NULL) result = malloc(capacity + 1);
    if (result == NULL) {
        error = ESP_ERR_NO_MEM;
        goto close;
    }
    size_t used = 0;
    while (used < capacity) {
        int read = esp_http_client_read(client, result + used, capacity - used);
        if (read < 0) {
            free(result);
            error = ESP_FAIL;
            goto close;
        }
        if (read == 0) break;
        used += read;
    }
    if (content_length <= 0 && used == capacity) {
        free(result);
        error = ESP_ERR_INVALID_SIZE;
        goto close;
    }
    result[used] = '\0';
    *body = result;
    *length = used;
    error = ESP_OK;
close:
    esp_http_client_close(client);
cleanup:
    esp_http_client_cleanup(client);
    return error;
}

static bool copy_json_string(
    const cJSON *object,
    const char *name,
    char *destination,
    size_t capacity)
{
    const cJSON *item = cJSON_GetObjectItemCaseSensitive(object, name);
    if (!cJSON_IsString(item) || item->valuestring == NULL ||
        strlen(item->valuestring) >= capacity) return false;
    strlcpy(destination, item->valuestring, capacity);
    return true;
}

static bool digest_matches(const uint8_t digest[32], const char *expected);

static bool bytes_match_sha256(
    const char *bytes,
    size_t length,
    const char *expected)
{
    if (bytes == NULL || expected == NULL || strlen(expected) != 64) return false;
    uint8_t digest[32];
    mbedtls_sha256_context sha;
    mbedtls_sha256_init(&sha);
    mbedtls_sha256_starts(&sha, 0);
    mbedtls_sha256_update(&sha, (const uint8_t *)bytes, length);
    mbedtls_sha256_finish(&sha, digest);
    mbedtls_sha256_free(&sha);
    return digest_matches(digest, expected);
}

static bool supports_esp32(const cJSON *object)
{
    const cJSON *platforms = cJSON_GetObjectItemCaseSensitive(
        object,
        "supportedPlatforms");
    const cJSON *entry;
    cJSON_ArrayForEach(entry, platforms) {
        if (cJSON_IsString(entry) && !strcmp(entry->valuestring, "esp32-s3")) {
            return true;
        }
    }
    return false;
}

static esp_err_t parse_release_manifest(
    const char *text,
    size_t length,
    pack_info_t *pack)
{
    cJSON *manifest = cJSON_ParseWithLength(text, length);
    if (manifest == NULL) return ESP_ERR_INVALID_RESPONSE;
    const cJSON *schema = cJSON_GetObjectItemCaseSensitive(manifest, "schemaVersion");
    const cJSON *kind = cJSON_GetObjectItemCaseSensitive(manifest, "kind");
    const cJSON *pack_id = cJSON_GetObjectItemCaseSensitive(manifest, "packId");
    const cJSON *scene_count = cJSON_GetObjectItemCaseSensitive(manifest, "sceneCount");
    const cJSON *installed_bytes = cJSON_GetObjectItemCaseSensitive(
        manifest,
        "totalSceneBytes");
    const cJSON *archive = cJSON_GetObjectItemCaseSensitive(manifest, "archive");
    const cJSON *archive_bytes = cJSON_GetObjectItemCaseSensitive(archive, "size");
    esp_err_t error = ESP_ERR_INVALID_RESPONSE;
    if (cJSON_IsNumber(schema) && schema->valueint == 1 &&
        cJSON_IsString(kind) &&
        !strcmp(kind->valuestring, "dmdclock-scene-pack-release") &&
        cJSON_IsString(pack_id) && !strcmp(pack_id->valuestring, pack->pack_id) &&
        supports_esp32(manifest) &&
        cJSON_IsNumber(scene_count) && scene_count->valueint > 0 &&
        scene_count->valueint <= 4096 &&
        cJSON_IsNumber(installed_bytes) && installed_bytes->valuedouble > 0 &&
        cJSON_IsObject(archive) && cJSON_IsNumber(archive_bytes) &&
        archive_bytes->valuedouble > 0 &&
        archive_bytes->valuedouble <= MAX_ARCHIVE_BYTES &&
        copy_json_string(archive, "downloadUrl", pack->url, sizeof(pack->url)) &&
        !strncmp(pack->url, "https://", 8) &&
        copy_json_string(archive, "sha256", pack->sha256, sizeof(pack->sha256)) &&
        strlen(pack->sha256) == 64) {
        pack->archive_bytes = (uint64_t)archive_bytes->valuedouble;
        pack->installed_bytes = (uint64_t)installed_bytes->valuedouble;
        pack->scene_count = (uint16_t)scene_count->valueint;
        error = ESP_OK;
    }
    cJSON_Delete(manifest);
    return error;
}

static esp_err_t fetch_release_manifest(
    const cJSON *selected,
    pack_info_t *pack)
{
    char url[512];
    char expected_sha256[65];
    const cJSON *expected_size = cJSON_GetObjectItemCaseSensitive(
        selected,
        "manifestSize");
    if (!copy_json_string(selected, "manifestUrl", url, sizeof(url)) ||
        strncmp(url, "https://", 8) != 0 ||
        !copy_json_string(
            selected,
            "manifestSha256",
            expected_sha256,
            sizeof(expected_sha256)) ||
        strlen(expected_sha256) != 64 || !cJSON_IsNumber(expected_size) ||
        expected_size->valuedouble <= 0 ||
        expected_size->valuedouble > MAX_CATALOG_BYTES) {
        return ESP_ERR_INVALID_RESPONSE;
    }
    char *text = NULL;
    size_t length = 0;
    esp_err_t error = http_read_all(url, &text, &length);
    if (error != ESP_OK) return error;
    if (length != (size_t)expected_size->valuedouble ||
        !bytes_match_sha256(text, length, expected_sha256)) {
        error = ESP_ERR_INVALID_CRC;
    } else {
        error = parse_release_manifest(text, length, pack);
    }
    free(text);
    return error;
}

static bool supported_pack_id(const char *pack_id)
{
    return pack_id != NULL &&
        (!strcmp(pack_id, ORIGINAL_PACK_ID) || !strcmp(pack_id, LARGE_PACK_ID));
}

static esp_err_t fetch_pack_info(const char *pack_id, pack_info_t *pack)
{
    if (!supported_pack_id(pack_id)) return ESP_ERR_INVALID_ARG;
    strlcpy(pack->pack_id, pack_id, sizeof(pack->pack_id));
    strlcpy(
        pack->display_name,
        !strcmp(pack_id, ORIGINAL_PACK_ID) ? ORIGINAL_DISPLAY_NAME : LARGE_DISPLAY_NAME,
        sizeof(pack->display_name));
    strlcpy(
        pack->version,
        !strcmp(pack_id, ORIGINAL_PACK_ID) ? ORIGINAL_VERSION : LARGE_VERSION,
        sizeof(pack->version));
    pack->requires_packaged_metadata = !strcmp(pack_id, LARGE_PACK_ID);
    char *text = NULL;
    size_t length = 0;
    esp_err_t error = http_read_all(CATALOG_URL, &text, &length);
    if (error != ESP_OK) {
        ESP_LOGW(TAG, "Primary scene catalog unavailable; trying packaged catalog");
        error = http_read_all(CATALOG_FALLBACK_URL, &text, &length);
    }
    if (error != ESP_OK) return error;
    cJSON *catalog = cJSON_ParseWithLength(text, length);
    free(text);
    if (catalog == NULL) return ESP_ERR_INVALID_RESPONSE;
    const cJSON *schema = cJSON_GetObjectItemCaseSensitive(catalog, "schemaVersion");
    const cJSON *packs = cJSON_GetObjectItemCaseSensitive(catalog, "packs");
    const cJSON *selected = NULL;
    const cJSON *entry;
    cJSON_ArrayForEach(entry, packs) {
        const cJSON *id = cJSON_GetObjectItemCaseSensitive(entry, "packId");
        if (cJSON_IsString(id) && !strcmp(id->valuestring, pack_id)) {
            selected = entry;
            break;
        }
    }
    if (!cJSON_IsNumber(schema) || schema->valueint != 1 || selected == NULL) {
        error = ESP_ERR_INVALID_RESPONSE;
        goto cleanup;
    }
    const cJSON *available = cJSON_GetObjectItemCaseSensitive(selected, "available");
    copy_json_string(selected, "version", pack->version, sizeof(pack->version));
    const cJSON *download_bytes = cJSON_GetObjectItemCaseSensitive(selected, "downloadBytes");
    const cJSON *installed_bytes = cJSON_GetObjectItemCaseSensitive(selected, "installedBytes");
    const cJSON *scene_count = cJSON_GetObjectItemCaseSensitive(selected, "sceneCount");
    if (cJSON_GetObjectItemCaseSensitive(selected, "manifestUrl") != NULL) {
        error = supports_esp32(selected)
            ? fetch_release_manifest(selected, pack)
            : ESP_ERR_INVALID_RESPONSE;
        goto cleanup;
    }
    if (!cJSON_IsTrue(available) || !cJSON_IsNumber(download_bytes) ||
        download_bytes->valuedouble <= 0 || download_bytes->valuedouble > MAX_ARCHIVE_BYTES ||
        !cJSON_IsNumber(installed_bytes) || installed_bytes->valuedouble <= 0 ||
        !cJSON_IsNumber(scene_count) || scene_count->valueint <= 0 ||
        scene_count->valueint > 4096 || !supports_esp32(selected) ||
        !copy_json_string(selected, "downloadUrl", pack->url, sizeof(pack->url)) ||
        strncmp(pack->url, "https://", 8) != 0 ||
        !copy_json_string(selected, "archiveSha256", pack->sha256, sizeof(pack->sha256)) ||
        strlen(pack->sha256) != 64) {
        error = ESP_ERR_INVALID_RESPONSE;
        goto cleanup;
    }
    pack->archive_bytes = (uint64_t)download_bytes->valuedouble;
    pack->installed_bytes = (uint64_t)installed_bytes->valuedouble;
    pack->scene_count = (uint16_t)scene_count->valueint;
    error = ESP_OK;
cleanup:
    cJSON_Delete(catalog);
    return error;
}

static esp_err_t hash_file(const char *path, uint8_t digest[32])
{
    FILE *file = fopen(path, "rb");
    if (file == NULL) return ESP_ERR_NOT_FOUND;
    uint8_t *buffer = malloc(IO_BUFFER_SIZE);
    if (buffer == NULL) {
        fclose(file);
        return ESP_ERR_NO_MEM;
    }
    mbedtls_sha256_context sha;
    mbedtls_sha256_init(&sha);
    mbedtls_sha256_starts(&sha, 0);
    size_t read;
    while ((read = fread(buffer, 1, IO_BUFFER_SIZE, file)) > 0) {
        mbedtls_sha256_update(&sha, buffer, read);
    }
    bool failed = ferror(file) != 0;
    if (!failed) mbedtls_sha256_finish(&sha, digest);
    mbedtls_sha256_free(&sha);
    free(buffer);
    fclose(file);
    return failed ? ESP_FAIL : ESP_OK;
}

static bool digest_matches(const uint8_t digest[32], const char *expected)
{
    char actual[65];
    for (size_t index = 0; index < 32; index++) {
        snprintf(actual + index * 2, 3, "%02x", digest[index]);
    }
    return strcasecmp(actual, expected) == 0;
}

static esp_err_t download_archive(const pack_info_t *pack)
{
    mkdir(WORK_DIR, 0755);
    struct stat partial;
    uint64_t offset = stat(ARCHIVE_PATH, &partial) == 0 ? partial.st_size : 0;
    if (offset > pack->archive_bytes) {
        unlink(ARCHIVE_PATH);
        offset = 0;
    }
    esp_http_client_config_t config = {
        .url = pack->url,
        .crt_bundle_attach = esp_crt_bundle_attach,
        .timeout_ms = 30000,
        .buffer_size = IO_BUFFER_SIZE,
        .buffer_size_tx = 4096,
    };
    esp_http_client_handle_t client = esp_http_client_init(&config);
    if (client == NULL) return ESP_ERR_NO_MEM;
    char range[48];
    if (offset > 0) {
        snprintf(range, sizeof(range), "bytes=%llu-", (unsigned long long)offset);
        esp_http_client_set_header(client, "Range", range);
    }
    int64_t content_length = 0;
    int status = 0;
    esp_err_t error = open_following_redirects(client, &content_length, &status);
    if (error != ESP_OK) goto cleanup;
    if (offset > 0 && status == 200) {
        esp_http_client_close(client);
        esp_http_client_cleanup(client);
        unlink(ARCHIVE_PATH);
        return download_archive(pack);
    }
    if ((offset == 0 && status != 200) || (offset > 0 && status != 206)) {
        error = ESP_ERR_INVALID_RESPONSE;
        goto close;
    }
    if (content_length > 0 &&
        (uint64_t)content_length != pack->archive_bytes - offset) {
        error = ESP_ERR_INVALID_SIZE;
        goto close;
    }
    FILE *file = fopen(ARCHIVE_PATH, offset > 0 ? "ab" : "wb");
    uint8_t *buffer = malloc(IO_BUFFER_SIZE);
    if (file == NULL || buffer == NULL) {
        if (file != NULL) fclose(file);
        free(buffer);
        error = ESP_ERR_NO_MEM;
        goto close;
    }
    uint64_t completed = offset;
    set_status(DMD_SCENE_PACK_DOWNLOADING, "Downloading scene pack", completed,
        pack->archive_bytes, 0, pack->scene_count);
    while (completed < pack->archive_bytes && !cancelled()) {
        int read = esp_http_client_read(client, (char *)buffer, IO_BUFFER_SIZE);
        if (read <= 0 || fwrite(buffer, 1, read, file) != (size_t)read) {
            error = ESP_FAIL;
            break;
        }
        completed += read;
        set_status(DMD_SCENE_PACK_DOWNLOADING, "Downloading scene pack", completed,
            pack->archive_bytes, 0, pack->scene_count);
    }
    free(buffer);
    if (fflush(file) != 0) error = ESP_FAIL;
    fclose(file);
    if (cancelled()) error = ESP_ERR_INVALID_STATE;
    if (error == ESP_OK && completed != pack->archive_bytes) error = ESP_ERR_INVALID_SIZE;
close:
    esp_http_client_close(client);
cleanup:
    esp_http_client_cleanup(client);
    return error;
}

static esp_err_t copy_file(const char *source, const char *destination)
{
    FILE *input = fopen(source, "rb");
    FILE *output = input == NULL ? NULL : fopen(destination, "wb");
    uint8_t *buffer = output == NULL ? NULL : malloc(IO_BUFFER_SIZE);
    if (input == NULL || output == NULL || buffer == NULL) {
        if (input != NULL) fclose(input);
        if (output != NULL) fclose(output);
        free(buffer);
        return ESP_FAIL;
    }
    esp_err_t error = ESP_OK;
    size_t read;
    while ((read = fread(buffer, 1, IO_BUFFER_SIZE, input)) > 0) {
        if (fwrite(buffer, 1, read, output) != read) {
            error = ESP_FAIL;
            break;
        }
    }
    if (ferror(input) || fflush(output) != 0) error = ESP_FAIL;
    free(buffer);
    fclose(output);
    fclose(input);
    return error;
}

static esp_err_t validate_scene_file(const char *path)
{
    FILE *file = fopen(path, "rb");
    if (file == NULL) return ESP_ERR_NOT_FOUND;
    uint8_t header[SCN_FRAME_HEADER_SIZE];
    if (fread(header, 1, SCN_HEADER_SIZE, file) != SCN_HEADER_SIZE) {
        fclose(file);
        return ESP_ERR_INVALID_SIZE;
    }
    uint16_t version = read_u16(header);
    uint16_t frames = read_u16(header + 2);
    uint16_t storyboards = read_u16(header + 4);
    if (version != 1 || frames == 0 || frames > SCN_MAX_FRAMES || storyboards == 0 ||
        fseek(file, (long)storyboards * SCN_STORYBOARD_SIZE, SEEK_CUR) != 0) {
        fclose(file);
        return ESP_ERR_INVALID_VERSION;
    }
    for (uint16_t index = 0; index < frames; index++) {
        if (fread(header, 1, SCN_FRAME_HEADER_SIZE, file) != SCN_FRAME_HEADER_SIZE) {
            fclose(file);
            return ESP_ERR_INVALID_SIZE;
        }
        uint16_t mask = read_u16(header + 6);
        if (read_u16(header) != 128 || read_u16(header + 2) != 32 ||
            read_u16(header + 4) != 4 || mask > 1 ||
            fseek(file, SCN_PACKED_PIXEL_SIZE + (mask ? SCN_MASK_SIZE : 0), SEEK_CUR) != 0) {
            fclose(file);
            return ESP_ERR_NOT_SUPPORTED;
        }
    }
    int trailing = fgetc(file);
    fclose(file);
    return trailing == EOF ? ESP_OK : ESP_ERR_INVALID_SIZE;
}

static esp_err_t validate_metadata_file(const char *path, uint16_t expected_scenes)
{
    FILE *file = fopen(path, "rb");
    if (file == NULL || fseek(file, 0, SEEK_END) != 0) {
        if (file != NULL) fclose(file);
        return ESP_ERR_NOT_FOUND;
    }
    long length = ftell(file);
    if (length <= 0 || length > MAX_CATALOG_BYTES || fseek(file, 0, SEEK_SET) != 0) {
        fclose(file);
        return ESP_ERR_INVALID_SIZE;
    }
    char *text = malloc((size_t)length + 1);
    if (text == NULL) {
        fclose(file);
        return ESP_ERR_NO_MEM;
    }
    bool read_ok = fread(text, 1, (size_t)length, file) == (size_t)length;
    fclose(file);
    text[length] = '\0';
    cJSON *json = read_ok ? cJSON_ParseWithLength(text, (size_t)length) : NULL;
    free(text);
    if (json == NULL) return ESP_ERR_INVALID_RESPONSE;
    const cJSON *schema = cJSON_GetObjectItemCaseSensitive(json, "schemaVersion");
    const cJSON *files = cJSON_GetObjectItemCaseSensitive(json, "files");
    bool valid = cJSON_IsNumber(schema) && schema->valueint == 1 &&
        cJSON_IsArray(files) && cJSON_GetArraySize(files) == expected_scenes;
    cJSON_Delete(json);
    return valid ? ESP_OK : ESP_ERR_INVALID_RESPONSE;
}

static esp_err_t validate_content_manifest_file(
    const char *path,
    uint16_t expected_scenes,
    const char *expected_pack_id)
{
    FILE *file = fopen(path, "rb");
    if (file == NULL || fseek(file, 0, SEEK_END) != 0) {
        if (file != NULL) fclose(file);
        return ESP_ERR_NOT_FOUND;
    }
    long length = ftell(file);
    if (length <= 0 || length > MAX_CATALOG_BYTES || fseek(file, 0, SEEK_SET) != 0) {
        fclose(file);
        return ESP_ERR_INVALID_SIZE;
    }
    char *text = malloc((size_t)length + 1);
    if (text == NULL) {
        fclose(file);
        return ESP_ERR_NO_MEM;
    }
    bool read_ok = fread(text, 1, (size_t)length, file) == (size_t)length;
    fclose(file);
    text[length] = '\0';
    cJSON *json = read_ok ? cJSON_ParseWithLength(text, (size_t)length) : NULL;
    free(text);
    if (json == NULL) return ESP_ERR_INVALID_RESPONSE;
    const cJSON *schema = cJSON_GetObjectItemCaseSensitive(json, "schemaVersion");
    const cJSON *kind = cJSON_GetObjectItemCaseSensitive(json, "kind");
    const cJSON *pack_id = cJSON_GetObjectItemCaseSensitive(json, "packId");
    const cJSON *scene_count = cJSON_GetObjectItemCaseSensitive(json, "sceneCount");
    const cJSON *files = cJSON_GetObjectItemCaseSensitive(json, "files");
    bool valid = cJSON_IsNumber(schema) && schema->valueint == 1 &&
        cJSON_IsString(kind) && !strcmp(kind->valuestring, "dmdclock-scene-pack-content") &&
        cJSON_IsString(pack_id) && !strcmp(pack_id->valuestring, expected_pack_id) &&
        cJSON_IsNumber(scene_count) && scene_count->valueint == expected_scenes &&
        cJSON_IsArray(files) && cJSON_GetArraySize(files) == expected_scenes;
    cJSON_Delete(json);
    return valid ? ESP_OK : ESP_ERR_INVALID_RESPONSE;
}

static esp_err_t extract_entry(
    FILE *archive,
    FILE *output,
    uint16_t method,
    uint32_t compressed_size,
    uint32_t uncompressed_size,
    uint32_t expected_crc)
{
    if (uncompressed_size == 0 || uncompressed_size > MAX_ENTRY_BYTES) return ESP_ERR_INVALID_SIZE;
    uint8_t *input = malloc(IO_BUFFER_SIZE);
    uint8_t *expanded = malloc(IO_BUFFER_SIZE);
    if (input == NULL || expanded == NULL) {
        free(input); free(expanded);
        return ESP_ERR_NO_MEM;
    }
    uint32_t remaining = compressed_size;
    uint32_t written = 0;
    uLong crc = crc32(0L, Z_NULL, 0);
    esp_err_t error = ESP_OK;
    if (method == 0) {
        while (remaining > 0) {
            size_t chunk = remaining > IO_BUFFER_SIZE ? IO_BUFFER_SIZE : remaining;
            if (fread(input, 1, chunk, archive) != chunk ||
                fwrite(input, 1, chunk, output) != chunk) { error = ESP_FAIL; break; }
            crc = crc32(crc, input, chunk);
            written += chunk;
            remaining -= chunk;
        }
    } else if (method == 8) {
        z_stream stream = {0};
        bool finished = false;
        if (inflateInit2(&stream, -MAX_WBITS) != Z_OK) error = ESP_FAIL;
        while (error == ESP_OK && remaining > 0) {
            size_t chunk = remaining > IO_BUFFER_SIZE ? IO_BUFFER_SIZE : remaining;
            if (fread(input, 1, chunk, archive) != chunk) { error = ESP_FAIL; break; }
            remaining -= chunk;
            stream.next_in = input;
            stream.avail_in = chunk;
            do {
                stream.next_out = expanded;
                stream.avail_out = IO_BUFFER_SIZE;
                int result = inflate(&stream, Z_NO_FLUSH);
                if (result != Z_OK && result != Z_STREAM_END) { error = ESP_ERR_INVALID_RESPONSE; break; }
                size_t produced = IO_BUFFER_SIZE - stream.avail_out;
                if (produced > 0 && fwrite(expanded, 1, produced, output) != produced) { error = ESP_FAIL; break; }
                crc = crc32(crc, expanded, produced);
                written += produced;
                if (result == Z_STREAM_END) finished = true;
            } while (!finished && stream.avail_out == 0);
            if (finished && (remaining != 0 || stream.avail_in != 0)) {
                error = ESP_ERR_INVALID_RESPONSE;
            }
        }
        inflateEnd(&stream);
        if (error == ESP_OK && !finished) error = ESP_ERR_INVALID_RESPONSE;
    } else {
        error = ESP_ERR_NOT_SUPPORTED;
    }
    free(expanded);
    free(input);
    if (error == ESP_OK && (written != uncompressed_size || crc != expected_crc)) {
        error = ESP_ERR_INVALID_CRC;
    }
    return error;
}

static bool scene_name_from_zip(const char *path, char *name, size_t capacity)
{
    const char *marker = strstr(path, "/Scenes/");
    if (marker == NULL) return false;
    const char *relative = marker + strlen("/Scenes/");
    if (*relative == '\0' || strchr(relative, '/') != NULL || strlen(relative) >= capacity) return false;
    size_t length = strlen(relative);
    if (length < 4 || strcasecmp(relative + length - 4, ".scn") != 0) return false;
    strlcpy(name, relative, capacity);
    return true;
}

static esp_err_t extract_archive(const pack_info_t *pack)
{
    ESP_RETURN_ON_ERROR(remove_flat_directory(STAGING_DIR), TAG, "clear staging");
    if (mkdir(STAGING_DIR, 0755) != 0) return ESP_FAIL;
    FILE *archive = fopen(ARCHIVE_PATH, "rb");
    if (archive == NULL) return ESP_ERR_NOT_FOUND;
    char managed_path[192];
    snprintf(managed_path, sizeof(managed_path), "%s/%s", STAGING_DIR, MANAGED_SCENES_FILE);
    FILE *managed = fopen(managed_path, "wb");
    if (managed == NULL) {
        fclose(archive);
        return ESP_FAIL;
    }
    uint16_t scenes = 0;
    bool metadata_found = false;
    bool content_manifest_found = false;
    esp_err_t error = ESP_OK;
    while (!cancelled()) {
        uint8_t header[30];
        if (fread(header, 1, 4, archive) != 4) { error = ESP_ERR_INVALID_RESPONSE; break; }
        uint32_t signature = read_u32(header);
        if (signature == ZIP_CENTRAL_HEADER) break;
        if (signature != ZIP_LOCAL_HEADER || fread(header + 4, 1, 26, archive) != 26) {
            error = ESP_ERR_INVALID_RESPONSE; break;
        }
        uint16_t flags = read_u16(header + 6);
        uint16_t method = read_u16(header + 8);
        uint32_t crc = read_u32(header + 14);
        uint32_t compressed = read_u32(header + 18);
        uint32_t uncompressed = read_u32(header + 22);
        uint16_t name_length = read_u16(header + 26);
        uint16_t extra_length = read_u16(header + 28);
        if ((flags & 0x09) != 0 || name_length == 0 || name_length >= 160) {
            error = ESP_ERR_NOT_SUPPORTED; break;
        }
        char path[160];
        if (fread(path, 1, name_length, archive) != name_length ||
            fseek(archive, extra_length, SEEK_CUR) != 0) { error = ESP_FAIL; break; }
        path[name_length] = '\0';
        char name[80];
        bool is_scene = scene_name_from_zip(path, name, sizeof(name));
        const char *metadata_marker = strstr(path, "/Scenes/scene-metadata.json");
        bool is_metadata = metadata_marker != NULL &&
            metadata_marker[strlen("/Scenes/scene-metadata.json")] == '\0';
        const char *content_marker = strstr(path, "/scene-pack-content.json");
        bool is_content_manifest = content_marker != NULL &&
            content_marker[strlen("/scene-pack-content.json")] == '\0';
        if (!is_scene && !is_metadata && !is_content_manifest) {
            if (fseek(archive, compressed, SEEK_CUR) != 0) { error = ESP_FAIL; break; }
            continue;
        }
        if (is_metadata) strlcpy(name, "scene-metadata.json", sizeof(name));
        if (is_content_manifest) strlcpy(name, "scene-pack-content.json", sizeof(name));
        char destination[192];
        snprintf(destination, sizeof(destination), "%s/%s", STAGING_DIR, name);
        FILE *output = fopen(destination, "wb");
        if (output == NULL) { error = ESP_FAIL; break; }
        error = extract_entry(archive, output, method, compressed, uncompressed, crc);
        if (fflush(output) != 0) error = ESP_FAIL;
        fclose(output);
        if (error != ESP_OK) { unlink(destination); break; }
        if (is_scene) {
            error = validate_scene_file(destination);
            if (error != ESP_OK) { unlink(destination); break; }
            if (fprintf(managed, "%s\n", name) < 0) { error = ESP_FAIL; break; }
            scenes++;
        } else if (is_metadata) {
            error = validate_metadata_file(destination, pack->scene_count);
            if (error != ESP_OK) { unlink(destination); break; }
            metadata_found = true;
        } else {
            error = validate_content_manifest_file(
                destination, pack->scene_count, pack->pack_id);
            if (error != ESP_OK) { unlink(destination); break; }
            content_manifest_found = true;
        }
        set_status(DMD_SCENE_PACK_EXTRACTING, "Extracting verified scenes",
            scenes, pack->scene_count, scenes, pack->scene_count);
    }
    fclose(archive);
    if (fflush(managed) != 0) error = ESP_FAIL;
    fclose(managed);
    if (cancelled()) return ESP_ERR_INVALID_STATE;
    if (error != ESP_OK) return error;
    return scenes == pack->scene_count &&
        (!pack->requires_packaged_metadata || (metadata_found && content_manifest_found))
        ? ESP_OK : ESP_ERR_INVALID_SIZE;
}

static char *read_managed_index(bool *line_list)
{
    char path[192];
    snprintf(path, sizeof(path), "%s/%s", DMD_STORAGE_SCENES, MANAGED_SCENES_FILE);
    FILE *file = fopen(path, "rb");
    *line_list = file != NULL;
    if (file == NULL) {
        snprintf(path, sizeof(path), "%s/scene-pack-content.json", DMD_STORAGE_SCENES);
        file = fopen(path, "rb");
    }
    if (file == NULL || fseek(file, 0, SEEK_END) != 0) {
        if (file != NULL) fclose(file);
        return NULL;
    }
    long length = ftell(file);
    if (length <= 0 || length > MAX_CATALOG_BYTES || fseek(file, 0, SEEK_SET) != 0) {
        fclose(file);
        return NULL;
    }
    char *text = heap_caps_malloc(
        (size_t)length + 1,
        MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    if (text == NULL) text = malloc((size_t)length + 1);
    if (text == NULL) {
        fclose(file);
        return NULL;
    }
    if (fread(text, 1, (size_t)length, file) != (size_t)length) {
        free(text);
        fclose(file);
        return NULL;
    }
    text[length] = '\0';
    fclose(file);
    return text;
}

static bool managed_index_contains(const char *index, bool line_list, const char *name)
{
    if (index == NULL) return false;
    if (!line_list) {
        char marker[128];
        snprintf(marker, sizeof(marker), "Scenes/%s\"", name);
        return strstr(index, marker) != NULL;
    }
    size_t length = strlen(name);
    const char *match = index;
    while ((match = strstr(match, name)) != NULL) {
        bool starts_line = match == index || match[-1] == '\n';
        bool ends_line = match[length] == '\0' || match[length] == '\r' || match[length] == '\n';
        if (starts_line && ends_line) return true;
        match += length;
    }
    return false;
}

static esp_err_t preserve_custom_scenes(void)
{
    DIR *directory = opendir(DMD_STORAGE_SCENES);
    if (directory == NULL) return errno == ENOENT ? ESP_OK : ESP_FAIL;
    struct dirent *entry;
    char source[320];
    char destination[320];
    bool line_list = false;
    char *managed_index = read_managed_index(&line_list);
    esp_err_t error = ESP_OK;
    while ((entry = readdir(directory)) != NULL) {
        size_t length = strlen(entry->d_name);
        if (length < 4 || strcasecmp(entry->d_name + length - 4, ".scn") != 0) continue;
        if (managed_index_contains(managed_index, line_list, entry->d_name)) continue;
        snprintf(destination, sizeof(destination), "%s/%s", STAGING_DIR, entry->d_name);
        struct stat existing;
        if (stat(destination, &existing) == 0) continue;
        snprintf(source, sizeof(source), "%s/%s", DMD_STORAGE_SCENES, entry->d_name);
        error = copy_file(source, destination);
        if (error != ESP_OK) break;
    }
    closedir(directory);
    free(managed_index);
    return error;
}

static esp_err_t activate(void)
{
    ESP_RETURN_ON_ERROR(preserve_custom_scenes(), TAG, "preserve custom scenes");
    ESP_RETURN_ON_ERROR(remove_flat_directory(BACKUP_DIR), TAG, "clear previous backup");
    if (rename(DMD_STORAGE_SCENES, BACKUP_DIR) != 0) return ESP_FAIL;
    if (rename(STAGING_DIR, DMD_STORAGE_SCENES) != 0) {
        rename(BACKUP_DIR, DMD_STORAGE_SCENES);
        return ESP_FAIL;
    }
    return ESP_OK;
}

static void update_selected_pack(const pack_info_t *pack)
{
    xSemaphoreTake(s_lock, portMAX_DELAY);
    strlcpy(s_status.pack_id, pack->pack_id, sizeof(s_status.pack_id));
    strlcpy(s_status.display_name, pack->display_name, sizeof(s_status.display_name));
    strlcpy(s_status.version, pack->version, sizeof(s_status.version));
    s_status.expected_scenes = pack->scene_count;
    xSemaphoreGive(s_lock);
}

static esp_err_t write_installed_pack(const pack_info_t *pack)
{
    cJSON *json = cJSON_CreateObject();
    if (json == NULL) return ESP_ERR_NO_MEM;
    cJSON_AddStringToObject(json, "packId", pack->pack_id);
    cJSON_AddStringToObject(json, "displayName", pack->display_name);
    cJSON_AddStringToObject(json, "version", pack->version);
    cJSON_AddNumberToObject(json, "sceneCount", pack->scene_count);
    char *text = cJSON_PrintUnformatted(json);
    cJSON_Delete(json);
    if (text == NULL) return ESP_ERR_NO_MEM;
    FILE *file = fopen(INSTALLED_PACK_TEMP, "wb");
    esp_err_t error = ESP_OK;
    if (file == NULL || fwrite(text, 1, strlen(text), file) != strlen(text) ||
        fflush(file) != 0) error = ESP_FAIL;
    if (file != NULL) fclose(file);
    free(text);
    if (error != ESP_OK) {
        unlink(INSTALLED_PACK_TEMP);
        return error;
    }
    unlink(INSTALLED_PACK_PATH);
    if (rename(INSTALLED_PACK_TEMP, INSTALLED_PACK_PATH) != 0) {
        unlink(INSTALLED_PACK_TEMP);
        return ESP_FAIL;
    }
    return ESP_OK;
}

static void load_installed_pack(void)
{
    FILE *file = fopen(INSTALLED_PACK_PATH, "rb");
    if (file == NULL) return;
    char text[512];
    size_t length = fread(text, 1, sizeof(text) - 1, file);
    fclose(file);
    text[length] = '\0';
    cJSON *json = cJSON_ParseWithLength(text, length);
    if (json == NULL) return;
    const cJSON *pack_id = cJSON_GetObjectItemCaseSensitive(json, "packId");
    const cJSON *display_name = cJSON_GetObjectItemCaseSensitive(json, "displayName");
    const cJSON *version = cJSON_GetObjectItemCaseSensitive(json, "version");
    const cJSON *scene_count = cJSON_GetObjectItemCaseSensitive(json, "sceneCount");
    if (cJSON_IsString(pack_id) && supported_pack_id(pack_id->valuestring) &&
        cJSON_IsString(display_name) && cJSON_IsString(version) &&
        cJSON_IsNumber(scene_count) && scene_count->valueint > 0 &&
        scene_count->valueint <= 4096) {
        strlcpy(s_status.pack_id, pack_id->valuestring, sizeof(s_status.pack_id));
        strlcpy(s_status.display_name, display_name->valuestring, sizeof(s_status.display_name));
        strlcpy(s_status.version, version->valuestring, sizeof(s_status.version));
        s_status.expected_scenes = (uint16_t)scene_count->valueint;
        s_status.extracted_scenes = (uint16_t)scene_count->valueint;
        s_status.installed = true;
        strlcpy(s_status.message, "Installed scene pack ready", sizeof(s_status.message));
    }
    cJSON_Delete(json);
}

static void install_task(void *argument)
{
    (void)argument;
    pack_info_t pack = {0};
    char selected_pack_id[sizeof(s_status.pack_id)];
    xSemaphoreTake(s_lock, portMAX_DELAY);
    strlcpy(selected_pack_id, s_status.pack_id, sizeof(selected_pack_id));
    xSemaphoreGive(s_lock);
    set_status(DMD_SCENE_PACK_FETCHING_CATALOG, "Downloading shared catalog", 0, 0, 0, 0);
    esp_err_t error = fetch_pack_info(selected_pack_id, &pack);
    if (error == ESP_OK) update_selected_pack(&pack);
    if (error == ESP_OK) {
        uint64_t total = 0;
        uint64_t free_bytes = 0;
        error = esp_vfs_fat_info("/sd", &total, &free_bytes);
        uint64_t required = pack.archive_bytes + pack.installed_bytes + (16ULL * 1024 * 1024);
        if (error == ESP_OK && free_bytes < required) error = ESP_ERR_NO_MEM;
    }
    if (error == ESP_OK) error = download_archive(&pack);
    if (error == ESP_OK) {
        set_status(DMD_SCENE_PACK_VERIFYING, "Verifying archive SHA-256", 0,
            pack.archive_bytes, 0, pack.scene_count);
        uint8_t digest[32];
        error = hash_file(ARCHIVE_PATH, digest);
        if (error == ESP_OK && !digest_matches(digest, pack.sha256)) error = ESP_ERR_INVALID_CRC;
    }
    if (error == ESP_OK) {
        set_status(DMD_SCENE_PACK_EXTRACTING, "Extracting verified scenes", 0,
            pack.scene_count, 0, pack.scene_count);
        error = extract_archive(&pack);
    }
    if (error == ESP_OK) {
        set_status(DMD_SCENE_PACK_ACTIVATING, "Activating new scene library", 0, 0,
            pack.scene_count, pack.scene_count);
        error = activate();
    }
    if (error == ESP_OK) {
        unlink(ARCHIVE_PATH);
        error = write_installed_pack(&pack);
    }
    if (error == ESP_OK) {
        xSemaphoreTake(s_lock, portMAX_DELAY);
        s_status.installed = true;
        xSemaphoreGive(s_lock);
        finish(DMD_SCENE_PACK_COMPLETE, "Scene pack installed; reboot to load it");
    } else if (cancelled()) {
        finish(DMD_SCENE_PACK_CANCELLED, "Scene-pack operation cancelled");
    } else {
        char message[128];
        snprintf(message, sizeof(message), "Scene-pack operation failed: %s", esp_err_to_name(error));
        finish(DMD_SCENE_PACK_FAILED, message);
        ESP_LOGE(TAG, "%s", message);
    }
    vTaskDelete(NULL);
}

esp_err_t dmd_scene_pack_init(void)
{
    s_lock = xSemaphoreCreateMutex();
    if (s_lock == NULL) return ESP_ERR_NO_MEM;
    memset(&s_status, 0, sizeof(s_status));
    strlcpy(s_status.message, "Ready", sizeof(s_status.message));
    load_installed_pack();
    return recover_activation();
}

esp_err_t dmd_scene_pack_start(const char *operation, const char *pack_id)
{
    if (!dmd_storage_available() || operation == NULL || !supported_pack_id(pack_id) ||
        (strcmp(operation, "install") && strcmp(operation, "update") && strcmp(operation, "repair"))) {
        return ESP_ERR_INVALID_ARG;
    }
    xSemaphoreTake(s_lock, portMAX_DELAY);
    if (s_status.running) {
        xSemaphoreGive(s_lock);
        return ESP_ERR_INVALID_STATE;
    }
    memset(&s_status, 0, sizeof(s_status));
    s_status.running = true;
    strlcpy(s_status.operation, operation, sizeof(s_status.operation));
    strlcpy(s_status.pack_id, pack_id, sizeof(s_status.pack_id));
    strlcpy(
        s_status.display_name,
        !strcmp(pack_id, ORIGINAL_PACK_ID) ? ORIGINAL_DISPLAY_NAME : LARGE_DISPLAY_NAME,
        sizeof(s_status.display_name));
    strlcpy(s_status.message, "Starting", sizeof(s_status.message));
    xSemaphoreGive(s_lock);
    BaseType_t result = xTaskCreate(install_task, "scene_pack", 12288, NULL, 3, NULL);
    if (result != pdPASS) finish(DMD_SCENE_PACK_FAILED, "Could not start scene-pack task");
    return result == pdPASS ? ESP_OK : ESP_ERR_NO_MEM;
}

esp_err_t dmd_scene_pack_cancel(void)
{
    xSemaphoreTake(s_lock, portMAX_DELAY);
    if (!s_status.running) {
        xSemaphoreGive(s_lock);
        return ESP_ERR_INVALID_STATE;
    }
    s_status.cancel_requested = true;
    strlcpy(s_status.message, "Cancellation requested", sizeof(s_status.message));
    xSemaphoreGive(s_lock);
    return ESP_OK;
}

void dmd_scene_pack_get_status(dmd_scene_pack_status_t *status)
{
    if (status == NULL || s_lock == NULL) return;
    xSemaphoreTake(s_lock, portMAX_DELAY);
    *status = s_status;
    xSemaphoreGive(s_lock);
}
