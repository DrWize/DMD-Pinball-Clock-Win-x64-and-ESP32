#include "dmd_panel.h"

#include "sdkconfig.h"

#if CONFIG_DMD_QEMU

#include "dmd_geometry.h"
#include "esp_check.h"
#include "esp_lcd_panel_ops.h"
#include "esp_lcd_qemu_rgb.h"
#include "esp_log.h"

static const char *TAG = "dmd_panel_qemu";
static esp_lcd_panel_handle_t s_panel;
static uint16_t *s_framebuffer;

esp_err_t dmd_panel_init(void)
{
    ESP_LOGI(TAG, "Initializing %dx%d virtual RGB panel", LCD_WIDTH, LCD_HEIGHT);
    const esp_lcd_rgb_qemu_config_t config = {
        .width = LCD_WIDTH,
        .height = LCD_HEIGHT,
        .bpp = RGB_QEMU_BPP_16,
    };
    ESP_RETURN_ON_ERROR(
        esp_lcd_new_rgb_qemu(&config, &s_panel),
        TAG,
        "create QEMU panel");
    ESP_RETURN_ON_ERROR(
        esp_lcd_panel_init(s_panel),
        TAG,
        "initialize QEMU panel");
    return esp_lcd_rgb_qemu_get_frame_buffer(
        s_panel,
        (void **)&s_framebuffer);
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

esp_err_t dmd_panel_present(uint16_t rotation)
{
    if (rotation == 180) {
        size_t left = 0;
        size_t right = LCD_WIDTH * LCD_HEIGHT - 1;
        while (left < right) {
            uint16_t pixel = s_framebuffer[left];
            s_framebuffer[left++] = s_framebuffer[right];
            s_framebuffer[right--] = pixel;
        }
    }
    return esp_lcd_rgb_qemu_refresh(s_panel);
}

bool dmd_panel_orientation_sensor_available(void) { return false; }
bool dmd_panel_read_accelerometer(float *x, float *y, float *z)
{
    (void)x; (void)y; (void)z;
    return false;
}

esp_err_t dmd_panel_set_backlight(bool enabled)
{
    (void)enabled;
    return ESP_OK;
}

#endif
