#include "dmd_panel.h"

#include "sdkconfig.h"

#if !CONFIG_DMD_QEMU && CONFIG_DMD_BOARD_3_49_LANDSCAPE

#include <string.h>

#include "dmd_geometry.h"
#include "driver/gpio.h"
#include "driver/i2c_master.h"
#include "driver/spi_master.h"
#include "esp_check.h"
#include "esp_heap_caps.h"
#include "esp_io_expander.h"
#include "esp_io_expander_tca9554.h"
#include "esp_lcd_axs15231b.h"
#include "esp_lcd_panel_io.h"
#include "esp_lcd_panel_ops.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"

#define NATIVE_WIDTH 172
#define NATIVE_HEIGHT 640
#define TRANSFER_ROWS 64

#define LCD_HOST SPI3_HOST
#define LCD_CS GPIO_NUM_9
#define LCD_PCLK GPIO_NUM_10
#define LCD_DATA0 GPIO_NUM_11
#define LCD_DATA1 GPIO_NUM_12
#define LCD_DATA2 GPIO_NUM_13
#define LCD_DATA3 GPIO_NUM_14
#define LCD_PWM GPIO_NUM_42
#define EXPANDER_SCL GPIO_NUM_48
#define EXPANDER_SDA GPIO_NUM_47
#define EXPANDER_BL_EN (1ULL << 1)
#define EXPANDER_LCD_RST (1ULL << 5)

static const char *TAG = "dmd_panel_waveshare349b";
static SemaphoreHandle_t s_transfer_done;
static esp_io_expander_handle_t s_io_expander;
static esp_lcd_panel_handle_t s_panel;
static uint16_t *s_framebuffer;
static uint16_t *s_transfer_buffer;
static bool s_first_frame_logged;

static const axs15231b_lcd_init_cmd_t s_lcd_init_commands[] = {
    {0x11, (uint8_t[]){0x00}, 0, 100},
    {0x29, (uint8_t[]){0x00}, 0, 100},
};

static bool IRAM_ATTR transfer_complete(
    esp_lcd_panel_io_handle_t panel_io,
    esp_lcd_panel_io_event_data_t *event_data,
    void *user_context)
{
    (void)panel_io;
    (void)event_data;
    (void)user_context;
    BaseType_t task_woken = pdFALSE;
    xSemaphoreGiveFromISR(s_transfer_done, &task_woken);
    return task_woken == pdTRUE;
}

static uint16_t swap_pixel_bytes(uint16_t pixel)
{
    return (uint16_t)((pixel << 8) | (pixel >> 8));
}

esp_err_t dmd_panel_init(void)
{
    ESP_LOGI(TAG, "Initializing Waveshare 3.49B V2 panel as %dx%d", LCD_WIDTH, LCD_HEIGHT);
    ESP_RETURN_ON_FALSE(
        LCD_WIDTH == NATIVE_HEIGHT && LCD_HEIGHT == NATIVE_WIDTH,
        ESP_ERR_INVALID_SIZE,
        TAG,
        "unexpected logical panel geometry");

    s_transfer_done = xSemaphoreCreateBinary();
    ESP_RETURN_ON_FALSE(s_transfer_done != NULL, ESP_ERR_NO_MEM, TAG, "transfer semaphore");
    s_framebuffer = heap_caps_calloc(
        LCD_WIDTH * LCD_HEIGHT,
        sizeof(uint16_t),
        MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    ESP_RETURN_ON_FALSE(s_framebuffer != NULL, ESP_ERR_NO_MEM, TAG, "logical framebuffer");
    s_transfer_buffer = heap_caps_malloc(
        NATIVE_WIDTH * TRANSFER_ROWS * sizeof(uint16_t),
        MALLOC_CAP_DMA | MALLOC_CAP_INTERNAL);
    ESP_RETURN_ON_FALSE(s_transfer_buffer != NULL, ESP_ERR_NO_MEM, TAG, "DMA transfer buffer");

    const i2c_master_bus_config_t i2c_config = {
        .clk_source = I2C_CLK_SRC_DEFAULT,
        .i2c_port = I2C_NUM_0,
        .scl_io_num = EXPANDER_SCL,
        .sda_io_num = EXPANDER_SDA,
        .glitch_ignore_cnt = 7,
        .flags.enable_internal_pullup = true,
    };
    i2c_master_bus_handle_t i2c_bus = NULL;
    ESP_RETURN_ON_ERROR(i2c_new_master_bus(&i2c_config, &i2c_bus), TAG, "create I2C bus");
    ESP_RETURN_ON_ERROR(
        esp_io_expander_new_i2c_tca9554(
            i2c_bus,
            ESP_IO_EXPANDER_I2C_TCA9554_ADDRESS_000,
            &s_io_expander),
        TAG,
        "create TCA9554 expander");
    ESP_RETURN_ON_ERROR(
        esp_io_expander_set_dir(
            s_io_expander,
            EXPANDER_BL_EN | EXPANDER_LCD_RST,
            IO_EXPANDER_OUTPUT),
        TAG,
        "configure LCD expander outputs");
    ESP_RETURN_ON_ERROR(
        esp_io_expander_set_level(s_io_expander, EXPANDER_BL_EN, 0),
        TAG,
        "disable backlight");
    ESP_RETURN_ON_ERROR(
        esp_io_expander_set_level(s_io_expander, EXPANDER_LCD_RST, 1),
        TAG,
        "release LCD reset");

    const gpio_config_t backlight_pwm = {
        .pin_bit_mask = 1ULL << LCD_PWM,
        .mode = GPIO_MODE_OUTPUT,
        .pull_down_en = GPIO_PULLDOWN_ENABLE,
    };
    ESP_RETURN_ON_ERROR(gpio_config(&backlight_pwm), TAG, "configure backlight PWM pin");
    ESP_RETURN_ON_ERROR(
        gpio_set_level(LCD_PWM, 0),
        TAG,
        "set active-low backlight PWM to full brightness");

    const spi_bus_config_t bus_config = AXS15231B_PANEL_BUS_QSPI_CONFIG(
        LCD_PCLK,
        LCD_DATA0,
        LCD_DATA1,
        LCD_DATA2,
        LCD_DATA3,
        NATIVE_WIDTH * TRANSFER_ROWS * sizeof(uint16_t));
    ESP_RETURN_ON_ERROR(
        spi_bus_initialize(LCD_HOST, &bus_config, SPI_DMA_CH_AUTO),
        TAG,
        "initialize LCD QSPI bus");

    esp_lcd_panel_io_handle_t panel_io = NULL;
    const esp_lcd_panel_io_spi_config_t io_config =
        AXS15231B_PANEL_IO_QSPI_CONFIG(LCD_CS, transfer_complete, NULL);
    ESP_RETURN_ON_ERROR(
        esp_lcd_new_panel_io_spi(LCD_HOST, &io_config, &panel_io),
        TAG,
        "create LCD panel IO");

    const axs15231b_vendor_config_t vendor_config = {
        .init_cmds = s_lcd_init_commands,
        .init_cmds_size = sizeof(s_lcd_init_commands) / sizeof(s_lcd_init_commands[0]),
        .flags.use_qspi_interface = 1,
    };
    const esp_lcd_panel_dev_config_t panel_config = {
        .reset_gpio_num = -1,
        .rgb_ele_order = LCD_RGB_ELEMENT_ORDER_RGB,
        .bits_per_pixel = 16,
        .vendor_config = (void *)&vendor_config,
    };
    ESP_RETURN_ON_ERROR(
        esp_lcd_new_panel_axs15231b(panel_io, &panel_config, &s_panel),
        TAG,
        "create AXS15231B panel");

    ESP_RETURN_ON_ERROR(
        esp_io_expander_set_level(s_io_expander, EXPANDER_LCD_RST, 1),
        TAG,
        "start LCD reset sequence");
    vTaskDelay(pdMS_TO_TICKS(30));
    ESP_RETURN_ON_ERROR(
        esp_io_expander_set_level(s_io_expander, EXPANDER_LCD_RST, 0),
        TAG,
        "assert LCD reset");
    vTaskDelay(pdMS_TO_TICKS(250));
    ESP_RETURN_ON_ERROR(
        esp_io_expander_set_level(s_io_expander, EXPANDER_LCD_RST, 1),
        TAG,
        "release LCD reset");
    vTaskDelay(pdMS_TO_TICKS(30));
    return esp_lcd_panel_init(s_panel);
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
    return s_framebuffer;
}

esp_err_t dmd_panel_present(void)
{
    ESP_RETURN_ON_FALSE(s_panel != NULL, ESP_ERR_INVALID_STATE, TAG, "panel not initialized");
    if (!s_first_frame_logged) {
        size_t nonblack_pixels = 0;
        for (size_t index = 0; index < LCD_WIDTH * LCD_HEIGHT; index++) {
            if (s_framebuffer[index] != 0) {
                nonblack_pixels++;
            }
        }
        ESP_LOGI(
            TAG,
            "Presenting first physical frame: %u nonblack pixels",
            (unsigned)nonblack_pixels);
        s_first_frame_logged = true;
    }
    for (int native_y = 0; native_y < NATIVE_HEIGHT; native_y += TRANSFER_ROWS) {
        int rows = NATIVE_HEIGHT - native_y;
        if (rows > TRANSFER_ROWS) {
            rows = TRANSFER_ROWS;
        }
        for (int native_x = 0; native_x < NATIVE_WIDTH; native_x++) {
            for (int row = 0; row < rows; row++) {
                int logical_x = NATIVE_HEIGHT - 1 - (native_y + row);
                uint16_t pixel = s_framebuffer[native_x * LCD_WIDTH + logical_x];
                s_transfer_buffer[row * NATIVE_WIDTH + native_x] = swap_pixel_bytes(pixel);
            }
        }
        ESP_RETURN_ON_ERROR(
            esp_lcd_panel_draw_bitmap(
                s_panel,
                0,
                native_y,
                NATIVE_WIDTH,
                native_y + rows,
                s_transfer_buffer),
            TAG,
            "transfer framebuffer stripe");
        ESP_RETURN_ON_FALSE(
            xSemaphoreTake(s_transfer_done, pdMS_TO_TICKS(2000)) == pdTRUE,
            ESP_ERR_TIMEOUT,
            TAG,
            "wait for framebuffer stripe");
    }
    return ESP_OK;
}

esp_err_t dmd_panel_set_backlight(bool enabled)
{
    ESP_RETURN_ON_FALSE(
        s_io_expander != NULL,
        ESP_ERR_INVALID_STATE,
        TAG,
        "LCD expander not initialized");
    esp_err_t error = esp_io_expander_set_level(
        s_io_expander,
        EXPANDER_BL_EN,
        enabled ? 1 : 0);
    if (error == ESP_OK) {
        ESP_LOGI(TAG, "Panel backlight %s", enabled ? "enabled" : "disabled");
    }
    return error;
}

#endif
