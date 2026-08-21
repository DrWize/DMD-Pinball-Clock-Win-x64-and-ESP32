#include "dmd_storage.h"

#include "dmd_board.h"
#include "esp_log.h"
#include "sdkconfig.h"

static const char *TAG = "dmd_storage";
static bool s_available;

#if CONFIG_DMD_QEMU

#include <sys/stat.h>

#include "driver/sdmmc_host.h"
#include "driver/sdmmc_types.h"
#include "esp_vfs_fat.h"
#include "sdmmc_cmd.h"

esp_err_t dmd_storage_init(void)
{
    sdmmc_host_t host = SDMMC_HOST_DEFAULT();
    host.slot = SDMMC_HOST_SLOT_0;
    sdmmc_slot_config_t slot = SDMMC_SLOT_CONFIG_DEFAULT();
    const esp_vfs_fat_mount_config_t mount_config = {
        .format_if_mount_failed = false,
        .max_files = 5,
        .allocation_unit_size = 16 * 1024,
    };
    sdmmc_card_t *card = NULL;
    esp_err_t error = esp_vfs_fat_sdmmc_mount(
        "/sd",
        &host,
        &slot,
        &mount_config,
        &card);
    if (error != ESP_OK) {
        ESP_LOGW(
            TAG,
            "QEMU SD card unavailable; embedded test scenes remain active: %s",
            esp_err_to_name(error));
        return ESP_OK;
    }

    mkdir(DMD_STORAGE_ROOT, 0755);
    mkdir(DMD_STORAGE_SCENES, 0755);
    mkdir(DMD_STORAGE_FONTS, 0755);
    mkdir(DMD_STORAGE_PLASMA, 0755);
    mkdir(DMD_STORAGE_CONFIG, 0755);
    mkdir(DMD_STORAGE_LOGS, 0755);
    s_available = true;
    ESP_LOGI(
        TAG,
        "QEMU SD card mounted at /sd; DMDClock content root is %s",
        DMD_STORAGE_ROOT);
    return ESP_OK;
}

#elif CONFIG_DMD_BOARD_3_49_LANDSCAPE

#include <sys/stat.h>

#include "driver/gpio.h"
#include "driver/sdmmc_host.h"
#include "esp_vfs_fat.h"
#include "sdmmc_cmd.h"

#define SDMMC_CMD GPIO_NUM_39
#define SDMMC_D0 GPIO_NUM_40
#define SDMMC_CLK GPIO_NUM_41

esp_err_t dmd_storage_init(void)
{
    sdmmc_host_t host = SDMMC_HOST_DEFAULT();
    host.max_freq_khz = SDMMC_FREQ_HIGHSPEED;
    sdmmc_slot_config_t slot = SDMMC_SLOT_CONFIG_DEFAULT();
    slot.width = 1;
    slot.cmd = SDMMC_CMD;
    slot.d0 = SDMMC_D0;
    slot.clk = SDMMC_CLK;
    const esp_vfs_fat_mount_config_t mount_config = {
        .format_if_mount_failed = false,
        .max_files = 5,
        .allocation_unit_size = 16 * 1024,
    };
    sdmmc_card_t *card = NULL;
    esp_err_t error = esp_vfs_fat_sdmmc_mount(
        "/sd",
        &host,
        &slot,
        &mount_config,
        &card);
    if (error != ESP_OK) {
        ESP_LOGW(
            TAG,
            "3.49B TF card unavailable; clock-only mode remains active: %s",
            esp_err_to_name(error));
        return ESP_OK;
    }

    mkdir(DMD_STORAGE_ROOT, 0755);
    mkdir(DMD_STORAGE_SCENES, 0755);
    mkdir(DMD_STORAGE_FONTS, 0755);
    mkdir(DMD_STORAGE_PLASMA, 0755);
    mkdir(DMD_STORAGE_CONFIG, 0755);
    mkdir(DMD_STORAGE_LOGS, 0755);
    s_available = true;
    ESP_LOGI(
        TAG,
        "3.49B TF card mounted at /sd in native 1-bit SDMMC mode; content root is %s",
        DMD_STORAGE_ROOT);
    return ESP_OK;
}

#else

#include <sys/stat.h>

#include "driver/spi_common.h"
#include "esp_vfs_fat.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "sdmmc_cmd.h"

#define SD_MOSI GPIO_NUM_11
#define SD_SCLK GPIO_NUM_12
#define SD_MISO GPIO_NUM_13

esp_err_t dmd_storage_init(void)
{
    const spi_bus_config_t bus_config = {
        .mosi_io_num = SD_MOSI,
        .miso_io_num = SD_MISO,
        .sclk_io_num = SD_SCLK,
        .quadwp_io_num = GPIO_NUM_NC,
        .quadhd_io_num = GPIO_NUM_NC,
        .max_transfer_sz = 16 * 1024,
    };
    sdmmc_host_t host = SDSPI_HOST_DEFAULT();
    esp_err_t error = spi_bus_initialize(host.slot, &bus_config, SPI_DMA_CH_AUTO);
    if (error != ESP_OK) {
        ESP_LOGW(TAG, "TF SPI bus unavailable: %s", esp_err_to_name(error));
        return ESP_OK;
    }

    error = dmd_board_set_sd_enabled(true);
    if (error != ESP_OK) {
        ESP_LOGW(TAG, "TF enable failed: %s", esp_err_to_name(error));
        spi_bus_free(host.slot);
        return ESP_OK;
    }
    vTaskDelay(pdMS_TO_TICKS(150));

    const esp_vfs_fat_sdmmc_mount_config_t mount_config = {
        .format_if_mount_failed = false,
        .max_files = 5,
        .allocation_unit_size = 16 * 1024,
    };
    sdspi_device_config_t slot_config = SDSPI_DEVICE_CONFIG_DEFAULT();
    slot_config.gpio_cs = GPIO_NUM_NC;
    slot_config.host_id = host.slot;
    sdmmc_card_t *card = NULL;
    for (uint8_t attempt = 1; attempt <= 3; attempt++) {
        error = esp_vfs_fat_sdspi_mount(
            "/sd",
            &host,
            &slot_config,
            &mount_config,
            &card);
        if (error == ESP_OK) {
            break;
        }
        ESP_LOGW(
            TAG,
            "TF mount attempt %u failed: %s",
            attempt,
            esp_err_to_name(error));
        if (attempt < 3) {
            dmd_board_set_sd_enabled(false);
            vTaskDelay(pdMS_TO_TICKS(100));
            error = dmd_board_set_sd_enabled(true);
            if (error != ESP_OK) {
                ESP_LOGW(
                    TAG,
                    "TF re-enable failed: %s",
                    esp_err_to_name(error));
                break;
            }
            vTaskDelay(pdMS_TO_TICKS(250));
        }
    }
    if (error != ESP_OK) {
        ESP_LOGW(
            TAG,
            "TF card unavailable; clock-only mode remains active: %s",
            esp_err_to_name(error));
        dmd_board_set_sd_enabled(false);
        spi_bus_free(host.slot);
        return ESP_OK;
    }

    mkdir(DMD_STORAGE_ROOT, 0755);
    mkdir(DMD_STORAGE_SCENES, 0755);
    mkdir(DMD_STORAGE_FONTS, 0755);
    mkdir(DMD_STORAGE_PLASMA, 0755);
    mkdir(DMD_STORAGE_CONFIG, 0755);
    mkdir(DMD_STORAGE_LOGS, 0755);
    s_available = true;
    ESP_LOGI(
        TAG,
        "TF card mounted at /sd; DMDClock content root is %s",
        DMD_STORAGE_ROOT);
    return ESP_OK;
}

#endif

bool dmd_storage_available(void)
{
    return s_available;
}
