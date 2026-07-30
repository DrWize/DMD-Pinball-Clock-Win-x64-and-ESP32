#include "dmd_diagnostics.h"

#include <string.h>
#include <sys/stat.h>

#include "dmd_settings.h"
#include "dmd_storage.h"
#include "esp_flash.h"
#include "esp_heap_caps.h"
#include "esp_log.h"
#include "esp_system.h"
#include "esp_vfs_fat.h"
#include "esp_wifi.h"
#include "nvs.h"
#include "sdkconfig.h"

#if !CONFIG_DMD_QEMU
#include "driver/temperature_sensor.h"
#endif

#define SETTINGS_PATH DMD_STORAGE_CONFIG "/settings.json"

static const char *TAG = "dmd_diagnostics";
static uint32_t s_boot_count;
#if !CONFIG_DMD_QEMU
static temperature_sensor_handle_t s_temperature_sensor;
#endif

static const char *reset_reason_name(esp_reset_reason_t reason)
{
    switch (reason) {
    case ESP_RST_POWERON: return "Power on";
    case ESP_RST_EXT: return "External reset";
    case ESP_RST_SW: return "Software restart";
    case ESP_RST_PANIC: return "Firmware panic";
    case ESP_RST_INT_WDT: return "Interrupt watchdog";
    case ESP_RST_TASK_WDT: return "Task watchdog";
    case ESP_RST_WDT: return "Watchdog";
    case ESP_RST_DEEPSLEEP: return "Deep sleep";
    case ESP_RST_BROWNOUT: return "Brownout";
    case ESP_RST_SDIO: return "SDIO";
    case ESP_RST_USB: return "USB";
    case ESP_RST_JTAG: return "JTAG";
    case ESP_RST_EFUSE: return "eFuse";
    case ESP_RST_PWR_GLITCH: return "Power glitch";
    case ESP_RST_CPU_LOCKUP: return "CPU lockup";
    default: return "Unknown";
    }
}

static void increment_boot_count(void)
{
    nvs_handle_t handle;
    esp_err_t error = nvs_open("dmdclock", NVS_READWRITE, &handle);
    if (error != ESP_OK) {
        ESP_LOGW(TAG, "Boot counter unavailable: %s", esp_err_to_name(error));
        return;
    }
    nvs_get_u32(handle, "boot_count", &s_boot_count);
    s_boot_count++;
    error = nvs_set_u32(handle, "boot_count", s_boot_count);
    if (error == ESP_OK) {
        error = nvs_commit(handle);
    }
    nvs_close(handle);
    if (error != ESP_OK) {
        ESP_LOGW(TAG, "Boot counter could not be saved: %s", esp_err_to_name(error));
    }
}

esp_err_t dmd_diagnostics_init(void)
{
    increment_boot_count();
#if !CONFIG_DMD_QEMU
    temperature_sensor_config_t config =
        TEMPERATURE_SENSOR_CONFIG_DEFAULT(-10, 80);
    esp_err_t error =
        temperature_sensor_install(&config, &s_temperature_sensor);
    if (error == ESP_OK) {
        error = temperature_sensor_enable(s_temperature_sensor);
    }
    if (error != ESP_OK) {
        ESP_LOGW(
            TAG,
            "Internal temperature sensor unavailable: %s",
            esp_err_to_name(error));
        s_temperature_sensor = NULL;
    }
#endif
    return ESP_OK;
}

void dmd_diagnostics_get(dmd_diagnostics_t *diagnostics)
{
    if (diagnostics == NULL) {
        return;
    }
    memset(diagnostics, 0, sizeof(*diagnostics));
#if !CONFIG_DMD_QEMU
    if (s_temperature_sensor != NULL &&
        temperature_sensor_get_celsius(
            s_temperature_sensor,
            &diagnostics->chip_temperature_c) == ESP_OK) {
        diagnostics->chip_temperature_available = true;
    }
#endif

    wifi_ap_record_t access_point = {0};
    if (esp_wifi_sta_get_ap_info(&access_point) == ESP_OK) {
        diagnostics->wifi_rssi_available = true;
        diagnostics->wifi_rssi_dbm = access_point.rssi;
    }
    diagnostics->free_heap_bytes = esp_get_free_heap_size();
    diagnostics->minimum_free_heap_bytes =
        esp_get_minimum_free_heap_size();
    diagnostics->total_psram_bytes =
        heap_caps_get_total_size(MALLOC_CAP_SPIRAM);
    diagnostics->free_psram_bytes =
        heap_caps_get_free_size(MALLOC_CAP_SPIRAM);
    diagnostics->sd_available = dmd_storage_available();
    if (diagnostics->sd_available) {
        esp_vfs_fat_info(
            "/sd",
            &diagnostics->sd_total_bytes,
            &diagnostics->sd_free_bytes);
        struct stat settings_file;
        diagnostics->settings_file_present =
            stat(SETTINGS_PATH, &settings_file) == 0 &&
            settings_file.st_size > 0;
    }
    esp_flash_get_size(NULL, &diagnostics->flash_size_bytes);
    diagnostics->cpu_frequency_mhz = CONFIG_ESP_DEFAULT_CPU_FREQ_MHZ;
    diagnostics->boot_count = s_boot_count;
    diagnostics->reset_reason = reset_reason_name(esp_reset_reason());
    diagnostics->last_nvs_save_error =
        dmd_settings_last_nvs_save_error();
    diagnostics->last_sd_save_error =
        dmd_settings_last_sd_save_error();
}
