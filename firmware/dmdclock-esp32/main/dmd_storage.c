#include "dmd_storage.h"

#include "dmd_board.h"
#include "esp_log.h"
#include "sdkconfig.h"

static const char *TAG = "dmd_storage";
static bool s_available;

#if CONFIG_DMD_QEMU

esp_err_t dmd_storage_init(void)
{
    ESP_LOGI(TAG, "TF storage unavailable in QEMU; using embedded test scenes");
    return ESP_OK;
}

#else

#include <sys/stat.h>

#include "driver/spi_common.h"
#include "esp_vfs_fat.h"
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

    const esp_vfs_fat_sdmmc_mount_config_t mount_config = {
        .format_if_mount_failed = false,
        .max_files = 5,
        .allocation_unit_size = 16 * 1024,
    };
    sdspi_device_config_t slot_config = SDSPI_DEVICE_CONFIG_DEFAULT();
    slot_config.gpio_cs = GPIO_NUM_NC;
    slot_config.host_id = host.slot;
    sdmmc_card_t *card = NULL;
    error = esp_vfs_fat_sdspi_mount(
        "/sd",
        &host,
        &slot_config,
        &mount_config,
        &card);
    if (error != ESP_OK) {
        ESP_LOGW(
            TAG,
            "TF card unavailable; internal fallback remains active: %s",
            esp_err_to_name(error));
        dmd_board_set_sd_enabled(false);
        spi_bus_free(host.slot);
        return ESP_OK;
    }

    mkdir(DMD_STORAGE_ROOT, 0755);
    mkdir(DMD_STORAGE_SCENES, 0755);
    mkdir(DMD_STORAGE_PLASMA, 0755);
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
