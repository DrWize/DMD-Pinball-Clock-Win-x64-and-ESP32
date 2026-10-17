// Opt-in measurement. No settings writes, clock setting, or scheduling changes.
#include "dmd_timing.h"
#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include "cJSON.h"
#include "dmd_display.h"
#include "dmd_storage.h"
#include "dmd_serial.h"
#include "esp_app_desc.h"
#include "esp_heap_caps.h"
#include "esp_mac.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"
#include "mbedtls/sha256.h"
#include "sdkconfig.h"

#define LOG_ROOT DMD_STORAGE_LOGS "/comparison"
typedef struct { uint16_t frame, delay; int64_t loop, decoded, painted; } timing_sample_t;
static timing_sample_t *s_samples;
static volatile bool s_enabled, s_active, s_detailed, s_overflow;
static volatile uint32_t s_count;
static uint16_t s_capacity;
static int64_t s_start, s_end, s_last_command;
static SemaphoreHandle_t s_done;
static dmd_display_state_t s_previous;
static uint32_t s_previous_revision;
static char s_session[49];
static const char *s_id;
static unsigned char s_file_block[4096];

static const char *board(void)
{
#if CONFIG_DMD_BOARD_3_49_LANDSCAPE
    return "Waveshare349B";
#else
    return "Waveshare7";
#endif
}

static void hex_digest(const unsigned char *bytes, size_t count, char *text)
{
    for (size_t i = 0; i < count; i++) sprintf(text + i * 2, "%02x", bytes[i]);
    text[count * 2] = 0;
}

static void emit(cJSON *json, bool done)
{
    if (json == NULL) return;
    cJSON_AddNumberToObject(json, "protocol", 1);
    cJSON_AddStringToObject(json, "id", s_id);
    cJSON_AddBoolToObject(json, "done", done);
    char *text = cJSON_PrintUnformatted(json);
    if (text != NULL) { dmd_serial_timing_reply(text); free(text); }
    cJSON_Delete(json);
}

static void error(const char *reason)
{
    cJSON *json = cJSON_CreateObject();
    cJSON_AddBoolToObject(json, "ok", false);
    cJSON_AddStringToObject(json, "error", reason);
    emit(json, true);
}

static cJSON *ok(void)
{
    cJSON *json = cJSON_CreateObject();
    cJSON_AddBoolToObject(json, "ok", true);
    return json;
}

static const char *string(cJSON *json, const char *key)
{
    cJSON *value = cJSON_GetObjectItemCaseSensitive(json, key);
    return cJSON_IsString(value) ? value->valuestring : "";
}

static bool token(const char *value)
{
    size_t length = strlen(value);
    if (!length || length > 48) return false;
    for (size_t i = 0; i < length; i++) {
        if (!isalnum((unsigned char)value[i]) && value[i] != '-' && value[i] != '_') return false;
    }
    return true;
}

static bool file_hash(const char *path, char hash[65], long *size)
{
    FILE *file = fopen(path, "rb");
    if (file == NULL) return false;
    mbedtls_sha256_context context;
    mbedtls_sha256_init(&context);
    bool valid = mbedtls_sha256_starts(&context, 0) == 0;
    size_t count; long total = 0;
    while (valid && (count = fread(s_file_block, 1, sizeof(s_file_block), file)) > 0) {
        valid = mbedtls_sha256_update(&context, s_file_block, count) == 0;
        total += count;
        if ((total & 65535) == 0) vTaskDelay(1);
    }
    valid = valid && !ferror(file);
    fclose(file);
    unsigned char digest[32];
    valid = valid && mbedtls_sha256_finish(&context, digest) == 0;
    mbedtls_sha256_free(&context);
    if (valid) { hex_digest(digest, 32, hash); if (size != NULL) *size = total; }
    return valid;
}

static bool stop_display(void)
{
    dmd_display_show_clock();
    // Require a stable stopped observation, rather than a stale state before
    // the command is consumed by the display task.
    int stable = 0;
    for (int i = 0; i < 250; i++) {
        dmd_display_state_t state; dmd_display_get_state(&state);
        stable = state.playing_scene ? 0 : stable + 1;
        if (stable >= 10) return true;
        vTaskDelay(pdMS_TO_TICKS(20));
    }
    return false;
}

static void restore_display(void)
{
    dmd_settings_t current; dmd_settings_get(&current);
    bool play = current.revision == s_previous_revision ? s_previous.playing_scene : current.play_scene;
    uint16_t index = current.revision == s_previous_revision ? s_previous.scene_index : current.scene_index;
    s_enabled = false;
    if (play) dmd_display_play_scene(index); else dmd_display_show_clock();
}

void dmd_timing_get_status(dmd_timing_status_t *out)
{
    *out = (dmd_timing_status_t){s_enabled, s_active, s_detailed, s_count};
}

bool dmd_timing_enabled(void) { return s_enabled; }

void dmd_timing_apply_settings(dmd_settings_t *settings)
{
    if (!s_enabled) return;
    if (!s_active && esp_timer_get_time() - s_last_command > 180000000) {
        restore_display();
        return;
    }
    settings->automatic_cycle = false;
    settings->show_information = false;
    settings->show_seconds = false;
    settings->screen_schedule_enabled = false;
    settings->reboot_schedule_enabled = false;
    settings->display_on = true;
    settings->brightness = 100;
    settings->glow_strength = 50;
    settings->hot_core_enabled = false;
    settings->color_preset = DMD_COLOR_ORANGE;
}

void dmd_timing_step(uint16_t step, const dmd_scene_step_info_t *info, int64_t loop, int64_t decoded)
{
    if (!s_active) return;
    if (step != s_count || step >= s_capacity) { s_overflow = true; return; }
    if (s_count == 0) s_start = decoded;
    if (s_detailed) s_samples[step] = (timing_sample_t){info->frame_index, info->duration_ms, loop, decoded, 0};
    s_count++;
}

void dmd_timing_painted(int64_t now)
{
    if (s_active && s_detailed && s_count && s_count <= s_capacity && !s_samples[s_count - 1].painted)
        s_samples[s_count - 1].painted = now;
}

void dmd_timing_finished(int64_t now)
{
    if (!s_active) return;
    s_end = now;
    s_active = false;
    xSemaphoreGive(s_done);
}

static void inventory(cJSON *request)
{
    cJSON *index = cJSON_GetObjectItemCaseSensitive(request, "index");
    int first = 0, end = dmd_scene_count();
    if (cJSON_IsNumber(index)) {
        first = index->valueint;
        if (index->valuedouble != first || first < 0 || first >= end) { error("invalid_index"); return; }
        end = first + 1;
    }
    for (int i = first; i < end; i++) {
        s_last_command = esp_timer_get_time();
        char path[192], hash[65]; long size;
        snprintf(path, sizeof(path), DMD_STORAGE_SCENES "/%s", dmd_scene_file_name(i));
        if (!file_hash(path, hash, &size)) { error("scene_read_failed"); return; }
        cJSON *row = ok();
        cJSON_AddStringToObject(row, "type", "scene");
        cJSON_AddNumberToObject(row, "index", i);
        cJSON_AddStringToObject(row, "name", dmd_scene_file_name(i));
        cJSON_AddStringToObject(row, "sha256", hash);
        cJSON_AddNumberToObject(row, "bytes", size);
        emit(row, false);
    }
    cJSON *end_row = ok(); cJSON_AddNumberToObject(end_row, "count", end - first); emit(end_row, true);
}

static bool result_path(cJSON *request, char path[256])
{
    const char *session = string(request, "session"), *stage = string(request, "stage"), *id = string(request, "caseId");
    cJSON *repeat = cJSON_GetObjectItemCaseSensitive(request, "repeat");
    if (!token(session) || !token(stage) || !token(id) || !cJSON_IsNumber(repeat) ||
        repeat->valuedouble != repeat->valueint || repeat->valueint < 0 || repeat->valueint > 2) return false;
    snprintf(path, 256, LOG_ROOT "/%s/%s/%s-r%d.jsonl", session, stage, id, repeat->valueint);
    return true;
}

static bool committed(const char *path)
{
    FILE *file = fopen(path, "rb"); if (file == NULL) return false;
    char tail[96] = {0};
    if (fseek(file, 0, SEEK_END) != 0) { fclose(file); return false; }
    long size = ftell(file);
    if (size < 30) { fclose(file); return false; }
    fseek(file, size > 95 ? size - 95 : 0, SEEK_SET);
    size_t count = fread(tail, 1, sizeof(tail) - 1, file); tail[count] = 0;
    fclose(file);
    char *last = strstr(tail, "{\"kind\":\"commit\"");
    if (last == NULL) return false;
    cJSON *json = cJSON_Parse(last);
    bool valid = cJSON_IsObject(json) && cJSON_IsNumber(cJSON_GetObjectItemCaseSensitive(json, "count"));
    cJSON_Delete(json); return valid;
}

static void get_result(cJSON *request)
{
    char path[256], hash[65]; long size;
    if (!result_path(request, path)) { error("invalid_result_path"); return; }
    if (!committed(path)) { cJSON *json = ok(); cJSON_AddBoolToObject(json, "found", false); emit(json, true); return; }
    if (!file_hash(path, hash, &size)) { error("result_read_failed"); return; }
    FILE *file = fopen(path, "rb"); if (file == NULL) { error("result_read_failed"); return; }
    char line[1536];
    while (fgets(line, sizeof(line), file)) {
        cJSON *json = ok(); cJSON_AddStringToObject(json, "type", "record");
        cJSON_AddStringToObject(json, "line", line); emit(json, false);
    }
    bool valid = !ferror(file); fclose(file);
    if (!valid) { error("result_read_failed"); return; }
    cJSON *json = ok(); cJSON_AddBoolToObject(json, "found", true);
    cJSON_AddNumberToObject(json, "bytes", size); cJSON_AddStringToObject(json, "sha256", hash); emit(json, true);
}

static void run_case(cJSON *request)
{
    char path[256], temporary[272], hash[65];
    cJSON *index = cJSON_GetObjectItemCaseSensitive(request, "index");
    cJSON *timeout = cJSON_GetObjectItemCaseSensitive(request, "timeoutMs");
    cJSON *detailed = cJSON_GetObjectItemCaseSensitive(request, "detailed");
    if (!result_path(request, path) || strcmp(string(request, "session"), s_session) ||
        !cJSON_IsNumber(index) || index->valuedouble != index->valueint || index->valueint < 0 || index->valueint >= dmd_scene_count() ||
        !cJSON_IsNumber(timeout) || timeout->valuedouble < 1000 || timeout->valuedouble > 3600000 ||
        !cJSON_IsBool(detailed) || strlen(string(request, "sha256")) != 64) { error("invalid_capture_request"); return; }
    if (committed(path)) { cJSON *json = ok(); cJSON_AddBoolToObject(json, "cached", true); emit(json, true); return; }
    if (!stop_display()) { error("display_did_not_stop"); return; }
    free(s_samples); s_samples = NULL;
    int64_t load_start = esp_timer_get_time();
    if (dmd_scene_reload(index->valueint) != ESP_OK) { error("scene_load_failed"); return; }
    int64_t load_end = esp_timer_get_time();
    if (dmd_scene_source_hash(hash) != ESP_OK || strcmp(hash, string(request, "sha256"))) { error("scene_hash_mismatch"); return; }
    dmd_scene_info_t info; dmd_scene_get_info(&info);
    if (!info.step_count) { error("empty_scene"); return; }
    s_capacity = info.step_count;
    s_detailed = cJSON_IsTrue(detailed);
    if (s_detailed) {
        s_samples = heap_caps_calloc(s_capacity, sizeof(*s_samples), MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
        if (s_samples == NULL) { error("capture_buffer_unavailable"); return; }
    }
    s_count = 0; s_start = 0; s_end = 0; s_overflow = false;
    xSemaphoreTake(s_done, 0);
    s_active = true;
    int64_t command_at = esp_timer_get_time();
    dmd_display_play_scene(index->valueint);
    bool finished = xSemaphoreTake(s_done, pdMS_TO_TICKS(timeout->valueint)) == pdTRUE;
    s_active = false;
    bool stopped = stop_display();
    bool valid = finished && stopped && !s_overflow && s_count == s_capacity && s_start > 0 && s_end > s_start;
    if (s_detailed) for (unsigned i = 0; i < s_count && i < s_capacity; i++) valid = valid && s_samples[i].painted >= s_samples[i].decoded;
    valid = valid && dmd_scene_source_hash(hash) == ESP_OK && !strcmp(hash, string(request, "sha256"));
    if (!valid) {
        if (stopped) { free(s_samples); s_samples = NULL; }
        error("capture_incomplete"); return;
    }
    mkdir(DMD_STORAGE_LOGS, 0755); mkdir(LOG_ROOT, 0755);
    char directory[192]; snprintf(directory, sizeof(directory), LOG_ROOT "/%s", s_session); mkdir(directory, 0755);
    snprintf(directory, sizeof(directory), LOG_ROOT "/%s/%s", s_session, string(request, "stage")); mkdir(directory, 0755);
    snprintf(temporary, sizeof(temporary), "%s.tmp", path);
    FILE *file = fopen(temporary, "wb");
    if (file == NULL) { free(s_samples); s_samples = NULL; error("log_open_failed"); return; }
    char elf[65]; hex_digest(esp_app_get_description()->app_elf_sha256, 32, elf);
    fprintf(file, "{\"kind\":\"header\",\"schemaVersion\":1,\"runId\":\"%s\",\"stage\":\"%s\",\"caseId\":\"%s\",\"repeat\":%d,\"board\":\"%s\",\"firmware\":\"%s\",\"elfSha256\":\"%s\",\"sha256\":\"%s\",\"steps\":%u,\"frames\":%u,\"detailed\":%s,\"loadStartUs\":%lld,\"loadEndUs\":%lld,\"commandUs\":%lld,\"colorPreset\":0,\"brightness\":100,\"glowStrength\":50,\"showSeconds\":false,\"showInformation\":false}\n",
        s_session, string(request, "stage"), string(request, "caseId"), cJSON_GetObjectItemCaseSensitive(request, "repeat")->valueint,
        board(), esp_app_get_description()->version, elf, hash, info.step_count, info.frame_count, s_detailed ? "true" : "false",
        (long long)load_start, (long long)load_end, (long long)command_at);
    if (s_detailed) for (unsigned i = 0; i < s_count; i++) fprintf(file,
        "{\"kind\":\"step\",\"n\":%u,\"frame\":%u,\"delay\":%u,\"loop\":%lld,\"decoded\":%lld,\"painted\":%lld}\n", i,
        s_samples[i].frame, s_samples[i].delay, (long long)s_samples[i].loop, (long long)s_samples[i].decoded, (long long)s_samples[i].painted);
    fprintf(file, "{\"kind\":\"result\",\"count\":%lu,\"start\":%lld,\"end\":%lld,\"status\":\"Completed\"}\n", (unsigned long)s_count, (long long)s_start, (long long)s_end);
    fprintf(file, "{\"kind\":\"commit\",\"count\":%lu}\n", (unsigned long)s_count);
    valid = !ferror(file) && fflush(file) == 0;
    if (valid) valid = fsync(fileno(file)) == 0;
    if (fclose(file) != 0) valid = false;
    free(s_samples); s_samples = NULL;
    if (!valid || rename(temporary, path) != 0 || !committed(path)) { error("log_commit_failed"); return; }
    cJSON *json = ok(); cJSON_AddNumberToObject(json, "steps", s_count); emit(json, true);
}

bool dmd_timing_handle_line(char *line)
{
    if (strncmp(line, "DMDTIMING:", 10)) return false;
    cJSON *request = cJSON_ParseWithOpts(line + 10, NULL, true);
    if (!cJSON_IsObject(request)) { cJSON_Delete(request); return true; }
    s_id = string(request, "id");
    if (!token(s_id)) { cJSON_Delete(request); return true; }
    cJSON *version = cJSON_GetObjectItemCaseSensitive(request, "protocol");
    const char *op = string(request, "op");
    s_last_command = esp_timer_get_time();
    if (!cJSON_IsNumber(version) || version->valuedouble != 1) error("unsupported_protocol");
    else if (!strcmp(op, "hello") || !strcmp(op, "status")) {
        char elf[65], mac_text[18]; uint8_t mac[6];
        esp_read_mac(mac, ESP_MAC_WIFI_STA);
        snprintf(mac_text, sizeof(mac_text), "%02x:%02x:%02x:%02x:%02x:%02x", mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
        hex_digest(esp_app_get_description()->app_elf_sha256, 32, elf);
        cJSON *json = ok();
        cJSON_AddStringToObject(json, "board", board()); cJSON_AddStringToObject(json, "mac", mac_text);
        cJSON_AddStringToObject(json, "firmware", esp_app_get_description()->version); cJSON_AddStringToObject(json, "elfSha256", elf);
        cJSON_AddBoolToObject(json, "enabled", s_enabled); cJSON_AddBoolToObject(json, "active", s_active);
        cJSON_AddBoolToObject(json, "sdAvailable", dmd_storage_available());
        cJSON_AddNumberToObject(json, "uptimeSeconds", esp_timer_get_time() / 1000000);
        emit(json, true);
    } else if (!strcmp(op, "begin")) {
        if (!token(string(request, "session")) || !dmd_storage_available()) error("invalid_session_or_storage");
        else if (s_enabled && strcmp(s_session, string(request, "session"))) error("session_busy");
        else {
            if (s_done == NULL) s_done = xSemaphoreCreateBinary();
            if (s_done == NULL) error("capture_buffer_unavailable");
            else {
                if (!s_enabled) {
                    dmd_display_get_state(&s_previous);
                    dmd_settings_t settings; dmd_settings_get(&settings); s_previous_revision = settings.revision;
                }
                strlcpy(s_session, string(request, "session"), sizeof(s_session)); s_enabled = true;
                if (stop_display()) emit(ok(), true); else { restore_display(); error("display_did_not_stop"); }
            }
        }
    } else if (!strcmp(op, "end")) {
        if (s_enabled && strcmp(s_session, string(request, "session"))) error("session_mismatch");
        else { s_active = false; if (s_enabled) restore_display(); emit(ok(), true); }
    } else if (!strcmp(op, "get")) get_result(request);
    else if (!s_enabled || strcmp(s_session, string(request, "session"))) error("session_not_enabled");
    else if (!strcmp(op, "inventory")) inventory(request);
    else if (!strcmp(op, "run")) run_case(request);
    else error("unsupported_operation");
    cJSON_Delete(request); s_id = NULL;
    return true;
}
