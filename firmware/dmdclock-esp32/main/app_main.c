#include "dmd_board.h"
#include "dmd_display.h"
#include "dmd_diagnostics.h"
#include "dmd_network.h"
#include "dmd_scene.h"
#include "dmd_settings.h"
#include "dmd_storage.h"
#include "dmd_web.h"

#include "esp_check.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "nvs_flash.h"

static const char *TAG = "dmdclock";

void app_main(void)
{
    esp_err_t error = nvs_flash_init();
    if (error == ESP_ERR_NVS_NO_FREE_PAGES ||
        error == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        error = nvs_flash_init();
    }
    ESP_ERROR_CHECK(error);

    ESP_ERROR_CHECK(dmd_board_init());
    ESP_ERROR_CHECK(dmd_storage_init());
    ESP_ERROR_CHECK(dmd_scene_init());
    ESP_ERROR_CHECK(dmd_settings_init());
    ESP_ERROR_CHECK(dmd_diagnostics_init());
    dmd_settings_t settings;
    dmd_settings_get(&settings);
    if (settings.scene_index >= dmd_scene_count()) {
        settings.scene_index = 0;
        ESP_ERROR_CHECK(dmd_settings_update(&settings));
    }
    if (dmd_scene_count() > 0) {
        ESP_ERROR_CHECK(dmd_scene_select(settings.scene_index));
    }
    ESP_ERROR_CHECK(dmd_display_init());
    ESP_ERROR_CHECK(dmd_network_init());
    ESP_ERROR_CHECK(dmd_web_start());

    BaseType_t created = xTaskCreatePinnedToCore(
        dmd_display_task,
        "dmd_display",
        4096,
        NULL,
        5,
        NULL,
        1);
    ESP_ERROR_CHECK(created == pdPASS ? ESP_OK : ESP_ERR_NO_MEM);

    ESP_LOGI(TAG, "DMDClock ready: connect to the displayed DMDClock Wi-Fi network");
}
