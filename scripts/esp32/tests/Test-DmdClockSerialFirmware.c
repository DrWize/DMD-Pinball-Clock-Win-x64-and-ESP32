#include <assert.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <stdint.h>
#include <setjmp.h>
#include <fcntl.h>
#include <unistd.h>
#ifndef O_NONBLOCK
#define O_NONBLOCK 0x4000
#endif

static char output[4096];
static const char *streams[2] = {"", ""};
static size_t positions[2];
static bool missing_usb;
static bool usb_driver_installed, usb_driver_vfs;
static int ticks;
static bool uart_installed;
static jmp_buf stop_task;
static int transport_read(int n, void *buf, size_t count)
{
    // IDF 5.5.2 VFS counts only bytes in the installed USB driver's RX ring.
    if (n == 1 && (!usb_driver_installed || !usb_driver_vfs)) return 0;
    size_t size = strlen(streams[n]) - positions[n];
    if (size > count) size = count;
    memcpy(buf, streams[n] + positions[n], size);
    positions[n] += size;
    return (int)size;
}
static int fake_printf(const char *format, ...)
{
    va_list args;
    va_start(args, format);
    int count = vsnprintf(output + strlen(output), sizeof(output) - strlen(output), format, args);
    va_end(args);
    return count;
}
static size_t fake_strlcpy(char *dst, const char *src, size_t size)
{
    size_t len = strlen(src);
    if (size) { size_t take = len < size - 1 ? len : size - 1; memcpy(dst, src, take); dst[take] = 0; }
    return len;
}
#define printf fake_printf
#define strlcpy fake_strlcpy
#include "../../../firmware/dmdclock-esp32/main/dmd_serial.c"
#undef printf
bool dmd_timing_handle_line(char *line) { return false; }
static int last_write_transport = -1;
int uart_write_bytes(int port, const void *data, size_t size)
{
    last_write_transport = 0;
    assert(size > 0 && !memcmp(data, "\nDMDTIMING:", 11));
    return (int)size;
}
int usb_serial_jtag_write_bytes(const void *data, size_t size, int timeout)
{
    last_write_transport = 1;
    assert(timeout == 5000 && size > 0 && !memcmp(data, "\nDMDTIMING:", 11));
    return (int)size;
}
#include "driver/usb_serial_jtag.h"

bool usb_serial_jtag_is_driver_installed(void) { return usb_driver_installed; }
esp_err_t usb_serial_jtag_driver_install(usb_serial_jtag_driver_config_t *config)
{
    assert(config->rx_buffer_size >= LINE_BYTES && config->tx_buffer_size > 0);
    if (missing_usb) return ESP_ERR_NO_MEM;
    usb_driver_installed = true;
    return ESP_OK;
}
esp_err_t usb_serial_jtag_driver_uninstall(void) { usb_driver_installed = false; return ESP_OK; }
void usb_serial_jtag_vfs_use_driver(void) { assert(usb_driver_installed); usb_driver_vfs = true; }
void usb_serial_jtag_vfs_use_nonblocking(void) { usb_driver_vfs = false; }
int usb_serial_jtag_read_bytes(void *buf, uint32_t len, int timeout)
{
    assert(timeout == 0);
    return transport_read(1, buf, len);
}
bool uart_is_driver_installed(int port) { return uart_installed; }
esp_err_t uart_driver_install(int port, int rx, int tx, int queue, void *handle, int flags)
{
    assert(rx >= LINE_BYTES);
    uart_installed = true;
    return ESP_OK;
}
esp_err_t uart_driver_delete(int port) { uart_installed = false; return ESP_OK; }
void uart_vfs_dev_use_driver(int port) {}
void uart_vfs_dev_use_nonblocking(int port) {}
int uart_read_bytes(int port, void *buf, uint32_t len, int timeout)
{
    assert(timeout == 0 && uart_installed);
    return transport_read(0, buf, len);
}

static dmd_settings_t settings;
static int saves, applies;
static bool fail_save;
static const esp_app_desc_t app = {.version = "firmware-test"};
const esp_app_desc_t *esp_app_get_description(void) { return &app; }
esp_err_t esp_read_mac(uint8_t *mac, int kind) { for (int i = 0; i < 6; i++) mac[i] = (uint8_t)(i + 1); return ESP_OK; }
int64_t esp_timer_get_time(void) { return ticks * 1000; }
esp_err_t esp_wifi_sta_get_ap_info(wifi_ap_record_t *ap) { memset(ap, 0, sizeof(*ap)); memcpy(ap->ssid, "home", 4); return ESP_OK; }
void dmd_network_get_info(dmd_network_info_t *info) { memset(info, 0, sizeof(*info)); info->station_connected = true; strcpy(info->station_ip, "192.168.1.150"); }
void dmd_settings_begin_update(void) {}
void dmd_settings_end_update(void) {}
void dmd_settings_get(dmd_settings_t *out) { *out = settings; }
esp_err_t dmd_settings_update(const dmd_settings_t *value) { saves++; settings = *value; return fail_save ? ESP_ERR_NO_MEM : ESP_OK; }
esp_err_t dmd_settings_last_nvs_save_error(void) { return fail_save ? ESP_ERR_NO_MEM : ESP_OK; }
esp_err_t dmd_settings_last_sd_save_error(void) { return ESP_OK; }
esp_err_t dmd_network_apply_credentials(const char *ssid, const char *password) { applies++; assert(!strcmp(ssid, "home")); return ESP_OK; }
int xTaskCreate(void (*task)(void *), const char *name, unsigned stack, void *arg, unsigned priority, void *handle) { return pdPASS; }
void vTaskDelay(int delay) { if (++ticks > 100) longjmp(stop_task, 1); }

static void command(const char *text)
{
    char line[2048];
    assert(strlen(text) < sizeof(line));
    strcpy(line, text); output[0] = 0;
    handle_line(line);
}
int main(void)
{
    assert(dmd_serial_init() == ESP_OK);
    // Exercise the production read loop, not just the JSON handler.
    streams[1] = "DMDWIFI:{\"id\":\"usb\",\"protocol\":1,\"op\":\"hello\"}\n";
    if (!setjmp(stop_task)) serial_task(NULL);
    assert(strstr(output, "\"id\":\"usb\"") && strstr(output, "firmware-test"));

    command("DMDWIFI:{\"id\":\"bad\",\"protocol\":99,\"op\":\"hello\"}");
    assert(strstr(output, "unsupported_protocol"));
    command("DMDWIFI:{broken}"); assert(!output[0]);
    command("DMDWIFI:{\"id\":\"nul\",\"protocol\":1,\"op\":\"setWifi\",\"password\":\"a\\u0000b\"}"); assert(!output[0]);
    command("DMDWIFI:{\"id\":\"bad\",\"protocol\":1,\"op\":\"setWifi\",\"mac\":\"wrong\",\"ssid\":\"home\",\"password\":\"secret\"}");
    assert(strstr(output, "identity_mismatch") && saves == 0);
    command("DMDWIFI:{\"id\":\"bad\",\"protocol\":1,\"op\":\"setWifi\",\"mac\":\"01:02:03:04:05:06\",\"ssid\":\"home\"}");
    assert(strstr(output, "invalid_credentials") && saves == 0);

    const char *set = "DMDWIFI:{\"id\":\"set\",\"protocol\":1,\"op\":\"setWifi\",\"mac\":\"01:02:03:04:05:06\",\"ssid\":\"home\",\"password\":\"secret\"}";
    settings.brightness = 42;
    command(set);
    assert(strstr(output, "\"ok\":true") && !strstr(output, "secret"));
    assert(saves == 1 && applies == 1 && settings.brightness == 42 && !strcmp(settings.wifi_password, "secret"));
    fail_save = true;
    command(set); assert(strstr(output, "save_failed") && applies == 1);

    dmd_serial_diagnostics_t diagnostics;
    s_reply_transport = 0; assert(dmd_serial_timing_reply("{\"test\":true}") && last_write_transport == 0);
    s_reply_transport = 1; assert(dmd_serial_timing_reply("{\"test\":true}") && last_write_transport == 1);
    dmd_serial_get_diagnostics(&diagnostics);
    assert(diagnostics.running && diagnostics.polls > 1 && diagnostics.usb_rx_bytes > 0);
    missing_usb = true; usb_driver_installed = false;
    assert(dmd_serial_init() == ESP_ERR_NO_MEM);
    puts("[PASS] Production zero-timeout driver input, diagnostics, protocol validation, identity, preservation, save failure, secret redaction, and driver-init failure.");
    return 0;
}
