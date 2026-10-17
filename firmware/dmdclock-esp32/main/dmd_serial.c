#include "dmd_serial.h"

#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "cJSON.h"
#include "sdkconfig.h"
#if !CONFIG_DMD_QEMU
#include "driver/usb_serial_jtag.h"
#include "driver/usb_serial_jtag_vfs.h"
#include "driver/uart.h"
#include "driver/uart_vfs.h"
#endif
#include "dmd_network.h"
#include "dmd_settings.h"
#include "dmd_timing.h"
#include "esp_app_desc.h"
#include "esp_mac.h"
#include "esp_timer.h"
#include "esp_wifi.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "sdkconfig.h"

static volatile dmd_serial_diagnostics_t s_diag;
#if !CONFIG_DMD_QEMU
static unsigned s_reply_transport;
#endif

bool dmd_serial_timing_reply(const char *json)
{
#if CONFIG_DMD_QEMU
    (void)json;
    return false;
#else
    size_t length = strlen(json) + 12;
    if (length > 4096) return false;
    char *packet = malloc(length + 1);
    if (packet == NULL) return false;
    int bytes = snprintf(packet, length + 1, "\nDMDTIMING:%s\n", json);
    int sent = s_reply_transport == 0
        ? uart_write_bytes(UART_NUM_0, packet, bytes)
        : usb_serial_jtag_write_bytes(packet, bytes, pdMS_TO_TICKS(5000));
    free(packet);
    return sent == bytes;
#endif
}

void dmd_serial_get_diagnostics(dmd_serial_diagnostics_t *out)
{
    if (out != NULL) *out = s_diag;
}

#if !CONFIG_DMD_QEMU
#define LINE_BYTES 1024
typedef struct {
    size_t used;
    bool discard;
    int64_t last_byte;
    char line[LINE_BYTES];
} serial_input_t;

static serial_input_t s_inputs[2];

static const char *board_name(void)
{
#if CONFIG_DMD_BOARD_3_49_LANDSCAPE
    return "Waveshare349B";
#else
    return "Waveshare7";
#endif
}

static void reply(cJSON *json)
{
    if (json == NULL) return;
    char *text = cJSON_PrintUnformatted(json);
    if (text != NULL) {
        // One stdio write prevents other stdio log lines splitting the reply.
        printf("\nDMDWIFI:%s\n", text);
        fflush(stdout);
        free(text);
    }
    cJSON_Delete(json);
}

static void handle_line(char *line)
{
    if (dmd_timing_handle_line(line)) return;
    if (strncmp(line, "DMDWIFI:", 8) != 0) return;
    s_diag.requests++;
    // cJSON strings cannot represent embedded NULs; reject before decoding.
    if (strstr(line, "\\u0000") != NULL) return;
    cJSON *request = cJSON_ParseWithOpts(line + 8, NULL, true);
    if (!cJSON_IsObject(request)) { cJSON_Delete(request); return; }
    cJSON *id = cJSON_GetObjectItemCaseSensitive(request, "id");
    cJSON *op = cJSON_GetObjectItemCaseSensitive(request, "op");
    cJSON *version = cJSON_GetObjectItemCaseSensitive(request, "protocol");
    if (!cJSON_IsString(id) || strlen(id->valuestring) > 64 ||
        !cJSON_IsString(op)) { cJSON_Delete(request); return; }
    cJSON *out = cJSON_CreateObject();
    if (out == NULL) { cJSON_Delete(request); return; }
    cJSON_AddNumberToObject(out, "protocol", 1);
    cJSON_AddStringToObject(out, "id", id->valuestring);
    const char *error = NULL;
    if (!cJSON_IsNumber(version) || version->valuedouble != 1) {
        error = "unsupported_protocol";
    } else if (strcmp(op->valuestring, "hello") == 0 ||
               strcmp(op->valuestring, "status") == 0) {
        uint8_t mac[6];
        if (esp_read_mac(mac, ESP_MAC_WIFI_STA) != ESP_OK) {
            error = "identity_unavailable";
        } else {
            char mac_text[18];
            snprintf(mac_text, sizeof(mac_text), "%02x:%02x:%02x:%02x:%02x:%02x",
                mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
            dmd_network_info_t network;
            dmd_network_get_info(&network);
            wifi_ap_record_t ap;
            bool associated = esp_wifi_sta_get_ap_info(&ap) == ESP_OK;
            char connected_ssid[33] = "";
            if (associated) memcpy(connected_ssid, ap.ssid, 32);
            cJSON_AddStringToObject(out, "board", board_name());
            cJSON_AddStringToObject(out, "mac", mac_text);
            cJSON_AddStringToObject(out, "firmware", esp_app_get_description()->version);
            cJSON_AddBoolToObject(out, "connected", network.station_connected && associated);
            cJSON_AddStringToObject(out, "ssid", connected_ssid);
            cJSON_AddStringToObject(out, "ip", network.station_ip);
            cJSON_AddBoolToObject(out, "ntpSynced", network.ntp_synced);
        }
    } else if (strcmp(op->valuestring, "setWifi") == 0) {
        cJSON *ssid = cJSON_GetObjectItemCaseSensitive(request, "ssid");
        cJSON *password = cJSON_GetObjectItemCaseSensitive(request, "password");
        cJSON *target = cJSON_GetObjectItemCaseSensitive(request, "mac");
        uint8_t mac[6];
        char mac_text[18] = "";
        if (esp_read_mac(mac, ESP_MAC_WIFI_STA) == ESP_OK) {
            snprintf(mac_text, sizeof(mac_text), "%02x:%02x:%02x:%02x:%02x:%02x",
                mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
        }
        if (!cJSON_IsString(target) || mac_text[0] == 0 ||
            strcmp(target->valuestring, mac_text) != 0) {
            error = "identity_mismatch";
        } else if (!cJSON_IsString(ssid) || !cJSON_IsString(password) ||
            strlen(ssid->valuestring) == 0 || strlen(ssid->valuestring) > DMD_WIFI_SSID_MAX ||
            strlen(password->valuestring) > DMD_WIFI_PASSWORD_MAX) {
            error = "invalid_credentials";
        } else {
            dmd_settings_begin_update();
            dmd_settings_t settings;
            dmd_settings_get(&settings);
            strlcpy(settings.wifi_ssid, ssid->valuestring, sizeof(settings.wifi_ssid));
            strlcpy(settings.wifi_password, password->valuestring, sizeof(settings.wifi_password));
            esp_err_t saved = dmd_settings_update(&settings);
            cJSON_AddBoolToObject(out, "nvsSaved", dmd_settings_last_nvs_save_error() == ESP_OK);
            cJSON_AddBoolToObject(out, "sdSaved", dmd_settings_last_sd_save_error() == ESP_OK);
            if (saved != ESP_OK) {
                error = "save_failed";
            } else if (dmd_network_apply_credentials(settings.wifi_ssid, settings.wifi_password) != ESP_OK) {
                error = "connect_failed";
            }
            memset(settings.wifi_password, 0, sizeof(settings.wifi_password));
            dmd_settings_end_update();
        }
    } else {
        error = "unsupported_operation";
    }
    cJSON_AddBoolToObject(out, "ok", error == NULL);
    if (error != NULL) cJSON_AddStringToObject(out, "error", error);
    cJSON *password = cJSON_GetObjectItemCaseSensitive(request, "password");
    if (cJSON_IsString(password)) memset(password->valuestring, 0, strlen(password->valuestring));
    cJSON_Delete(request);
    reply(out);
}

static void serial_task(void *argument)
{
    (void)argument;
    for (;;) {
        s_diag.running = true;
        s_diag.polls++;
        for (size_t n = 0; n < 2; n++) {
            serial_input_t *input = &s_inputs[n];
            int64_t now = esp_timer_get_time();
            if (input->used && now - input->last_byte > 5000000) {
                memset(input->line, 0, sizeof(input->line));
                input->used = 0;
                input->discard = true;
            }
            unsigned char bytes[64];
            int count = n == 0
                ? uart_read_bytes(UART_NUM_0, bytes, sizeof(bytes), 0)
                : usb_serial_jtag_read_bytes(bytes, sizeof(bytes), 0);
            if (count > 0) {
                if (n == 0) s_diag.uart_rx_bytes += count;
                else s_diag.usb_rx_bytes += count;
            }
            for (ssize_t i = 0; i < count; i++) {
                input->last_byte = now;
                if (bytes[i] == '\r') continue;
                if (bytes[i] == '\n') {
                    if (!input->discard) {
                        input->line[input->used] = 0;
                        s_reply_transport = n;
                        handle_line(input->line);
                    }
                    memset(input->line, 0, sizeof(input->line));
                    input->used = 0;
                    input->discard = false;
                } else if (!input->discard) {
                    if (bytes[i] == 0 || input->used >= sizeof(input->line) - 1) {
                        input->discard = true;
                        memset(input->line, 0, sizeof(input->line));
                        input->used = 0;
                    } else {
                        input->line[input->used++] = bytes[i];
                    }
                }
            }
        }
        vTaskDelay(pdMS_TO_TICKS(1));
    }
}

#endif

esp_err_t dmd_serial_init(void)
{
#if CONFIG_DMD_QEMU
    return ESP_OK;
#else
    // IDF 5.5.2's USB VFS availability check reads the driver's RX ring,
    // even for a nonblocking VFS handle. Without this driver it returns zero
    // forever and the hardware RX FIFO eventually stalls Windows writes.
    bool installed_here = !usb_serial_jtag_is_driver_installed();
    if (installed_here) {
        usb_serial_jtag_driver_config_t config = {
            .tx_buffer_size = 8192,
            .rx_buffer_size = 2048,
        };
        esp_err_t error = usb_serial_jtag_driver_install(&config);
        if (error != ESP_OK) return error;
    }
    usb_serial_jtag_vfs_use_driver();
    // Use driver reads with explicit zero timeouts. Console VFS flags and
    // stdio initialization must never block UART polling ahead of USB input.
    bool uart_installed_here = !uart_is_driver_installed(UART_NUM_0);
    esp_err_t uart_error = ESP_OK;
    if (uart_installed_here) uart_error = uart_driver_install(UART_NUM_0, 2048, 0, 0, NULL, 0);
    if (uart_error != ESP_OK) {
        if (installed_here) {
            usb_serial_jtag_vfs_use_nonblocking();
            usb_serial_jtag_driver_uninstall();
        }
        return uart_error;
    }
    uart_vfs_dev_use_driver(UART_NUM_0);
    if (xTaskCreate(serial_task, "dmd_serial", 8192, NULL, 3, NULL) != pdPASS) {
        if (uart_installed_here) {
            uart_vfs_dev_use_nonblocking(UART_NUM_0);
            uart_driver_delete(UART_NUM_0);
        }
        if (installed_here) {
            usb_serial_jtag_vfs_use_nonblocking();
            usb_serial_jtag_driver_uninstall();
        }
        return ESP_ERR_NO_MEM;
    }
    return ESP_OK;
#endif
}
