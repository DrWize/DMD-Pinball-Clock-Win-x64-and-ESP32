#include "dmd_board.h"

#include <string.h>

#include "esp_check.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "sdkconfig.h"

static const char *TAG = "dmd_board";

#if CONFIG_DMD_QEMU

esp_err_t dmd_board_init(void)
{
    ESP_LOGI(TAG, "Touch input is unavailable in QEMU; use the matching web controls");
    return ESP_OK;
}

bool dmd_board_read_touch(uint16_t *x, uint16_t *y)
{
    (void)x;
    (void)y;
    return false;
}

bool dmd_board_touch_available(void)
{
    return false;
}

esp_err_t dmd_board_set_sd_enabled(bool enabled)
{
    (void)enabled;
    return ESP_ERR_NOT_SUPPORTED;
}

#else

#include "driver/gpio.h"
#include "driver/i2c_master.h"

#define BOARD_I2C_PORT I2C_NUM_0
#define BOARD_I2C_SDA GPIO_NUM_8
#define BOARD_I2C_SCL GPIO_NUM_9
#define TOUCH_INTERRUPT GPIO_NUM_4
#define CH422_MODE_ADDRESS 0x24
#define CH422_OUTPUT_ADDRESS 0x38
#define GT911_ADDRESS_PRIMARY 0x5d
#define GT911_ADDRESS_SECONDARY 0x14
#define GT911_PRODUCT_ID 0x8140
#define GT911_TOUCH_STATUS 0x814e
#define GT911_FIRST_POINT 0x8150

static i2c_master_bus_handle_t s_bus;
static i2c_master_dev_handle_t s_ch422_mode;
static i2c_master_dev_handle_t s_ch422_output;
static i2c_master_dev_handle_t s_touch;
static uint8_t s_ch422_state = 0x1e;
static bool s_touch_available;

static esp_err_t add_device(
    uint8_t address,
    i2c_master_dev_handle_t *device)
{
    const i2c_device_config_t config = {
        .dev_addr_length = I2C_ADDR_BIT_LEN_7,
        .device_address = address,
        .scl_speed_hz = 400000,
    };
    return i2c_master_bus_add_device(s_bus, &config, device);
}

static esp_err_t write_ch422(uint8_t value)
{
    s_ch422_state = value;
    return i2c_master_transmit(s_ch422_output, &s_ch422_state, 1, 1000);
}

static esp_err_t touch_read(uint16_t register_address, uint8_t *data, size_t size)
{
    uint8_t address[2] = {
        (uint8_t)(register_address >> 8),
        (uint8_t)register_address,
    };
    return i2c_master_transmit_receive(
        s_touch,
        address,
        sizeof(address),
        data,
        size,
        100);
}

static esp_err_t touch_write_u8(uint16_t register_address, uint8_t value)
{
    uint8_t data[3] = {
        (uint8_t)(register_address >> 8),
        (uint8_t)register_address,
        value,
    };
    return i2c_master_transmit(s_touch, data, sizeof(data), 100);
}

static esp_err_t initialize_touch(void)
{
    gpio_config_t interrupt_config = {
        .pin_bit_mask = 1ULL << TOUCH_INTERRUPT,
        .mode = GPIO_MODE_OUTPUT,
        .pull_up_en = GPIO_PULLUP_DISABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_DISABLE,
    };
    ESP_RETURN_ON_ERROR(
        gpio_config(&interrupt_config),
        TAG,
        "configure GT911 interrupt pin");
    gpio_set_level(TOUCH_INTERRUPT, 0);

    ESP_RETURN_ON_ERROR(
        write_ch422(s_ch422_state & ~(1U << 1)),
        TAG,
        "assert GT911 reset");
    vTaskDelay(pdMS_TO_TICKS(15));
    ESP_RETURN_ON_ERROR(
        write_ch422(s_ch422_state | (1U << 1)),
        TAG,
        "release GT911 reset");
    vTaskDelay(pdMS_TO_TICKS(60));

    interrupt_config.mode = GPIO_MODE_INPUT;
    interrupt_config.pull_up_en = GPIO_PULLUP_ENABLE;
    ESP_RETURN_ON_ERROR(
        gpio_config(&interrupt_config),
        TAG,
        "configure GT911 interrupt input");

    uint8_t address = GT911_ADDRESS_PRIMARY;
    if (i2c_master_probe(s_bus, address, 100) != ESP_OK) {
        address = GT911_ADDRESS_SECONDARY;
        if (i2c_master_probe(s_bus, address, 100) != ESP_OK) {
            ESP_LOGW(TAG, "GT911 touch controller was not detected");
            return ESP_ERR_NOT_FOUND;
        }
    }
    ESP_RETURN_ON_ERROR(add_device(address, &s_touch), TAG, "add GT911");

    uint8_t product_id[4] = {0};
    ESP_RETURN_ON_ERROR(
        touch_read(GT911_PRODUCT_ID, product_id, sizeof(product_id)),
        TAG,
        "read GT911 product ID");
    char product[5] = {0};
    memcpy(product, product_id, sizeof(product_id));
    ESP_LOGI(TAG, "GT911 touch ready at 0x%02x (ID %s)", address, product);
    s_touch_available = true;
    return ESP_OK;
}

esp_err_t dmd_board_init(void)
{
    const i2c_master_bus_config_t bus_config = {
        .i2c_port = BOARD_I2C_PORT,
        .sda_io_num = BOARD_I2C_SDA,
        .scl_io_num = BOARD_I2C_SCL,
        .clk_source = I2C_CLK_SRC_DEFAULT,
        .glitch_ignore_cnt = 7,
        .flags.enable_internal_pullup = true,
    };
    ESP_RETURN_ON_ERROR(i2c_new_master_bus(&bus_config, &s_bus), TAG, "I2C bus");
    ESP_RETURN_ON_ERROR(
        add_device(CH422_MODE_ADDRESS, &s_ch422_mode),
        TAG,
        "add CH422G mode device");
    ESP_RETURN_ON_ERROR(
        add_device(CH422_OUTPUT_ADDRESS, &s_ch422_output),
        TAG,
        "add CH422G output device");

    const uint8_t output_mode = 0x01;
    ESP_RETURN_ON_ERROR(
        i2c_master_transmit(s_ch422_mode, &output_mode, 1, 1000),
        TAG,
        "set CH422G output mode");
    ESP_RETURN_ON_ERROR(write_ch422(s_ch422_state), TAG, "enable LCD backlight");

    esp_err_t touch_error = initialize_touch();
    if (touch_error != ESP_OK) {
        ESP_LOGW(
            TAG,
            "Touch controls disabled: %s",
            esp_err_to_name(touch_error));
    }
    return ESP_OK;
}

bool dmd_board_read_touch(uint16_t *x, uint16_t *y)
{
    if (!s_touch_available || x == NULL || y == NULL) {
        return false;
    }

    uint8_t status = 0;
    if (touch_read(GT911_TOUCH_STATUS, &status, 1) != ESP_OK ||
        (status & 0x80) == 0) {
        return false;
    }
    uint8_t point_count = status & 0x0f;
    bool touched = false;
    if (point_count > 0 && point_count <= 5) {
        uint8_t point[8] = {0};
        if (touch_read(GT911_FIRST_POINT, point, sizeof(point)) == ESP_OK) {
            uint16_t point_x = point[1] | ((uint16_t)point[2] << 8);
            uint16_t point_y = point[3] | ((uint16_t)point[4] << 8);
            if (point_x < 800 && point_y < 480) {
                *x = point_x;
                *y = point_y;
                touched = true;
            }
        }
    }
    touch_write_u8(GT911_TOUCH_STATUS, 0);
    return touched;
}

bool dmd_board_touch_available(void)
{
    return s_touch_available;
}

esp_err_t dmd_board_set_sd_enabled(bool enabled)
{
    return write_ch422(
        enabled
            ? (uint8_t)(s_ch422_state & ~(1U << 4))
            : (uint8_t)(s_ch422_state | (1U << 4)));
}

#endif
