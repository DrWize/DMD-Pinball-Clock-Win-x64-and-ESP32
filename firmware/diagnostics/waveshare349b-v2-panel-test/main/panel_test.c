#include <stdbool.h>
#include <stdint.h>
#include <string.h>

#include "driver/gpio.h"
#include "driver/i2c_master.h"
#include "driver/spi_master.h"
#include "esp_err.h"
#include "esp_heap_caps.h"
#include "esp_io_expander.h"
#include "esp_io_expander_tca9554.h"
#include "esp_lcd_axs15231b.h"
#include "esp_lcd_panel_io.h"
#include "esp_lcd_panel_ops.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"

#define LOGICAL_WIDTH 640
#define LOGICAL_HEIGHT 172
#define NATIVE_WIDTH 172
#define NATIVE_HEIGHT 640
#define TRANSFER_ROWS 32

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

typedef enum {
    PATTERN_RED,
    PATTERN_GREEN,
    PATTERN_BLUE,
    PATTERN_BLACK,
    PATTERN_WHITE,
    PATTERN_GRID,
} panel_pattern_t;

static const char *TAG = "panel349_test";
static SemaphoreHandle_t transfer_done;
static esp_io_expander_handle_t io_expander;
static esp_lcd_panel_handle_t panel;
static uint16_t *transfer_buffer;

static const axs15231b_lcd_init_cmd_t lcd_init_commands[] = {
    {0x11, (uint8_t[]){0x00}, 0, 100},
    {0x29, (uint8_t[]){0x00}, 0, 100},
};

static uint16_t rgb565_wire(uint8_t red, uint8_t green, uint8_t blue)
{
    uint16_t pixel = ((uint16_t)(red & 0xf8) << 8) |
                     ((uint16_t)(green & 0xfc) << 3) |
                     ((uint16_t)blue >> 3);
    return (uint16_t)((pixel << 8) | (pixel >> 8));
}

static uint16_t pattern_pixel(panel_pattern_t pattern, int x, int y)
{
    switch (pattern) {
    case PATTERN_RED:
        return rgb565_wire(255, 0, 0);
    case PATTERN_GREEN:
        return rgb565_wire(0, 255, 0);
    case PATTERN_BLUE:
        return rgb565_wire(0, 0, 255);
    case PATTERN_BLACK:
        return rgb565_wire(0, 0, 0);
    case PATTERN_WHITE:
        return rgb565_wire(255, 255, 255);
    case PATTERN_GRID:
        if (x < 24 && y < 24) {
            return rgb565_wire(255, 0, 0);
        }
        if (x >= LOGICAL_WIDTH - 24 && y < 24) {
            return rgb565_wire(0, 255, 0);
        }
        if (x < 24 && y >= LOGICAL_HEIGHT - 24) {
            return rgb565_wire(0, 0, 255);
        }
        if (x >= LOGICAL_WIDTH - 24 && y >= LOGICAL_HEIGHT - 24) {
            return rgb565_wire(255, 255, 255);
        }
        if (x == 0 || x == LOGICAL_WIDTH - 1 || y == 0 || y == LOGICAL_HEIGHT - 1) {
            return rgb565_wire(255, 255, 0);
        }
        if ((x % 64) == 0 || (y % 32) == 0) {
            return rgb565_wire(0, 255, 255);
        }
        if (x == LOGICAL_WIDTH / 2 || y == LOGICAL_HEIGHT / 2) {
            return rgb565_wire(255, 0, 255);
        }
        return rgb565_wire(12, 12, 12);
    }
    return 0;
}

static bool transfer_complete(
    esp_lcd_panel_io_handle_t panel_io,
    esp_lcd_panel_io_event_data_t *event_data,
    void *user_context)
{
    (void)panel_io;
    (void)event_data;
    (void)user_context;
    BaseType_t task_woken = pdFALSE;
    xSemaphoreGiveFromISR(transfer_done, &task_woken);
    return task_woken == pdTRUE;
}

static void render_pattern(panel_pattern_t pattern)
{
    for (int native_y = 0; native_y < NATIVE_HEIGHT; native_y += TRANSFER_ROWS) {
        int rows = NATIVE_HEIGHT - native_y;
        if (rows > TRANSFER_ROWS) {
            rows = TRANSFER_ROWS;
        }
        for (int row = 0; row < rows; row++) {
            int logical_x = NATIVE_HEIGHT - 1 - (native_y + row);
            for (int native_x = 0; native_x < NATIVE_WIDTH; native_x++) {
                int logical_y = native_x;
                transfer_buffer[row * NATIVE_WIDTH + native_x] =
                    pattern_pixel(pattern, logical_x, logical_y);
            }
        }
        ESP_ERROR_CHECK(esp_lcd_panel_draw_bitmap(
            panel,
            0,
            native_y,
            NATIVE_WIDTH,
            native_y + rows,
            transfer_buffer));
        if (xSemaphoreTake(transfer_done, pdMS_TO_TICKS(2000)) != pdTRUE) {
            ESP_LOGE(TAG, "PANEL_TEST failure=transfer_timeout native_y=%d", native_y);
            abort();
        }
    }
}

static void initialize_panel(void)
{
    i2c_master_bus_config_t i2c_config = {
        .clk_source = I2C_CLK_SRC_DEFAULT,
        .i2c_port = I2C_NUM_0,
        .scl_io_num = EXPANDER_SCL,
        .sda_io_num = EXPANDER_SDA,
        .glitch_ignore_cnt = 7,
        .flags.enable_internal_pullup = true,
    };
    i2c_master_bus_handle_t i2c_bus = NULL;
    ESP_ERROR_CHECK(i2c_new_master_bus(&i2c_config, &i2c_bus));
    ESP_ERROR_CHECK(esp_io_expander_new_i2c_tca9554(
        i2c_bus,
        ESP_IO_EXPANDER_I2C_TCA9554_ADDRESS_000,
        &io_expander));
    ESP_ERROR_CHECK(esp_io_expander_set_dir(
        io_expander,
        EXPANDER_BL_EN | EXPANDER_LCD_RST,
        IO_EXPANDER_OUTPUT));
    ESP_ERROR_CHECK(esp_io_expander_set_level(io_expander, EXPANDER_BL_EN, 0));
    ESP_ERROR_CHECK(esp_io_expander_set_level(io_expander, EXPANDER_LCD_RST, 1));

    gpio_config_t backlight_pwm = {
        .pin_bit_mask = 1ULL << LCD_PWM,
        .mode = GPIO_MODE_OUTPUT,
        .pull_down_en = GPIO_PULLDOWN_ENABLE,
    };
    ESP_ERROR_CHECK(gpio_config(&backlight_pwm));
    ESP_ERROR_CHECK(gpio_set_level(LCD_PWM, 0));

    spi_bus_config_t bus_config = AXS15231B_PANEL_BUS_QSPI_CONFIG(
        LCD_PCLK,
        LCD_DATA0,
        LCD_DATA1,
        LCD_DATA2,
        LCD_DATA3,
        NATIVE_WIDTH * TRANSFER_ROWS * sizeof(uint16_t));
    ESP_ERROR_CHECK(spi_bus_initialize(LCD_HOST, &bus_config, SPI_DMA_CH_AUTO));

    esp_lcd_panel_io_handle_t panel_io = NULL;
    esp_lcd_panel_io_spi_config_t io_config =
        AXS15231B_PANEL_IO_QSPI_CONFIG(LCD_CS, transfer_complete, NULL);
    ESP_ERROR_CHECK(esp_lcd_new_panel_io_spi(LCD_HOST, &io_config, &panel_io));

    axs15231b_vendor_config_t vendor_config = {
        .init_cmds = lcd_init_commands,
        .init_cmds_size = sizeof(lcd_init_commands) / sizeof(lcd_init_commands[0]),
        .flags.use_qspi_interface = 1,
    };
    esp_lcd_panel_dev_config_t panel_config = {
        .reset_gpio_num = -1,
        .rgb_ele_order = LCD_RGB_ELEMENT_ORDER_RGB,
        .bits_per_pixel = 16,
        .vendor_config = &vendor_config,
    };
    ESP_ERROR_CHECK(esp_lcd_new_panel_axs15231b(panel_io, &panel_config, &panel));

    ESP_ERROR_CHECK(esp_io_expander_set_level(io_expander, EXPANDER_LCD_RST, 1));
    vTaskDelay(pdMS_TO_TICKS(30));
    ESP_ERROR_CHECK(esp_io_expander_set_level(io_expander, EXPANDER_LCD_RST, 0));
    vTaskDelay(pdMS_TO_TICKS(250));
    ESP_ERROR_CHECK(esp_io_expander_set_level(io_expander, EXPANDER_LCD_RST, 1));
    vTaskDelay(pdMS_TO_TICKS(30));
    ESP_ERROR_CHECK(esp_lcd_panel_init(panel));
    ESP_ERROR_CHECK(esp_io_expander_set_level(io_expander, EXPANDER_BL_EN, 1));
}

void app_main(void)
{
    transfer_done = xSemaphoreCreateBinary();
    if (transfer_done == NULL) {
        ESP_LOGE(TAG, "PANEL_TEST failure=semaphore_allocation");
        abort();
    }
    transfer_buffer = heap_caps_malloc(
        NATIVE_WIDTH * TRANSFER_ROWS * sizeof(uint16_t),
        MALLOC_CAP_DMA | MALLOC_CAP_INTERNAL);
    if (transfer_buffer == NULL) {
        ESP_LOGE(TAG, "PANEL_TEST failure=dma_allocation");
        abort();
    }

    initialize_panel();
    ESP_LOGI(
        TAG,
        "PANEL_TEST ready width=%d height=%d psram=%u free_heap=%u",
        LOGICAL_WIDTH,
        LOGICAL_HEIGHT,
        (unsigned)heap_caps_get_total_size(MALLOC_CAP_SPIRAM),
        (unsigned)esp_get_free_heap_size());

    const panel_pattern_t patterns[] = {
        PATTERN_RED,
        PATTERN_GREEN,
        PATTERN_BLUE,
        PATTERN_BLACK,
        PATTERN_WHITE,
        PATTERN_GRID,
    };
    const char *names[] = {"red", "green", "blue", "black", "white", "grid"};
    uint32_t cycle = 0;
    while (true) {
        cycle++;
        for (size_t index = 0; index < sizeof(patterns) / sizeof(patterns[0]); index++) {
            render_pattern(patterns[index]);
            ESP_LOGI(
                TAG,
                "PANEL_TEST stage=%s cycle=%u uptime_ms=%lld free_heap=%u",
                names[index],
                (unsigned)cycle,
                esp_timer_get_time() / 1000,
                (unsigned)esp_get_free_heap_size());
            vTaskDelay(pdMS_TO_TICKS(patterns[index] == PATTERN_GRID ? 8000 : 2000));
        }
        ESP_LOGI(TAG, "PANEL_TEST heartbeat cycle=%u", (unsigned)cycle);
    }
}
