#include "dmd_scene.h"

#include <stdbool.h>
#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "dmd_storage.h"
#include "dmd_scene_metadata.h"
#include "esp_check.h"
#include "esp_heap_caps.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "sdkconfig.h"

#define SCN_HEADER_SIZE 6
#define SCN_STORYBOARD_SIZE 36
#define SCN_FRAME_HEADER_SIZE 8
#define SCN_PACKED_PIXEL_SIZE (DMD_SCENE_PIXEL_COUNT / 2)
#define SCN_MASK_SIZE (DMD_SCENE_PIXEL_COUNT / 8)
#define SCN_MAX_FRAMES 512

typedef struct {
    const uint8_t *start;
    const uint8_t *end;
    const char *file_name;
    const char *display_name;
} scene_blob_t;

#define DECLARE_SCENE(number) \
    extern const uint8_t scene_##number##_start[] \
        asm("_binary_scene_" #number "_scn_start"); \
    extern const uint8_t scene_##number##_end[] \
        asm("_binary_scene_" #number "_scn_end")

#if CONFIG_DMD_QEMU
DECLARE_SCENE(00);
DECLARE_SCENE(01);
DECLARE_SCENE(02);
DECLARE_SCENE(03);
DECLARE_SCENE(04);
DECLARE_SCENE(05);
DECLARE_SCENE(06);
DECLARE_SCENE(07);
DECLARE_SCENE(08);
DECLARE_SCENE(09);
DECLARE_SCENE(10);
#endif

#if CONFIG_DMD_QEMU
static const scene_blob_t QEMU_SCENES[DMD_QEMU_SCENE_COUNT] = {
    {scene_00_start, scene_00_end, "got06.scn", "GOT06 - Game of Thrones"},
    {scene_01_start, scene_01_end, "afm01.scn", "AFM01 - Attack from Mars"},
    {scene_02_start, scene_02_end, "RD0868.scn", "RD0868"},
    {scene_03_start, scene_03_end, "RD0959.scn", "RD0959"},
    {scene_04_start, scene_04_end, "RD1116.scn", "RD1116"},
    {scene_05_start, scene_05_end, "RD1385.scn", "RD1385"},
    {scene_06_start, scene_06_end, "RD1448.scn", "RD1448"},
    {scene_07_start, scene_07_end, "RD1474.scn", "RD1474"},
    {scene_08_start, scene_08_end, "RD1695.scn", "RD1695"},
    {scene_09_start, scene_09_end, "RD1701.scn", "RD1701"},
    {scene_10_start, scene_10_end, "RD1891.scn", "RD1891"},
};
#endif

static const char *TAG = "dmd_scene";
static SemaphoreHandle_t s_lock;
static scene_blob_t *s_scenes;
static dmd_scene_metadata_t *s_metadata;
static uint16_t s_scene_count;
static const uint8_t *s_data;
static size_t s_size;
static uint8_t *s_owned_data;
static uint32_t s_frame_offsets[SCN_MAX_FRAMES];
static uint32_t s_mask_offsets[SCN_MAX_FRAMES];
static dmd_scene_info_t s_info;

#if !CONFIG_DMD_QEMU
static int scene_name_compare(const void *left, const void *right)
{
    const scene_blob_t *left_scene = left;
    const scene_blob_t *right_scene = right;
    return strcasecmp(left_scene->file_name, right_scene->file_name);
}
#endif

static uint16_t read_u16(size_t offset)
{
    return (uint16_t)(s_data[offset] | ((uint16_t)s_data[offset + 1] << 8));
}

static bool can_read(size_t offset, size_t count)
{
    return offset <= s_size && count <= s_size - offset;
}

static void release_owned_data(void)
{
    free(s_owned_data);
    s_owned_data = NULL;
}

static esp_err_t load_scene_data(const scene_blob_t *scene)
{
    if (scene->start != NULL && scene->end != NULL) {
        release_owned_data();
        s_data = scene->start;
        s_size = (size_t)(scene->end - scene->start);
        return ESP_OK;
    }

    char path[96];
    snprintf(
        path,
        sizeof(path),
        "%s/%s",
        DMD_STORAGE_SCENES,
        scene->file_name);
    FILE *file = fopen(path, "rb");
    if (file == NULL) {
        ESP_LOGE(TAG, "Could not open %s", path);
        return ESP_ERR_NOT_FOUND;
    }
    if (fseek(file, 0, SEEK_END) != 0) {
        fclose(file);
        return ESP_FAIL;
    }
    long length = ftell(file);
    if (length <= 0 || fseek(file, 0, SEEK_SET) != 0) {
        fclose(file);
        return ESP_ERR_INVALID_SIZE;
    }
    uint8_t *loaded_data = heap_caps_malloc(
        (size_t)length,
        MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    if (loaded_data == NULL) {
        loaded_data = heap_caps_malloc((size_t)length, MALLOC_CAP_8BIT);
    }
    if (loaded_data == NULL) {
        fclose(file);
        return ESP_ERR_NO_MEM;
    }
    size_t read = fread(loaded_data, 1, (size_t)length, file);
    fclose(file);
    if (read != (size_t)length) {
        free(loaded_data);
        return ESP_FAIL;
    }
    release_owned_data();
    s_owned_data = loaded_data;
    s_data = loaded_data;
    s_size = (size_t)length;
    return ESP_OK;
}

static esp_err_t parse_scene(uint16_t index)
{
    if (index >= s_scene_count) {
        return ESP_ERR_INVALID_ARG;
    }

    const scene_blob_t *scene = &s_scenes[index];
    ESP_RETURN_ON_ERROR(load_scene_data(scene), TAG, "load scene data");
    if (!can_read(0, SCN_HEADER_SIZE)) {
        return ESP_ERR_INVALID_SIZE;
    }

    uint16_t version = read_u16(0);
    uint16_t frame_count = read_u16(2);
    uint16_t storyboard_count = read_u16(4);
    if (version != 1 || frame_count == 0 || frame_count > SCN_MAX_FRAMES ||
        storyboard_count == 0) {
        ESP_LOGE(
            TAG,
            "%s unsupported header: version=%u frames=%u storyboards=%u",
            scene->file_name,
            version,
            frame_count,
            storyboard_count);
        return ESP_ERR_INVALID_VERSION;
    }

    size_t storyboard_bytes = (size_t)storyboard_count * SCN_STORYBOARD_SIZE;
    if (!can_read(SCN_HEADER_SIZE, storyboard_bytes)) {
        return ESP_ERR_INVALID_SIZE;
    }
    size_t storyboard = SCN_HEADER_SIZE;
    uint16_t first_delay = read_u16(storyboard);
    uint16_t clock_above_first_value = read_u16(storyboard + 2);
    uint16_t blank_first_value = read_u16(storyboard + 4);
    uint16_t normal_delay = read_u16(storyboard + 6);
    uint16_t clock_above_frames_value = read_u16(storyboard + 8);
    uint16_t final_hold = read_u16(storyboard + 10);
    uint16_t clock_above_last_value = read_u16(storyboard + 12);
    uint16_t blank_last_value = read_u16(storyboard + 14);
    if (clock_above_first_value > 1 || blank_first_value > 1 ||
        clock_above_frames_value > 1 || clock_above_last_value > 1 ||
        blank_last_value > 1) {
        ESP_LOGE(TAG, "%s has an invalid storyboard flag", scene->file_name);
        return ESP_ERR_INVALID_ARG;
    }
    bool clock_above_first = clock_above_first_value != 0;
    bool blank_first = blank_first_value != 0;
    bool clock_above_frames = clock_above_frames_value != 0;
    bool clock_above_last = clock_above_last_value != 0;
    bool blank_last = blank_last_value != 0;
    if (normal_delay == 0) {
        normal_delay = 100;
    }

    size_t offset = SCN_HEADER_SIZE + storyboard_bytes;
    for (uint16_t frame = 0; frame < frame_count; frame++) {
        if (!can_read(offset, SCN_FRAME_HEADER_SIZE)) {
            return ESP_ERR_INVALID_SIZE;
        }
        uint16_t width = read_u16(offset);
        uint16_t height = read_u16(offset + 2);
        uint16_t bpp = read_u16(offset + 4);
        uint16_t has_mask = read_u16(offset + 6);
        if (width != 128 || height != 32 || bpp != 4 || has_mask > 1) {
            ESP_LOGE(
                TAG,
                "%s frame %u unsupported: %ux%u %ubpp mask=%u",
                scene->file_name,
                frame,
                width,
                height,
                bpp,
                has_mask);
            return ESP_ERR_NOT_SUPPORTED;
        }

        size_t frame_size = SCN_FRAME_HEADER_SIZE + SCN_PACKED_PIXEL_SIZE +
                            (has_mask ? SCN_MASK_SIZE : 0);
        if (!can_read(offset, frame_size)) {
            return ESP_ERR_INVALID_SIZE;
        }
        s_frame_offsets[frame] = offset + SCN_FRAME_HEADER_SIZE;
        s_mask_offsets[frame] = has_mask
            ? offset + SCN_FRAME_HEADER_SIZE + SCN_PACKED_PIXEL_SIZE
            : 0;
        offset += frame_size;
    }
    if (offset != s_size) {
        ESP_LOGE(
            TAG,
            "%s has %u unexpected trailing bytes",
            scene->file_name,
            (unsigned)(s_size - offset));
        return ESP_ERR_INVALID_SIZE;
    }

    memset(&s_info, 0, sizeof(s_info));
    s_info.index = index;
    s_info.frame_count = frame_count;
    s_info.first_delay_ms = first_delay;
    s_info.normal_delay_ms = normal_delay;
    s_info.final_hold_ms = final_hold;
    s_info.clock_above_first = clock_above_first;
    s_info.blank_first = blank_first;
    s_info.clock_above_frames = clock_above_frames;
    s_info.clock_above_last = clock_above_last;
    s_info.blank_last = blank_last;
    s_info.clock_style = s_data[storyboard + 16];
    s_info.clock_x = s_data[storyboard + 17];
    s_info.clock_y = s_data[storyboard + 18];
    uint16_t first_normal_frame =
        first_delay > 0 && !blank_first ? 1 : 0;
    s_info.step_count =
        (first_delay > 0 ? 1 : 0) +
        (frame_count - first_normal_frame) +
        (final_hold > 0 ? 1 : 0);
    s_info.source_size = s_size;
    strlcpy(s_info.file_name, scene->file_name, sizeof(s_info.file_name));
    strlcpy(s_info.display_name, scene->display_name, sizeof(s_info.display_name));
    return ESP_OK;
}

esp_err_t dmd_scene_init(void)
{
    s_lock = xSemaphoreCreateMutex();
    if (s_lock == NULL) {
        return ESP_ERR_NO_MEM;
    }

#if CONFIG_DMD_QEMU
    s_scene_count = DMD_QEMU_SCENE_COUNT;
    s_scenes = calloc(s_scene_count, sizeof(*s_scenes));
    s_metadata = calloc(s_scene_count, sizeof(*s_metadata));
    if (s_scenes == NULL || s_metadata == NULL) {
        return ESP_ERR_NO_MEM;
    }
    memcpy(s_scenes, QEMU_SCENES, sizeof(QEMU_SCENES));
#else
    if (dmd_storage_available()) {
        s_scenes = heap_caps_calloc(
            DMD_SCENE_MAX_COUNT,
            sizeof(*s_scenes),
            MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
        if (s_scenes == NULL) {
            s_scenes = calloc(DMD_SCENE_MAX_COUNT, sizeof(*s_scenes));
        }
        if (s_scenes == NULL) {
            return ESP_ERR_NO_MEM;
        }
        DIR *directory = opendir(DMD_STORAGE_SCENES);
        if (directory != NULL) {
            struct dirent *entry;
            while ((entry = readdir(directory)) != NULL &&
                   s_scene_count < DMD_SCENE_MAX_COUNT) {
                const char *extension = strrchr(entry->d_name, '.');
                if (extension == NULL || strcasecmp(extension, ".scn") != 0) {
                    continue;
                }
                char *file_name = strdup(entry->d_name);
                if (file_name == NULL) {
                    closedir(directory);
                    return ESP_ERR_NO_MEM;
                }
                s_scenes[s_scene_count++] = (scene_blob_t){
                    .file_name = file_name,
                    .display_name = file_name,
                };
            }
            closedir(directory);
        } else {
            ESP_LOGW(TAG, "Could not open scene directory %s", DMD_STORAGE_SCENES);
        }
        if (s_scene_count == DMD_SCENE_MAX_COUNT) {
            ESP_LOGW(TAG, "Scene index reached its %u-file limit", DMD_SCENE_MAX_COUNT);
        }
        if (s_scene_count > 1) {
            qsort(
                s_scenes,
                s_scene_count,
                sizeof(*s_scenes),
                scene_name_compare);
        }
        if (s_scene_count > 0) {
            s_metadata = heap_caps_calloc(
                s_scene_count,
                sizeof(*s_metadata),
                MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
            if (s_metadata == NULL) {
                s_metadata = calloc(s_scene_count, sizeof(*s_metadata));
            }
            if (s_metadata == NULL) {
                return ESP_ERR_NO_MEM;
            }
        }
    }
#endif

    dmd_scene_metadata_catalog_t *catalog = NULL;
    esp_err_t metadata_error = dmd_scene_metadata_load(&catalog);
    if (metadata_error != ESP_OK) {
        ESP_LOGW(
            TAG,
            "Shared scene metadata not applied: %s",
            esp_err_to_name(metadata_error));
    }
    for (uint16_t index = 0; index < s_scene_count; index++) {
        dmd_scene_metadata_resolve(
            catalog,
            s_scenes[index].file_name,
            &s_metadata[index]);
        s_scenes[index].display_name = s_metadata[index].display_name;
    }
    dmd_scene_metadata_free(catalog);

#if CONFIG_DMD_QEMU
    for (uint16_t index = 0; index < s_scene_count; index++) {
        esp_err_t error = parse_scene(index);
        if (error != ESP_OK) {
            return error;
        }
    }
#endif
    if (s_scene_count == 0) {
        ESP_LOGW(
            TAG,
            "No valid scenes found in %s; clock-only mode is active",
            DMD_STORAGE_SCENES);
        return ESP_OK;
    }
    ESP_RETURN_ON_ERROR(parse_scene(0), TAG, "select default scene");
    ESP_LOGI(TAG, "%u scenes validated", s_scene_count);
    ESP_LOGI(
        TAG,
        "%s ready: %u frames, %u ms timing, %u ms final hold",
        s_info.file_name,
        s_info.frame_count,
        s_info.normal_delay_ms,
        s_info.final_hold_ms);
    return ESP_OK;
}

esp_err_t dmd_scene_select(uint16_t index)
{
    if (s_lock == NULL || index >= s_scene_count) {
        return ESP_ERR_INVALID_ARG;
    }
    xSemaphoreTake(s_lock, portMAX_DELAY);
    esp_err_t error = index == s_info.index ? ESP_OK : parse_scene(index);
    if (error == ESP_OK) {
        ESP_LOGI(TAG, "Selected %s", s_info.file_name);
    }
    xSemaphoreGive(s_lock);
    return error;
}

uint16_t dmd_scene_count(void)
{
    return s_scene_count;
}

const char *dmd_scene_file_name(uint16_t index)
{
    return index < s_scene_count ? s_scenes[index].file_name : "";
}

const char *dmd_scene_display_name(uint16_t index)
{
    return index < s_scene_count ? s_scenes[index].display_name : "";
}

void dmd_scene_get_metadata(uint16_t index, dmd_scene_metadata_t *metadata)
{
    if (metadata == NULL) {
        return;
    }
    if (index >= s_scene_count) {
        memset(metadata, 0, sizeof(*metadata));
        return;
    }
    *metadata = s_metadata[index];
}

uint16_t dmd_scene_next_game(uint16_t current)
{
    if (s_scene_count == 0) {
        return 0;
    }
    if (current >= s_scene_count) {
        current = 0;
    }
    const char *current_game = s_metadata[current].game;
    for (uint16_t offset = 1; offset < s_scene_count; offset++) {
        uint16_t candidate = (uint16_t)((current + offset) % s_scene_count);
        const char *candidate_game = s_metadata[candidate].game;
        if (strcasecmp(candidate_game, current_game) != 0) {
            return candidate;
        }
    }
    return current;
}

uint16_t dmd_scene_next_in_game(uint16_t current)
{
    if (s_scene_count == 0) {
        return 0;
    }
    if (current >= s_scene_count) {
        current = 0;
    }
    const char *current_game = s_metadata[current].game;
    for (uint16_t offset = 1; offset < s_scene_count; offset++) {
        uint16_t candidate = (uint16_t)((current + offset) % s_scene_count);
        if (strcasecmp(s_metadata[candidate].game, current_game) == 0) {
            return candidate;
        }
    }
    return current;
}

void dmd_scene_get_info(dmd_scene_info_t *info)
{
    if (info == NULL || s_lock == NULL) {
        return;
    }
    xSemaphoreTake(s_lock, portMAX_DELAY);
    *info = s_info;
    xSemaphoreGive(s_lock);
}

esp_err_t dmd_scene_decode_step(
    uint16_t step,
    uint8_t output[DMD_SCENE_PIXEL_COUNT],
    uint8_t mask[DMD_SCENE_PIXEL_COUNT],
    dmd_scene_step_info_t *step_info)
{
    if (output == NULL || mask == NULL || step_info == NULL || s_lock == NULL) {
        return ESP_ERR_INVALID_ARG;
    }

    xSemaphoreTake(s_lock, portMAX_DELAY);
    if (step >= s_info.step_count) {
        xSemaphoreGive(s_lock);
        return ESP_ERR_INVALID_ARG;
    }
    memset(step_info, 0, sizeof(*step_info));
    uint16_t cursor = 0;
    uint16_t first_normal_frame = 0;
    if (s_info.first_delay_ms > 0) {
        if (step == cursor) {
            step_info->frame_index = 0;
            step_info->duration_ms = s_info.first_delay_ms;
            step_info->blank = s_info.blank_first;
            step_info->clock_above = s_info.clock_above_first;
        }
        cursor++;
        if (!s_info.blank_first) {
            first_normal_frame = 1;
        }
    }

    uint16_t normal_count = s_info.frame_count - first_normal_frame;
    if (step >= cursor && step < cursor + normal_count) {
        step_info->frame_index = first_normal_frame + (step - cursor);
        step_info->duration_ms = s_info.normal_delay_ms;
        step_info->clock_above = s_info.clock_above_frames;
    } else if (step >= cursor + normal_count) {
        step_info->frame_index = s_info.frame_count - 1;
        step_info->duration_ms = s_info.final_hold_ms;
        step_info->blank = s_info.blank_last;
        step_info->clock_above = s_info.clock_above_last;
    }
    if (step_info->duration_ms == 0) {
        step_info->duration_ms = 100;
    }
    if (step_info->blank) {
        memset(output, 0, DMD_SCENE_PIXEL_COUNT);
        memset(mask, 0, DMD_SCENE_PIXEL_COUNT);
    } else {
        const uint8_t *packed =
            s_data + s_frame_offsets[step_info->frame_index];
        for (size_t index = 0; index < SCN_PACKED_PIXEL_SIZE; index++) {
            output[index * 2] = packed[index] & 0x0f;
            output[index * 2 + 1] = packed[index] >> 4;
        }
        uint32_t mask_offset = s_mask_offsets[step_info->frame_index];
        if (mask_offset == 0) {
            memset(mask, 0, DMD_SCENE_PIXEL_COUNT);
        } else {
            const uint8_t *packed_mask = s_data + mask_offset;
            for (size_t index = 0; index < SCN_MASK_SIZE; index++) {
                for (uint8_t bit = 0; bit < 8; bit++) {
                    mask[index * 8 + bit] =
                        (packed_mask[index] >> bit) & 1U;
                }
            }
        }
    }
    xSemaphoreGive(s_lock);
    return ESP_OK;
}
