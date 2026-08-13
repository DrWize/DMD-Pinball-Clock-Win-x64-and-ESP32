#include "dmd_panel.h"

#include "sdkconfig.h"

#if !CONFIG_DMD_QEMU && CONFIG_DMD_BOARD_WAVESHARE_7

#include <string.h>

#include "dmd_board.h"
#include "dmd_geometry.h"
#include "driver/gpio.h"
#include "esp_check.h"
#include "esp_lcd_panel_ops.h"
#include "esp_lcd_panel_rgb.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#define WAVESHARE7_PIXEL_CLOCK_HZ (16 * 1000 * 1000)

static const char *TAG = "dmd_panel_waveshare7";
static esp_lcd_panel_handle_t s_panel;
static uint16_t *s_framebuffers[2];
static uint8_t s_render_buffer = 1;
static TaskHandle_t s_display_task;

static bool IRAM_ATTR frame_buffer_complete(
    esp_lcd_panel_handle_t panel,
    const esp_lcd_rgb_panel_event_data_t *event,
    void *context)
{
    (void)panel;
    (void)event;
    (void)context;
    TaskHandle_t display_task = s_display_task;
    if (display_task == NULL) {
        return false;
    }
    BaseType_t higher_priority_task_woken = pdFALSE;
    vTaskNotifyGiveFromISR(display_task, &higher_priority_task_woken);
    return higher_priority_task_woken == pdTRUE;
}

esp_err_t dmd_panel_init(void)
{
    ESP_LOGI(TAG, "Initializing %dx%d RGB panel", LCD_WIDTH, LCD_HEIGHT);
    const esp_lcd_rgb_panel_config_t config = {
        .clk_src = LCD_CLK_SRC_DEFAULT,
        .timings = {
            .pclk_hz = WAVESHARE7_PIXEL_CLOCK_HZ,
            .h_res = LCD_WIDTH,
            .v_res = LCD_HEIGHT,
            .hsync_pulse_width = 4,
            .hsync_back_porch = 8,
            .hsync_front_porch = 8,
            .vsync_pulse_width = 4,
            .vsync_back_porch = 8,
            .vsync_front_porch = 8,
            .flags.pclk_active_neg = 1,
        },
        .data_width = 16,
        .bits_per_pixel = 16,
        .num_fbs = 2,
        .bounce_buffer_size_px = LCD_WIDTH * 20,
        .sram_trans_align = 4,
        .psram_trans_align = 64,
        .hsync_gpio_num = GPIO_NUM_46,
        .vsync_gpio_num = GPIO_NUM_3,
        .de_gpio_num = GPIO_NUM_5,
        .pclk_gpio_num = GPIO_NUM_7,
        .disp_gpio_num = GPIO_NUM_NC,
        .data_gpio_nums = {
            GPIO_NUM_14, GPIO_NUM_38, GPIO_NUM_18, GPIO_NUM_17,
            GPIO_NUM_10, GPIO_NUM_39, GPIO_NUM_0, GPIO_NUM_45,
            GPIO_NUM_48, GPIO_NUM_47, GPIO_NUM_21, GPIO_NUM_1,
            GPIO_NUM_2, GPIO_NUM_42, GPIO_NUM_41, GPIO_NUM_40,
        },
        .flags.fb_in_psram = 1,
    };

    ESP_RETURN_ON_ERROR(
        esp_lcd_new_rgb_panel(&config, &s_panel),
        TAG,
        "create panel");
    ESP_RETURN_ON_ERROR(esp_lcd_panel_reset(s_panel), TAG, "reset panel");
    ESP_RETURN_ON_ERROR(esp_lcd_panel_init(s_panel), TAG, "initialize panel");
    const esp_lcd_rgb_panel_event_callbacks_t callbacks = {
        .on_frame_buf_complete = frame_buffer_complete,
    };
    ESP_RETURN_ON_ERROR(
        esp_lcd_rgb_panel_register_event_callbacks(s_panel, &callbacks, NULL),
        TAG,
        "register frame-buffer callback");
    ESP_RETURN_ON_ERROR(
        esp_lcd_rgb_panel_get_frame_buffer(
            s_panel,
            2,
            (void **)&s_framebuffers[0],
            (void **)&s_framebuffers[1]),
        TAG,
        "get framebuffers");
    memset(s_framebuffers[0], 0, LCD_WIDTH * LCD_HEIGHT * sizeof(uint16_t));
    memset(s_framebuffers[1], 0, LCD_WIDTH * LCD_HEIGHT * sizeof(uint16_t));
    s_render_buffer = 1;
    return ESP_OK;
}

int dmd_panel_width(void)
{
    return LCD_WIDTH;
}

int dmd_panel_height(void)
{
    return LCD_HEIGHT;
}

uint16_t *dmd_panel_begin_frame(void)
{
    return s_framebuffers[s_render_buffer];
}

esp_err_t dmd_panel_present(void)
{
    s_display_task = xTaskGetCurrentTaskHandle();
    ulTaskNotifyValueClear(NULL, ULONG_MAX);
    ESP_RETURN_ON_ERROR(
        esp_lcd_panel_draw_bitmap(
            s_panel,
            0,
            0,
            LCD_WIDTH,
            LCD_HEIGHT,
            s_framebuffers[s_render_buffer]),
        TAG,
        "present framebuffer");
    if (ulTaskNotifyTake(pdTRUE, pdMS_TO_TICKS(100)) == 0) {
        ESP_LOGW(TAG, "Timed out waiting for RGB frame-buffer handoff");
    }
    s_render_buffer ^= 1U;
    return ESP_OK;
}

esp_err_t dmd_panel_set_backlight(bool enabled)
{
    return dmd_board_set_backlight(enabled);
}

#endif
