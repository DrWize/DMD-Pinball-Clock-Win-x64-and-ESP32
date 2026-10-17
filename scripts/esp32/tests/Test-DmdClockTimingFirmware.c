#include <assert.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <stdint.h>
#include <sys/stat.h>
#include <unistd.h>
#include <direct.h>

static char output[32768];
static bool fail_allocation, fail_sync, simulate_timeout, missing_paint, overflow_steps, interrupted_steps;
static int64_t simulated_us = 25000000;
static int done, plays;
static void mapped(const char *path, char target[512])
{
    snprintf(target, 512, "%s", !strncmp(path, "/sd/dmd/", 8) ? path + 8 : path);
}
static FILE *fake_fopen(const char *path, const char *mode) { char target[512]; mapped(path, target); return fopen(target, mode); }
static int fake_mkdir(const char *path, int mode) { char target[512]; mapped(path, target); return _mkdir(target); }
static int fake_rename(const char *left, const char *right) { char a[512], b[512]; mapped(left, a); mapped(right, b); return rename(a, b); }
static int fake_fsync(int fd) { return fail_sync ? -1 : 0; }
static int fake_printf(const char *format, ...)
{
    va_list args; va_start(args, format);
    int n = vsnprintf(output + strlen(output), sizeof(output) - strlen(output), format, args);
    va_end(args); return n;
}
bool dmd_serial_timing_reply(const char *json)
{
    fake_printf("\nDMDTIMING:%s\n", json);
    return true;
}
static size_t fake_strlcpy(char *dst, const char *src, size_t capacity)
{
    size_t length = strlen(src), take = length < capacity - 1 ? length : capacity - 1;
    memcpy(dst, src, take); dst[take] = 0; return length;
}
#define fopen fake_fopen
#define mkdir fake_mkdir
#define rename fake_rename
#define fsync fake_fsync
#define printf fake_printf
#define strlcpy fake_strlcpy
#include "../../../firmware/dmdclock-esp32/main/dmd_timing.c"
#undef printf

static dmd_settings_t stored;
static dmd_display_state_t display;
static esp_app_desc_t app = {.version = "capture-test"};
const esp_app_desc_t *esp_app_get_description(void) { return &app; }
int64_t esp_timer_get_time(void) { return simulated_us; }
void vTaskDelay(int delay) { simulated_us += delay * 1000; }
SemaphoreHandle_t xSemaphoreCreateBinary(void) { return &done; }
int xSemaphoreTake(SemaphoreHandle_t semaphore, int ticks) { int value = done; done = 0; return value; }
int xSemaphoreGive(SemaphoreHandle_t semaphore) { done = 1; return 1; }
void *heap_caps_calloc(size_t count, size_t size, int caps) { return fail_allocation ? NULL : calloc(count, size); }
bool dmd_storage_available(void) { return true; }
esp_err_t esp_read_mac(uint8_t *mac, int type) { memset(mac, 1, 6); return ESP_OK; }
void dmd_settings_get(dmd_settings_t *out) { *out = stored; }
void dmd_display_get_state(dmd_display_state_t *out) { *out = display; }
void dmd_display_show_clock(void) { display.playing_scene = false; }
void dmd_display_play_scene(uint16_t index)
{
    display.playing_scene = true; plays++;
    if (simulate_timeout) return;
    for (unsigned i = 0; i < (interrupted_steps ? 1u : overflow_steps ? 3u : 2u); i++) {
        dmd_scene_step_info_t info = {.frame_index = i, .duration_ms = 100};
        int64_t loop = simulated_us; simulated_us += 30;
        dmd_timing_step(i, &info, loop, simulated_us);
        simulated_us += 30;
        if (!missing_paint) dmd_timing_painted(simulated_us);
        simulated_us += 100000;
    }
    dmd_timing_finished(simulated_us);
    display.playing_scene = false;
}
uint16_t dmd_scene_count(void) { return 1; }
const char *dmd_scene_file_name(uint16_t index) { return "test.scn"; }
esp_err_t dmd_scene_reload(uint16_t index) { simulated_us += 100; return ESP_OK; }
void dmd_scene_get_info(dmd_scene_info_t *info) { memset(info, 0, sizeof(*info)); info->frame_count = 2; info->step_count = 2; }
esp_err_t dmd_scene_source_hash(char hash[65]) { for (int i = 0; i < 32; i++) sprintf(hash + i * 2, "ab"); hash[64] = 0; return ESP_OK; }
void mbedtls_sha256_init(mbedtls_sha256_context *ctx) {}
void mbedtls_sha256_free(mbedtls_sha256_context *ctx) {}
int mbedtls_sha256_starts(mbedtls_sha256_context *ctx, int mode) { return 0; }
int mbedtls_sha256_update(mbedtls_sha256_context *ctx, const unsigned char *data, size_t size) { return 0; }
int mbedtls_sha256_finish(mbedtls_sha256_context *ctx, unsigned char *hash) { memset(hash, 0xab, 32); return 0; }

static void command(const char *arguments)
{
    char line[1024];
    snprintf(line, sizeof(line), "DMDTIMING:{\"protocol\":1,\"id\":\"test\",%s}", arguments);
    output[0] = 0;
    assert(dmd_timing_handle_line(line));
}
static void run(const char *id, bool detailed)
{
    char args[768];
    snprintf(args, sizeof(args), "\"op\":\"run\",\"session\":\"run\",\"stage\":\"main\",\"caseId\":\"%s\",\"repeat\":0,\"index\":0,\"timeoutMs\":30000,\"detailed\":%s,\"sha256\":\"abababababababababababababababababababababababababababababababab\"", id, detailed ? "true" : "false");
    command(args);
}
int main(void)
{
    memset(app.app_elf_sha256, 0xab, 32);
    stored.brightness = 33; stored.glow_strength = 12; stored.automatic_cycle = true; stored.revision = 7;
    assert(!dmd_timing_enabled());
    dmd_settings_t effective = stored; dmd_timing_apply_settings(&effective); assert(effective.brightness == 33);
    run("disabled", true); assert(strstr(output, "session_not_enabled"));
    command("\"op\":\"begin\",\"session\":\"../bad\""); assert(strstr(output, "invalid_session"));
    command("\"op\":\"begin\",\"session\":\"run\""); assert(s_enabled);
    command("\"op\":\"begin\",\"session\":\"other\""); assert(strstr(output, "session_busy"));
    effective = stored; dmd_timing_apply_settings(&effective);
    assert(effective.brightness == 100 && effective.glow_strength == 50 && !effective.automatic_cycle && stored.brightness == 33);
    fail_allocation = true; run("allocation", true); assert(strstr(output, "capture_buffer_unavailable") && !s_active);
    fail_allocation = false; simulate_timeout = true; run("timeout", true);
    assert(strstr(output, "capture_incomplete") && s_samples == NULL && !s_active);
    simulate_timeout = false; missing_paint = true; run("missing-paint", true); assert(strstr(output, "capture_incomplete"));
    missing_paint = false;
    overflow_steps = true; run("overflow", true); assert(strstr(output, "capture_incomplete") && s_samples == NULL);
    overflow_steps = false; interrupted_steps = true; run("interrupted", true); assert(strstr(output, "capture_incomplete"));
    interrupted_steps = false;
    _mkdir("scenes"); FILE *scene = fopen("scenes/test.scn", "wb"); assert(scene); fputs("data", scene); fclose(scene);
    fail_sync = true; run("retry", true); assert(strstr(output, "log_commit_failed"));
    command("\"op\":\"get\",\"session\":\"run\",\"stage\":\"main\",\"caseId\":\"retry\",\"repeat\":0");
    assert(strstr(output, "\"found\":false"));
    fail_sync = false; run("retry", true); assert(strstr(output, "\"ok\":true") && !strstr(output, "error"));
    int count = plays; run("retry", true); assert(plays == count && strstr(output, "cached"));
    command("\"op\":\"get\",\"session\":\"run\",\"stage\":\"main\",\"caseId\":\"retry\",\"repeat\":0");
    assert(strstr(output, "\"found\":true") && strstr(output, "\"type\":\"record\""));
    run("summary", false); assert(strstr(output, "\"ok\":true"));
    command("\"op\":\"end\",\"session\":\"run\""); assert(!s_enabled && stored.brightness == 33 && stored.automatic_cycle);
    command("\"op\":\"begin\",\"session\":\"run\"");
    simulated_us += 181000000; effective = stored; dmd_timing_apply_settings(&effective);
    assert(!s_enabled && effective.brightness == 33);
    puts("[PASS] Production capture: disabled default, runtime-only settings, session ownership, buffer failure, timeout, missing paint, SD failure/retry, committed cache, export, cleanup, and orphan lease.");
    return 0;
}
