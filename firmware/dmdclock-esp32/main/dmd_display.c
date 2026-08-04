#include "dmd_display.h"

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

#include "dmd_actions.h"
#include "dmd_board.h"
#include "dmd_color.h"
#include "dmd_network.h"
#include "dmd_playback_log.h"
#include "dmd_plasma.h"
#include "dmd_scene.h"
#include "dmd_settings.h"
#include "esp_check.h"
#include "esp_lcd_panel_ops.h"
#include "esp_random.h"
#include "esp_system.h"
#include "esp_timer.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"
#include "qrcode.h"
#include "sdkconfig.h"

#if CONFIG_DMD_QEMU
#include "esp_lcd_qemu_rgb.h"
#else
#include "driver/gpio.h"
#include "esp_lcd_panel_rgb.h"
#endif

#define LCD_WIDTH 800
#define LCD_HEIGHT 480
#define LCD_PIXEL_CLOCK_HZ (16 * 1000 * 1000)
#define TOUCH_SCHEDULE_OVERRIDE_US (INT64_C(60) * 60 * 1000000)

#define DMD_WIDTH 128
#define DMD_HEIGHT 32
#define DMD_SCALE 6
#define DMD_PIXEL_SIZE 4
#define DMD_VIEW_WIDTH (DMD_WIDTH * DMD_SCALE)
#define DMD_VIEW_HEIGHT (DMD_HEIGHT * DMD_SCALE)
#define DMD_VIEW_X ((LCD_WIDTH - DMD_VIEW_WIDTH) / 2)
#define DMD_VIEW_Y ((LCD_HEIGHT - DMD_VIEW_HEIGHT) / 2)
#define CONTROL_VISIBLE_US (8LL * 1000 * 1000)
#define CONTROL_FADE_US (1LL * 1000 * 1000)
#define STARTUP_NETWORK_STATUS_US (20LL * 1000 * 1000)
#define TOUCH_TEST_TARGET_US (5LL * 1000 * 1000)
#define TOUCH_TEST_TARGET_COUNT 5
#define TOUCH_TEST_RESULT_US (5LL * 1000 * 1000)
#define SETUP_QR_VISIBLE_US (60LL * 1000 * 1000)

static const char *TAG = "dmd_display";
static esp_lcd_panel_handle_t s_panel;
static uint16_t *s_framebuffer;
#if !CONFIG_DMD_QEMU
static uint16_t *s_framebuffers[2];
static TaskHandle_t s_display_task;
#endif
static uint8_t s_dmd[DMD_WIDTH * DMD_HEIGHT];
static uint8_t s_clock_dmd[DMD_WIDTH * DMD_HEIGHT];
static uint8_t s_scene_mask[DMD_WIDTH * DMD_HEIGHT];
static dmd_rgb_t s_plasma_palette[DMD_PLASMA_PALETTE_SIZE];
static dmd_plasma_palette_t s_cached_plasma_palette = UINT8_MAX;
static dmd_rgb_t s_cached_plasma_custom[DMD_PLASMA_STOP_COUNT];
static SemaphoreHandle_t s_state_lock;
static dmd_display_state_t s_state;
static uint32_t s_command_revision;
static uint32_t s_touch_test_request_revision;
static uint32_t s_setup_qr_request_revision;
static bool s_command_play_scene;
static uint16_t s_command_scene_index;
static int64_t s_controls_last_interaction_at;

typedef struct {
    char character;
    uint8_t width;
    uint8_t rows[7];
} glyph_t;

static const glyph_t GLYPHS[] = {
    {'0', 5, {0x0e, 0x11, 0x13, 0x15, 0x19, 0x11, 0x0e}},
    {'1', 5, {0x04, 0x0c, 0x14, 0x04, 0x04, 0x04, 0x1f}},
    {'2', 5, {0x0e, 0x11, 0x01, 0x02, 0x04, 0x08, 0x1f}},
    {'3', 5, {0x1e, 0x01, 0x01, 0x0e, 0x01, 0x01, 0x1e}},
    {'4', 5, {0x02, 0x06, 0x0a, 0x12, 0x1f, 0x02, 0x02}},
    {'5', 5, {0x1f, 0x10, 0x10, 0x1e, 0x01, 0x01, 0x1e}},
    {'6', 5, {0x0e, 0x10, 0x10, 0x1e, 0x11, 0x11, 0x0e}},
    {'7', 5, {0x1f, 0x01, 0x02, 0x04, 0x08, 0x08, 0x08}},
    {'8', 5, {0x0e, 0x11, 0x11, 0x0e, 0x11, 0x11, 0x0e}},
    {'9', 5, {0x0e, 0x11, 0x11, 0x0f, 0x01, 0x01, 0x0e}},
    {':', 1, {0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00}},
    {'.', 1, {0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01}},
    {'-', 3, {0x00, 0x00, 0x00, 0x07, 0x00, 0x00, 0x00}},
    {' ', 3, {0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00}},
    {'A', 5, {0x0e, 0x11, 0x11, 0x1f, 0x11, 0x11, 0x11}},
    {'B', 5, {0x1e, 0x11, 0x11, 0x1e, 0x11, 0x11, 0x1e}},
    {'C', 5, {0x0f, 0x10, 0x10, 0x10, 0x10, 0x10, 0x0f}},
    {'D', 5, {0x1e, 0x11, 0x11, 0x11, 0x11, 0x11, 0x1e}},
    {'E', 5, {0x1f, 0x10, 0x10, 0x1e, 0x10, 0x10, 0x1f}},
    {'F', 5, {0x1f, 0x10, 0x10, 0x1e, 0x10, 0x10, 0x10}},
    {'G', 5, {0x0f, 0x10, 0x10, 0x17, 0x11, 0x11, 0x0f}},
    {'H', 5, {0x11, 0x11, 0x11, 0x1f, 0x11, 0x11, 0x11}},
    {'I', 5, {0x1f, 0x04, 0x04, 0x04, 0x04, 0x04, 0x1f}},
    {'J', 5, {0x07, 0x02, 0x02, 0x02, 0x12, 0x12, 0x0c}},
    {'K', 5, {0x11, 0x12, 0x14, 0x18, 0x14, 0x12, 0x11}},
    {'L', 5, {0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x1f}},
    {'M', 5, {0x11, 0x1b, 0x15, 0x15, 0x11, 0x11, 0x11}},
    {'N', 5, {0x11, 0x19, 0x15, 0x13, 0x11, 0x11, 0x11}},
    {'O', 5, {0x0e, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0e}},
    {'P', 5, {0x1e, 0x11, 0x11, 0x1e, 0x10, 0x10, 0x10}},
    {'Q', 5, {0x0e, 0x11, 0x11, 0x11, 0x15, 0x12, 0x0d}},
    {'R', 5, {0x1e, 0x11, 0x11, 0x1e, 0x14, 0x12, 0x11}},
    {'S', 5, {0x0f, 0x10, 0x10, 0x0e, 0x01, 0x01, 0x1e}},
    {'T', 5, {0x1f, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04}},
    {'U', 5, {0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0e}},
    {'V', 5, {0x11, 0x11, 0x11, 0x11, 0x11, 0x0a, 0x04}},
    {'W', 5, {0x11, 0x11, 0x11, 0x15, 0x15, 0x15, 0x0a}},
    {'X', 5, {0x11, 0x11, 0x0a, 0x04, 0x0a, 0x11, 0x11}},
    {'Y', 5, {0x11, 0x11, 0x0a, 0x04, 0x04, 0x04, 0x04}},
    {'Z', 5, {0x1f, 0x01, 0x02, 0x04, 0x08, 0x10, 0x1f}},
};

static const glyph_t *find_glyph(char character)
{
    const glyph_t *fallback = &GLYPHS[0];
    for (size_t index = 0; index < sizeof(GLYPHS) / sizeof(GLYPHS[0]); index++) {
        if (GLYPHS[index].character == ' ') {
            fallback = &GLYPHS[index];
        }
        if (GLYPHS[index].character == character) {
            return &GLYPHS[index];
        }
    }
    return fallback;
}

static uint16_t rgb565(uint8_t red, uint8_t green, uint8_t blue)
{
    return (uint16_t)(((red & 0xf8) << 8) |
                      ((green & 0xfc) << 3) |
                      (blue >> 3));
}

static uint16_t fade_rgb565(uint16_t color, uint8_t opacity)
{
    uint8_t red = (uint8_t)(((color >> 11) & 0x1f) << 3);
    uint8_t green = (uint8_t)(((color >> 5) & 0x3f) << 2);
    uint8_t blue = (uint8_t)((color & 0x1f) << 3);
    return rgb565(
        (uint8_t)(((uint16_t)red * opacity) / 255U),
        (uint8_t)(((uint16_t)green * opacity) / 255U),
        (uint8_t)(((uint16_t)blue * opacity) / 255U));
}

static uint8_t controls_opacity(int64_t now)
{
    int64_t idle_for = now - s_controls_last_interaction_at;
    if (idle_for <= CONTROL_VISIBLE_US) {
        return 255;
    }

    int64_t fade_for = idle_for - CONTROL_VISIBLE_US;
    if (fade_for >= CONTROL_FADE_US) {
        return 0;
    }

    uint8_t opacity =
        (uint8_t)(255 - (fade_for * 255 / CONTROL_FADE_US));
    return (uint8_t)((opacity / 16U) * 16U);
}

static uint16_t themed_color(
    dmd_rgb_t color,
    uint8_t brightness,
    uint8_t intensity)
{
    uint32_t scale = (uint32_t)brightness * intensity;
    uint8_t red = (uint8_t)((color.red * scale) / (100U * 15U));
    uint8_t green = (uint8_t)((color.green * scale) / (100U * 15U));
    uint8_t blue = (uint8_t)((color.blue * scale) / (100U * 15U));
    return rgb565(red, green, blue);
}

static void ensure_plasma_palette(const dmd_settings_t *settings)
{
    if (s_cached_plasma_palette == settings->plasma_palette &&
        memcmp(
            s_cached_plasma_custom,
            settings->plasma_custom,
            sizeof(s_cached_plasma_custom)) == 0) {
        return;
    }
    dmd_plasma_build_palette(
        settings->plasma_palette,
        settings->plasma_custom,
        s_plasma_palette);
    s_cached_plasma_palette = settings->plasma_palette;
    memcpy(
        s_cached_plasma_custom,
        settings->plasma_custom,
        sizeof(s_cached_plasma_custom));
}

static void draw_rect(int x, int y, int width, int height, uint16_t color)
{
    if (x < 0 || y < 0 || x + width > LCD_WIDTH || y + height > LCD_HEIGHT) {
        return;
    }
    for (int row = 0; row < height; row++) {
        uint16_t *target = s_framebuffer + (y + row) * LCD_WIDTH + x;
        for (int column = 0; column < width; column++) {
            target[column] = color;
        }
    }
}

static void draw_outline(int x, int y, int width, int height, uint16_t color)
{
    draw_rect(x, y, width, 2, color);
    draw_rect(x, y + height - 2, width, 2, color);
    draw_rect(x, y, 2, height, color);
    draw_rect(x + width - 2, y, 2, height, color);
}

static int lcd_text_width(const char *text, int scale)
{
    int width = 0;
    for (size_t index = 0; text[index] != '\0'; index++) {
        width += (find_glyph(text[index])->width + 1) * scale;
    }
    return width > 0 ? width - scale : 0;
}

static void draw_lcd_text(
    const char *text,
    int x,
    int y,
    int scale,
    uint16_t color)
{
    int cursor_x = x;
    for (size_t index = 0; text[index] != '\0'; index++) {
        const glyph_t *glyph = find_glyph(text[index]);
        for (int row = 0; row < 7; row++) {
            for (int column = 0; column < glyph->width; column++) {
                uint8_t mask = (uint8_t)(1U << (glyph->width - column - 1));
                if ((glyph->rows[row] & mask) != 0) {
                    draw_rect(
                        cursor_x + column * scale,
                        y + row * scale,
                        scale,
                        scale,
                        color);
                }
            }
        }
        cursor_x += (glyph->width + 1) * scale;
    }
}

static void draw_button_at(
    int x,
    int y,
    int width,
    int height,
    const char *label,
    uint16_t accent,
    uint8_t opacity)
{
    draw_rect(x, y, width, height, fade_rgb565(rgb565(22, 15, 10), opacity));
    draw_outline(x, y, width, height, fade_rgb565(accent, opacity));
    int text_width = lcd_text_width(label, 2);
    draw_lcd_text(
        label,
        x + (width - text_width) / 2,
        y + (height - 14) / 2,
        2,
        fade_rgb565(rgb565(245, 238, 230), opacity));
}

static void draw_button(
    int x,
    int width,
    const char *label,
    uint16_t accent,
    uint8_t opacity)
{
    draw_button_at(x, 400, width, 56, label, accent, opacity);
}

static void uppercase_copy(char *target, size_t capacity, const char *source)
{
    size_t index = 0;
    while (index + 1 < capacity && source[index] != '\0') {
        char value = source[index];
        target[index] =
            value >= 'a' && value <= 'z' ? (char)(value - 'a' + 'A') : value;
        index++;
    }
    target[index] = '\0';
}

static void draw_lcd_text_fit(
    const char *text,
    int x,
    int y,
    int scale,
    int max_width,
    uint16_t color)
{
    char fitted[256];
    strlcpy(fitted, text, sizeof(fitted));
    if (lcd_text_width(fitted, scale) > max_width) {
        size_t length = strlen(fitted);
        while (length > 3) {
            fitted[--length] = '\0';
            if (lcd_text_width(fitted, scale) +
                    lcd_text_width("...", scale) <=
                max_width) {
                break;
            }
        }
        strlcat(fitted, "...", sizeof(fitted));
    }
    draw_lcd_text(fitted, x, y, scale, color);
}

static void draw_centered_lcd_text(
    const char *text,
    int y,
    int scale,
    uint16_t color)
{
    char uppercase[256];
    uppercase_copy(uppercase, sizeof(uppercase), text);
    int width = lcd_text_width(uppercase, scale);
    if (width <= LCD_WIDTH - 40) {
        draw_lcd_text(uppercase, (LCD_WIDTH - width) / 2, y, scale, color);
    } else {
        draw_lcd_text_fit(uppercase, 20, y, scale, LCD_WIDTH - 40, color);
    }
}

static dmd_rgb_t settings_color_at(
    const dmd_settings_t *settings,
    uint8_t x,
    uint8_t y)
{
    if (settings->color_preset == DMD_COLOR_BASIC_CUSTOM) {
        return dmd_color_custom_at(
            settings->color_preset, &settings->basic_custom, 1, x, y);
    }
    if (settings->color_preset == DMD_COLOR_GRADIENT_CUSTOM) {
        return dmd_color_custom_at(
            settings->color_preset,
            settings->gradient_custom,
            DMD_GRADIENT_CUSTOM_COLOR_COUNT,
            x,
            y);
    }
    if (settings->color_preset == DMD_COLOR_RASTER_CUSTOM) {
        return dmd_color_custom_at(
            settings->color_preset,
            settings->raster_custom,
            DMD_RASTER_CUSTOM_COLOR_COUNT,
            x,
            y);
    }
    return dmd_color_at(settings->color_preset, x, y);
}

static void paint_startup_network_status(
    const dmd_settings_t *settings,
    const dmd_network_info_t *network)
{
    memset(s_framebuffer, 0, LCD_WIDTH * LCD_HEIGHT * sizeof(uint16_t));

    dmd_rgb_t rgb = settings_color_at(settings, 64, 16);
    uint16_t accent = rgb565(rgb.red, rgb.green, rgb.blue);
    uint16_t text = rgb565(245, 238, 230);
    char line[96];

    draw_centered_lcd_text(
        network->device_name[0] != '\0' ? network->device_name : "DMDClock",
        72,
        4,
        accent);
    draw_centered_lcd_text("Network startup", 132, 2, text);

    if (settings->wifi_ssid[0] != '\0') {
        snprintf(line, sizeof(line), "Wi-Fi: %s", settings->wifi_ssid);
    } else {
        strlcpy(line, "Wi-Fi: Not configured", sizeof(line));
    }
    draw_centered_lcd_text(line, 214, 2, accent);

    if (network->station_connected && network->station_ip[0] != '\0') {
        snprintf(line, sizeof(line), "IP: %s", network->station_ip);
    } else if (settings->wifi_ssid[0] != '\0') {
        strlcpy(line, "IP: Connecting", sizeof(line));
    } else {
        strlcpy(line, "IP: Not available", sizeof(line));
    }
    draw_centered_lcd_text(line, 262, 2, text);

    if (!network->station_connected) {
        snprintf(
            line,
            sizeof(line),
            "Setup IP: %s",
            network->access_point_ip[0] != '\0'
                ? network->access_point_ip
                : "192.168.4.1");
        draw_centered_lcd_text(line, 310, 2, text);
    }
}

static void draw_setup_qr(esp_qrcode_handle_t qrcode)
{
    int size = esp_qrcode_get_size(qrcode);
    const int quiet = 4;
    int scale = 330 / (size + quiet * 2);
    if (scale < 1) {
        scale = 1;
    }
    int extent = (size + quiet * 2) * scale;
    int origin_x = (LCD_WIDTH - extent) / 2;
    int origin_y = 68;
    uint16_t white = rgb565(255, 255, 255);
    uint16_t black = rgb565(0, 0, 0);
    draw_rect(origin_x, origin_y, extent, extent, white);
    for (int y = 0; y < size; y++) {
        for (int x = 0; x < size; x++) {
            if (esp_qrcode_get_module(qrcode, x, y)) {
                draw_rect(
                    origin_x + (x + quiet) * scale,
                    origin_y + (y + quiet) * scale,
                    scale,
                    scale,
                    black);
            }
        }
    }
}

static void paint_setup_qr(
    const dmd_settings_t *settings,
    const dmd_network_info_t *network)
{
    memset(s_framebuffer, 0, LCD_WIDTH * LCD_HEIGHT * sizeof(uint16_t));
    const char *address =
        network->station_connected && network->station_ip[0] != '\0'
            ? network->station_ip
            : network->access_point_ip;
    char url[64];
    snprintf(url, sizeof(url), "http://%s/", address);
    dmd_rgb_t rgb = settings_color_at(settings, 64, 16);
    uint16_t accent = rgb565(rgb.red, rgb.green, rgb.blue);
    uint16_t text = rgb565(245, 238, 230);
    draw_centered_lcd_text("SCAN TO SET UP DMDCLOCK", 18, 2, accent);
    esp_qrcode_config_t config = ESP_QRCODE_CONFIG_DEFAULT();
    config.display_func = draw_setup_qr;
    config.max_qrcode_version = 5;
    config.qrcode_ecc_level = ESP_QRCODE_ECC_MED;
    if (esp_qrcode_generate(&config, url) != ESP_OK) {
        draw_centered_lcd_text("QR CODE COULD NOT BE GENERATED", 200, 2, text);
    }
    draw_centered_lcd_text(url, 424, 2, text);
    draw_centered_lcd_text("Returns automatically after 60 seconds", 454, 1, accent);
}

static void paint_touch_test(
    const dmd_settings_t *settings,
    uint8_t target_index,
    uint8_t countdown,
    uint32_t event_count,
    const dmd_touch_diagnostics_t *touch)
{
    static const int target_x[TOUCH_TEST_TARGET_COUNT] = {
        120, 680, 400, 680, 120,
    };
    static const int target_y[TOUCH_TEST_TARGET_COUNT] = {
        190, 190, 280, 380, 380,
    };
    memset(s_framebuffer, 0, LCD_WIDTH * LCD_HEIGHT * sizeof(uint16_t));

    dmd_rgb_t rgb = settings_color_at(settings, 64, 16);
    uint16_t accent = rgb565(rgb.red, rgb.green, rgb.blue);
    uint16_t text = rgb565(245, 238, 230);
    uint16_t target = rgb565(255, 190, 32);
    char line[96];

    draw_centered_lcd_text("TOUCH TEST", 28, 3, accent);
    snprintf(
        line,
        sizeof(line),
        "TOUCH TARGET %u OF %u",
        target_index + 1,
        TOUCH_TEST_TARGET_COUNT);
    draw_centered_lcd_text(line, 72, 2, text);
    snprintf(line, sizeof(line), "COUNTDOWN %u", countdown);
    draw_centered_lcd_text(line, 102, 2, target);

    int x = target_x[target_index];
    int y = target_y[target_index];
    draw_outline(x - 50, y - 50, 101, 101, target);
    draw_outline(x - 38, y - 38, 77, 77, accent);
    draw_rect(x - 4, y - 30, 8, 61, text);
    draw_rect(x - 30, y - 4, 61, 8, text);
    draw_rect(x - 8, y - 8, 16, 16, target);

    snprintf(line, sizeof(line), "EVENTS %lu", (unsigned long)event_count);
    draw_centered_lcd_text(line, 438, 2, text);
    if (touch->event_count > 0) {
        snprintf(
            line,
            sizeof(line),
            "LAST %u %u",
            touch->last_x,
            touch->last_y);
        draw_centered_lcd_text(line, 408, 2, accent);
    }
}

static void paint_touch_test_result(
    const dmd_settings_t *settings,
    uint32_t event_count)
{
    memset(s_framebuffer, 0, LCD_WIDTH * LCD_HEIGHT * sizeof(uint16_t));
    dmd_rgb_t rgb = settings_color_at(settings, 64, 16);
    uint16_t accent = rgb565(rgb.red, rgb.green, rgb.blue);
    uint16_t text = rgb565(245, 238, 230);
    char line[64];

    draw_centered_lcd_text("TOUCH TEST COMPLETE", 120, 3, accent);
    snprintf(line, sizeof(line), "EVENTS %lu", (unsigned long)event_count);
    draw_centered_lcd_text(line, 210, 3, text);
    draw_centered_lcd_text(
        event_count > 0 ? "TOUCH DATA RECEIVED" : "NO TOUCH DATA RECEIVED",
        280,
        2,
        event_count > 0 ? accent : rgb565(255, 96, 64));
}

static void draw_screen_chrome(
    const dmd_settings_t *settings,
    const dmd_scene_info_t *scene,
    const dmd_network_info_t *network,
    uint8_t controls_opacity_value)
{
    dmd_rgb_t rgb = settings_color_at(settings, 64, 16);
    uint16_t accent = rgb565(rgb.red, rgb.green, rgb.blue);

    if (settings->show_information) {
        dmd_rgb_t information_rgb;
        if (settings->information_color_mode ==
            DMD_INFORMATION_COLOR_THEME) {
            information_rgb = rgb;
        } else if (settings->information_color_mode ==
                   DMD_INFORMATION_COLOR_CUSTOM) {
            information_rgb = settings->information_custom_color;
        } else {
            information_rgb = (dmd_rgb_t){144, 144, 144};
        }
        uint16_t information_color = rgb565(
            information_rgb.red,
            information_rgb.green,
            information_rgb.blue);
        dmd_scene_metadata_t metadata;
        dmd_scene_get_metadata(scene->index, &metadata);
        char source[256];
        char info[256];
        char scene_name[DMD_SCENE_FILE_NAME_MAX];
        strlcpy(scene_name, scene->file_name, sizeof(scene_name));
        char *extension = strrchr(scene_name, '.');
        if (extension != NULL) {
            *extension = '\0';
        }
        const char *scene_title =
            metadata.title[0] != '\0' ? metadata.title : scene_name;
        source[0] = '\0';
        if (metadata.game[0] != '\0') {
            strlcat(source, metadata.game, sizeof(source));
        }
        if (scene_title[0] != '\0') {
            if (source[0] != '\0') {
                strlcat(source, " - ", sizeof(source));
            }
            strlcat(source, scene_title, sizeof(source));
        }
        if (metadata.year > 0) {
            char year[8];
            snprintf(year, sizeof(year), "%u", metadata.year);
            if (source[0] != '\0') {
                strlcat(source, " - ", sizeof(source));
            }
            strlcat(source, year, sizeof(source));
        }
        if (metadata.manufacturer[0] != '\0') {
            if (source[0] != '\0') {
                strlcat(source, " - ", sizeof(source));
            }
            strlcat(source, metadata.manufacturer, sizeof(source));
        }
        if (source[0] != '\0') {
            uppercase_copy(info, sizeof(info), source);
            draw_lcd_text_fit(
                info,
                20,
                70,
                2,
                LCD_WIDTH - 40,
                information_color);
        }
    }

    if (controls_opacity_value > 0) {
        draw_button_at(
            10, 10, 253, 46, "NEXT PINBALL", accent, controls_opacity_value);
        draw_button_at(
            273, 10, 253, 46, "NEXT SCENE", accent, controls_opacity_value);
        draw_button_at(
            536,
            10,
            254,
            46,
            settings->random_playback ? "RANDOM ON" : "RANDOM OFF",
            accent,
            controls_opacity_value);
        draw_button(10, 148, "THEME", accent, controls_opacity_value);
        draw_button(168, 148, "COLOUR", accent, controls_opacity_value);
        draw_button(
            326,
            148,
            settings->show_information ? "INFO ON" : "INFO OFF",
            accent,
            controls_opacity_value);
        draw_button(
            484,
            148,
            settings->glow_strength > 0 ? "GLOW ON" : "GLOW OFF",
            accent,
            controls_opacity_value);
        char ntp_label[24] = "NTP CHECK";
        if (network->ntp_syncing) {
            strlcpy(ntp_label, "NTP ...", sizeof(ntp_label));
        } else if (network->ntp_synced && network->ntp_last_sync > 0) {
            time_t now = time(NULL);
            unsigned long age = now > network->ntp_last_sync
                ? (unsigned long)(now - network->ntp_last_sync)
                : 0;
            if (age < 60) {
                snprintf(ntp_label, sizeof(ntp_label), "NTP OK %lus", age);
            } else if (age < 3600) {
                snprintf(ntp_label, sizeof(ntp_label), "NTP OK %lum", age / 60);
            } else {
                snprintf(ntp_label, sizeof(ntp_label), "NTP OK %luh", age / 3600);
            }
        }
        draw_button(642, 148, ntp_label, accent, controls_opacity_value);
    }
}

static void dmd_set_block(uint8_t *buffer, int x, int y, int scale)
{
    for (int row = 0; row < scale; row++) {
        int target_y = y + row;
        if (target_y < 0 || target_y >= DMD_HEIGHT) {
            continue;
        }
        for (int column = 0; column < scale; column++) {
            int target_x = x + column;
            if (target_x >= 0 && target_x < DMD_WIDTH) {
                buffer[target_y * DMD_WIDTH + target_x] = 15;
            }
        }
    }
}

static void render_text_to_buffer(
    uint8_t *buffer,
    const char *text,
    int requested_scale,
    int center_x,
    int center_y)
{
    memset(buffer, 0, DMD_WIDTH * DMD_HEIGHT);
    size_t length = strlen(text);
    int base_width = length > 0 ? (int)length - 1 : 0;
    for (size_t index = 0; index < length; index++) {
        base_width += find_glyph(text[index])->width;
    }

    int scale_x = base_width > 0 ? DMD_WIDTH / base_width : 1;
    int scale_y = DMD_HEIGHT / 7;
    int font_scale = requested_scale > 0
        ? requested_scale
        : (scale_x < scale_y ? scale_x : scale_y);
    if (font_scale > 4) {
        font_scale = 4;
    }
    if (font_scale < 1) {
        font_scale = 1;
    }

    int rendered_width = base_width * font_scale;
    int cursor_x = center_x - rendered_width / 2;
    int origin_y = center_y - (7 * font_scale) / 2;

    for (size_t index = 0; index < length; index++) {
        const glyph_t *glyph = find_glyph(text[index]);
        for (int row = 0; row < 7; row++) {
            for (int column = 0; column < glyph->width; column++) {
                uint8_t mask = (uint8_t)(1U << (glyph->width - column - 1));
                if ((glyph->rows[row] & mask) != 0) {
                    dmd_set_block(
                        buffer,
                        cursor_x + column * font_scale,
                        origin_y + row * font_scale,
                        font_scale);
                }
            }
        }
        cursor_x += (glyph->width + 1) * font_scale;
    }
}

static void render_text_to_dmd(const char *text)
{
    render_text_to_buffer(s_dmd, text, 0, DMD_WIDTH / 2, DMD_HEIGHT / 2);
}

static void overlay_scene_clock(
    const dmd_settings_t *settings,
    const dmd_scene_info_t *scene,
    bool clock_above,
    time_t now)
{
    char time_text[16];
    struct tm local;
    localtime_r(&now, &local);
    const char *format = scene->clock_style == 1
        ? (settings->use_24_hour ? "%H:%M" : "%I:%M")
        : (settings->show_seconds
            ? (settings->use_24_hour ? "%H:%M:%S" : "%I:%M:%S")
            : (settings->use_24_hour ? "%H:%M" : "%I:%M"));
    strftime(time_text, sizeof(time_text), format, &local);
    if (!settings->use_24_hour && time_text[0] == '0') {
        memmove(time_text, time_text + 1, strlen(time_text));
    }
    int center_x = scene->clock_style == 1 ? scene->clock_x : DMD_WIDTH / 2;
    int center_y = scene->clock_style == 1 ? scene->clock_y : DMD_HEIGHT / 2;
    render_text_to_buffer(
        s_clock_dmd,
        time_text,
        scene->clock_style == 1 ? 2 : 0,
        center_x,
        center_y);
    for (size_t index = 0; index < sizeof(s_dmd); index++) {
        if (s_scene_mask[index] != 0) {
            s_dmd[index] = 0;
        }
        if (clock_above) {
            if (s_clock_dmd[index] != 0) {
                s_dmd[index] = s_clock_dmd[index];
            }
        } else if (s_scene_mask[index] != 0) {
            s_dmd[index] = s_clock_dmd[index];
        }
    }
}

static void paint_dmd(
    const dmd_settings_t *settings,
    const dmd_display_state_t *display,
    const dmd_scene_info_t *scene,
    time_t now,
    bool schedule_override_active,
    uint8_t controls_opacity_value,
    uint8_t plasma_phase)
{
    memset(s_framebuffer, 0, LCD_WIDTH * LCD_HEIGHT * sizeof(uint16_t));
    if (!settings->display_on ||
        (dmd_settings_screen_scheduled_off(settings, now) &&
         !schedule_override_active)) {
        return;
    }

    ensure_plasma_palette(settings);
    dmd_network_info_t network;
    dmd_network_get_info(&network);
    draw_screen_chrome(
        settings,
        scene,
        &network,
        controls_opacity_value);
    for (int dmd_y = 0; dmd_y < DMD_HEIGHT; dmd_y++) {
        for (int dmd_x = 0; dmd_x < DMD_WIDTH; dmd_x++) {
            uint8_t intensity = s_dmd[dmd_y * DMD_WIDTH + dmd_x];
            dmd_rgb_t theme_color;
            if (settings->color_preset == DMD_COLOR_PLASMA) {
                theme_color = s_plasma_palette[dmd_plasma_palette_index(
                    (uint8_t)dmd_x,
                    (uint8_t)dmd_y,
                    plasma_phase)];
            } else {
                theme_color = settings_color_at(
                    settings,
                    (uint8_t)dmd_x,
                    (uint8_t)dmd_y);
            }
            uint16_t color = themed_color(
                theme_color,
                settings->brightness,
                intensity == 0 ? 1 : intensity);
            int cell_x = DMD_VIEW_X + dmd_x * DMD_SCALE;
            int cell_y = DMD_VIEW_Y + dmd_y * DMD_SCALE;
            int pixel_x = cell_x + 1;
            int pixel_y = cell_y + 1;

            uint16_t glow_color = 0;
            if (intensity > 0 && settings->glow_strength > 0) {
                uint8_t glow_intensity = (uint8_t)(
                    ((uint16_t)intensity * settings->glow_strength) / 100U);
                if (glow_intensity > 0) {
                    glow_color = themed_color(
                        theme_color,
                        settings->brightness,
                        glow_intensity);
                    for (int row = 0; row < DMD_SCALE; row++) {
                        for (int column = 0; column < DMD_SCALE; column++) {
                            s_framebuffer[
                                (cell_y + row) * LCD_WIDTH +
                                cell_x + column] = glow_color;
                        }
                    }
                }
            }

            for (int row = 0; row < DMD_PIXEL_SIZE; row++) {
                for (int column = 0; column < DMD_PIXEL_SIZE; column++) {
                    bool corner = (row == 0 || row == DMD_PIXEL_SIZE - 1) &&
                                  (column == 0 || column == DMD_PIXEL_SIZE - 1);
                    s_framebuffer[(pixel_y + row) * LCD_WIDTH + pixel_x + column] =
                        corner ? glow_color : color;
                }
            }
        }
    }
}

static void refresh_display(void)
{
#if CONFIG_DMD_QEMU
    ESP_ERROR_CHECK(esp_lcd_rgb_qemu_refresh(s_panel));
#else
    ulTaskNotifyValueClear(NULL, ULONG_MAX);
    ESP_ERROR_CHECK(
        esp_lcd_panel_draw_bitmap(
            s_panel,
            0,
            0,
            LCD_WIDTH,
            LCD_HEIGHT,
            s_framebuffer));
    if (ulTaskNotifyTake(pdTRUE, pdMS_TO_TICKS(100)) == 0) {
        ESP_LOGW(TAG, "Timed out waiting for RGB frame-buffer handoff");
    }
    s_framebuffer =
        s_framebuffer == s_framebuffers[0]
            ? s_framebuffers[1]
            : s_framebuffers[0];
#endif
}

#if !CONFIG_DMD_QEMU
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
#endif

esp_err_t dmd_display_init(void)
{
    ESP_RETURN_ON_FALSE(
        dmd_plasma_self_test(),
        ESP_ERR_INVALID_STATE,
        TAG,
        "Plasma reference-vector self-test failed");
#if CONFIG_DMD_QEMU
    ESP_LOGI(TAG, "Initializing QEMU 800x480 virtual RGB panel");
    const esp_lcd_rgb_qemu_config_t qemu_config = {
        .width = LCD_WIDTH,
        .height = LCD_HEIGHT,
        .bpp = RGB_QEMU_BPP_16,
    };
    ESP_RETURN_ON_ERROR(
        esp_lcd_new_rgb_qemu(&qemu_config, &s_panel),
        TAG,
        "create QEMU panel");
    ESP_RETURN_ON_ERROR(esp_lcd_panel_init(s_panel), TAG, "initialize QEMU panel");
    ESP_RETURN_ON_ERROR(
        esp_lcd_rgb_qemu_get_frame_buffer(s_panel, (void **)&s_framebuffer),
        TAG,
        "get QEMU framebuffer");
#else
    ESP_LOGI(TAG, "Initializing 800x480 RGB panel");
    const esp_lcd_rgb_panel_config_t panel_config = {
        .clk_src = LCD_CLK_SRC_DEFAULT,
        .timings = {
            .pclk_hz = LCD_PIXEL_CLOCK_HZ,
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
        esp_lcd_new_rgb_panel(&panel_config, &s_panel),
        TAG,
        "create panel");
    ESP_RETURN_ON_ERROR(esp_lcd_panel_reset(s_panel), TAG, "reset panel");
    ESP_RETURN_ON_ERROR(esp_lcd_panel_init(s_panel), TAG, "initialize panel");
    const esp_lcd_rgb_panel_event_callbacks_t callbacks = {
        .on_frame_buf_complete = frame_buffer_complete,
    };
    ESP_RETURN_ON_ERROR(
        esp_lcd_rgb_panel_register_event_callbacks(
            s_panel,
            &callbacks,
            NULL),
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
    memset(
        s_framebuffers[0],
        0,
        LCD_WIDTH * LCD_HEIGHT * sizeof(uint16_t));
    memset(
        s_framebuffers[1],
        0,
        LCD_WIDTH * LCD_HEIGHT * sizeof(uint16_t));
    s_framebuffer = s_framebuffers[1];

#endif
    s_state_lock = xSemaphoreCreateMutex();
    if (s_state_lock == NULL) {
        return ESP_ERR_NO_MEM;
    }
    memset(&s_state, 0, sizeof(s_state));
    memset(s_framebuffer, 0, LCD_WIDTH * LCD_HEIGHT * sizeof(uint16_t));
#if CONFIG_DMD_QEMU
    refresh_display();
#endif
    return ESP_OK;
}

void dmd_display_play_scene(uint16_t scene_index)
{
    if (s_state_lock == NULL || scene_index >= dmd_scene_count()) {
        return;
    }
    xSemaphoreTake(s_state_lock, portMAX_DELAY);
    s_command_play_scene = true;
    s_command_scene_index = scene_index;
    s_command_revision++;
    xSemaphoreGive(s_state_lock);
}

void dmd_display_show_clock(void)
{
    if (s_state_lock == NULL) {
        return;
    }
    xSemaphoreTake(s_state_lock, portMAX_DELAY);
    s_command_play_scene = false;
    s_command_revision++;
    xSemaphoreGive(s_state_lock);
}

void dmd_display_start_touch_test(void)
{
    if (s_state_lock == NULL) {
        return;
    }
    xSemaphoreTake(s_state_lock, portMAX_DELAY);
    s_touch_test_request_revision++;
    xSemaphoreGive(s_state_lock);
}

void dmd_display_show_setup_qr(void)
{
    if (s_state_lock == NULL) {
        return;
    }
    xSemaphoreTake(s_state_lock, portMAX_DELAY);
    s_setup_qr_request_revision++;
    xSemaphoreGive(s_state_lock);
}

void dmd_display_get_state(dmd_display_state_t *state)
{
    if (state == NULL || s_state_lock == NULL) {
        return;
    }
    xSemaphoreTake(s_state_lock, portMAX_DELAY);
    *state = s_state;
    xSemaphoreGive(s_state_lock);
}

static void publish_state(
    bool playing_scene,
    bool waiting_for_scene,
    uint16_t scene_index,
    uint16_t scene_step,
    uint16_t scene_frame,
    uint8_t animations_remaining,
    uint8_t plasma_phase,
    uint32_t plasma_frames_rendered,
    uint32_t display_frames_rendered,
    uint32_t schedule_override_seconds_remaining,
    bool touch_test_running)
{
    xSemaphoreTake(s_state_lock, portMAX_DELAY);
    s_state.playing_scene = playing_scene;
    s_state.waiting_for_scene = waiting_for_scene;
    s_state.scene_index = scene_index;
    s_state.scene_step = scene_step;
    s_state.scene_frame = scene_frame;
    s_state.animations_remaining = animations_remaining;
    s_state.plasma_phase = plasma_phase;
    s_state.plasma_frames_rendered = plasma_frames_rendered;
    s_state.display_frames_rendered = display_frames_rendered;
    s_state.schedule_override_seconds_remaining =
        schedule_override_seconds_remaining;
    s_state.touch_test_running = touch_test_running;
    xSemaphoreGive(s_state_lock);
}

static uint16_t next_automatic_scene(
    uint16_t current,
    bool random_playback)
{
    uint16_t scene_count = dmd_scene_count();
    if (scene_count == 0) {
        return 0;
    }
    if (!random_playback || scene_count == 1) {
        return (current + 1) % scene_count;
    }
    uint16_t next = current;
    while (next == current) {
        next = (uint16_t)(esp_random() % scene_count);
    }
    return next;
}

static void render_clock(const dmd_settings_t *settings)
{
    char time_text[16];
    if (!dmd_settings_time_is_valid()) {
        strlcpy(time_text, "--:--", sizeof(time_text));
    } else {
        time_t now = time(NULL);
        struct tm local;
        localtime_r(&now, &local);
        const char *format = settings->show_seconds
            ? (settings->use_24_hour ? "%H:%M:%S" : "%I:%M:%S")
            : (settings->use_24_hour ? "%H:%M" : "%I:%M");
        strftime(time_text, sizeof(time_text), format, &local);
        if (!settings->use_24_hour && time_text[0] == '0') {
            memmove(time_text, time_text + 1, strlen(time_text));
        }
    }
    render_text_to_dmd(time_text);
}

static bool handle_touch(
    int64_t now,
    bool execute_controls,
    uint16_t *touch_x,
    uint16_t *touch_y)
{
    static int64_t last_touch_at;
    uint16_t x;
    uint16_t y;
    if (!dmd_board_read_touch(&x, &y) ||
        now - last_touch_at < 350000) {
        return false;
    }

    last_touch_at = now;
    if (touch_x != NULL) {
        *touch_x = x;
    }
    if (touch_y != NULL) {
        *touch_y = y;
    }
    if (!execute_controls) {
        return true;
    }

    bool controls_hidden = controls_opacity(now) == 0;
    s_controls_last_interaction_at = now;
    if (controls_hidden) {
        return true;
    }

    if (y < 70) {
        dmd_action_execute(
            x < 267
                ? DMD_ACTION_PINBALL_NEXT
                : (x < 533
                    ? DMD_ACTION_SCENE_NEXT
                    : DMD_ACTION_TOGGLE_RANDOM));
    } else if (y < 390) {
        return true;
    } else if (x < 160) {
        dmd_action_execute(DMD_ACTION_COLOR_FAMILY_NEXT);
    } else if (x < 320) {
        dmd_action_execute(DMD_ACTION_COLOR_THEME_NEXT);
    } else if (x < 480) {
        dmd_action_execute(DMD_ACTION_TOGGLE_INFORMATION);
    } else if (x < 640) {
        dmd_action_execute(DMD_ACTION_TOGGLE_GLOW);
    } else {
        dmd_action_execute(DMD_ACTION_SYNC_NTP);
    }
    return true;
}

void dmd_display_task(void *context)
{
    (void)context;
#if !CONFIG_DMD_QEMU
    s_display_task = xTaskGetCurrentTaskHandle();
#endif
    dmd_settings_t settings;
    dmd_settings_get(&settings);

    bool playing_scene =
        settings.play_scene && dmd_scene_count() > 0;
    bool waiting_for_scene = false;
    uint16_t active_scene = settings.scene_index;
    uint8_t animations_remaining = 0;
    uint16_t scene_step = 0;
    uint16_t scene_frame = 0;
    uint32_t previous_revision = 0;
    dmd_color_preset_t previous_color_preset = settings.color_preset;
    dmd_plasma_palette_t previous_plasma_palette = settings.plasma_palette;
    bool previous_playback_log_enabled = settings.playback_log_enabled;
    uint32_t handled_command_revision = 0;
    time_t previous_second = 0;
    time_t previous_reboot_minute = -1;
    int64_t schedule_awake_until = 0;
    bool previous_schedule_override_active = false;
    bool previous_scheduled_off = false;
    int64_t monotonic_now = esp_timer_get_time();
    int64_t startup_network_status_until =
        monotonic_now + STARTUP_NETWORK_STATUS_US;
    int64_t touch_test_started_at = 0;
    int64_t touch_test_until = 0;
    int64_t touch_test_result_until = 0;
    int64_t setup_qr_until = 0;
    bool startup_network_status_painted = false;
    bool previous_startup_network_status_visible = true;
    bool previous_touch_test_visible = false;
    bool previous_touch_test_result_visible = false;
    uint8_t previous_touch_test_target = UINT8_MAX;
    uint8_t previous_touch_test_countdown = UINT8_MAX;
    uint32_t touch_test_start_events = 0;
    bool touch_test_start_events_captured = false;
    uint32_t handled_touch_test_request_revision = 0;
    uint32_t handled_setup_qr_request_revision = 0;
    bool previous_setup_qr_visible = false;
    bool previous_station_connected = false;
    char previous_station_ip[16] = "";
    int64_t next_scene_frame_at = 0;
    int64_t next_mode_at =
        monotonic_now + (int64_t)settings.clock_display_seconds * 1000000;
    s_controls_last_interaction_at = monotonic_now;
    uint8_t previous_controls_opacity = 255;
    uint8_t plasma_phase = dmd_plasma_phase_at_ms(
        (uint64_t)(monotonic_now / 1000),
        settings.plasma_cycle_ms);
    int64_t next_plasma_frame_at = monotonic_now;
    uint32_t plasma_frames_rendered = 0;
    uint32_t display_frames_rendered = 0;
    bool force_render = true;

    if (playing_scene) {
        esp_err_t error = dmd_scene_select(active_scene);
        if (error != ESP_OK) {
            ESP_LOGW(TAG, "Initial scene unavailable: %s", esp_err_to_name(error));
            playing_scene = false;
            render_clock(&settings);
        } else {
            dmd_playback_log_scene(active_scene);
        }
    }

    while (true) {
        dmd_settings_get(&settings);
        if (settings.revision != previous_revision &&
            (settings.color_preset != previous_color_preset ||
             settings.plasma_palette != previous_plasma_palette ||
             (!previous_playback_log_enabled &&
              settings.playback_log_enabled))) {
            dmd_playback_log_theme(&settings);
        }
        previous_color_preset = settings.color_preset;
        previous_plasma_palette = settings.plasma_palette;
        previous_playback_log_enabled = settings.playback_log_enabled;
        time_t now = time(NULL);
        time_t reboot_minute = now / 60;
        if (reboot_minute != previous_reboot_minute ||
            settings.revision != previous_revision) {
            previous_reboot_minute = reboot_minute;
            if (dmd_settings_claim_scheduled_reboot(&settings, now)) {
#if CONFIG_DMD_QEMU
                ESP_LOGW(
                    TAG,
                    "Weekly scheduled reboot simulated; QEMU cannot recover "
                    "its network adapter after esp_restart()");
#else
                ESP_LOGI(TAG, "Weekly scheduled reboot is due");
                vTaskDelay(pdMS_TO_TICKS(250));
                esp_restart();
#endif
            }
        }
        bool scheduled_off =
            dmd_settings_screen_scheduled_off(&settings, now);
        if (scheduled_off != previous_scheduled_off) {
            force_render = true;
        }
        monotonic_now = esp_timer_get_time();
        xSemaphoreTake(s_state_lock, portMAX_DELAY);
        if (s_touch_test_request_revision !=
            handled_touch_test_request_revision) {
            handled_touch_test_request_revision =
                s_touch_test_request_revision;
            touch_test_started_at =
                monotonic_now < startup_network_status_until
                    ? startup_network_status_until
                    : monotonic_now;
            touch_test_until =
                touch_test_started_at +
                TOUCH_TEST_TARGET_COUNT * TOUCH_TEST_TARGET_US;
            touch_test_result_until =
                touch_test_until + TOUCH_TEST_RESULT_US;
            touch_test_start_events_captured = false;
            force_render = true;
        }
        if (s_setup_qr_request_revision !=
            handled_setup_qr_request_revision) {
            handled_setup_qr_request_revision =
                s_setup_qr_request_revision;
            setup_qr_until =
                (monotonic_now < startup_network_status_until
                    ? startup_network_status_until
                    : monotonic_now) +
                SETUP_QR_VISIBLE_US;
            force_render = true;
        }
        xSemaphoreGive(s_state_lock);
        dmd_network_info_t network = {0};
        dmd_network_get_info(&network);
        bool startup_network_status_visible =
            monotonic_now < startup_network_status_until;
        bool touch_test_visible =
            monotonic_now >= touch_test_started_at &&
            monotonic_now < touch_test_until;
        bool touch_test_result_visible =
            monotonic_now >= touch_test_until &&
            monotonic_now < touch_test_result_until;
        bool setup_qr_visible =
            monotonic_now >= startup_network_status_until &&
            monotonic_now < setup_qr_until;
        uint8_t touch_test_target = 0;
        uint8_t touch_test_countdown = 0;
        if (touch_test_visible) {
            int64_t touch_test_elapsed =
                monotonic_now - touch_test_started_at;
            touch_test_target =
                (uint8_t)(touch_test_elapsed / TOUCH_TEST_TARGET_US);
            int64_t target_elapsed =
                touch_test_elapsed % TOUCH_TEST_TARGET_US;
            touch_test_countdown =
                (uint8_t)((TOUCH_TEST_TARGET_US - target_elapsed +
                           999999) /
                          1000000);
        }
        bool startup_network_status_changed =
            startup_network_status_visible !=
                previous_startup_network_status_visible ||
            network.station_connected != previous_station_connected ||
            strcmp(network.station_ip, previous_station_ip) != 0;
        bool touch_test_changed =
            touch_test_visible != previous_touch_test_visible ||
            touch_test_result_visible !=
                previous_touch_test_result_visible ||
            touch_test_target != previous_touch_test_target ||
            touch_test_countdown != previous_touch_test_countdown;
        if (startup_network_status_changed ||
            touch_test_changed ||
            setup_qr_visible != previous_setup_qr_visible) {
            force_render = true;
        }
        dmd_touch_diagnostics_t touch_diagnostics = {0};
        dmd_board_get_touch_diagnostics(&touch_diagnostics);
        if (touch_test_visible && !touch_test_start_events_captured) {
            touch_test_start_events = touch_diagnostics.event_count;
            touch_test_start_events_captured = true;
        }
        bool schedule_override_active =
            monotonic_now < schedule_awake_until;
        bool normal_touch_controls =
            !startup_network_status_visible &&
            !setup_qr_visible &&
            !touch_test_visible &&
            !touch_test_result_visible;
        uint16_t touch_x = 0;
        uint16_t touch_y = 0;
        if (handle_touch(
                monotonic_now,
                normal_touch_controls,
                &touch_x,
                &touch_y)) {
            if (normal_touch_controls) {
                schedule_awake_until =
                    monotonic_now + TOUCH_SCHEDULE_OVERRIDE_US;
                schedule_override_active = true;
            }
            force_render = true;
            dmd_board_get_touch_diagnostics(&touch_diagnostics);
        }
        if (schedule_override_active !=
            previous_schedule_override_active) {
            force_render = true;
        }
        uint8_t current_controls_opacity = controls_opacity(monotonic_now);
        if (current_controls_opacity != previous_controls_opacity) {
            force_render = true;
        }
        if (settings.color_preset == DMD_COLOR_PLASMA &&
            monotonic_now >= next_plasma_frame_at) {
            uint8_t next_phase = dmd_plasma_phase_at_ms(
                (uint64_t)(monotonic_now / 1000),
                settings.plasma_cycle_ms);
            if (next_phase != plasma_phase) {
                plasma_phase = next_phase;
                force_render = true;
            }
            next_plasma_frame_at = monotonic_now + 33333;
        }

        bool command_pending = false;
        bool command_play_scene = false;
        uint16_t command_scene_index = 0;
        xSemaphoreTake(s_state_lock, portMAX_DELAY);
        if (s_command_revision != handled_command_revision) {
            handled_command_revision = s_command_revision;
            command_pending = true;
            command_play_scene = s_command_play_scene;
            command_scene_index = s_command_scene_index;
        }
        xSemaphoreGive(s_state_lock);

        if (command_pending) {
            animations_remaining = 0;
            waiting_for_scene = false;
            playing_scene = command_play_scene;
            scene_step = 0;
            if (playing_scene) {
                active_scene = command_scene_index;
                esp_err_t error = dmd_scene_select(active_scene);
                if (error == ESP_OK) {
                    dmd_playback_log_scene(active_scene);
                    next_scene_frame_at = 0;
                } else {
                    ESP_LOGW(
                        TAG,
                        "Requested scene unavailable: %s",
                        esp_err_to_name(error));
                    playing_scene = false;
                    render_clock(&settings);
                }
            } else {
                next_mode_at =
                    monotonic_now +
                    (int64_t)settings.clock_display_seconds * 1000000;
            }
            force_render = true;
        }

        if (!playing_scene && monotonic_now >= next_mode_at) {
            if (waiting_for_scene) {
                waiting_for_scene = false;
            } else if (
                settings.automatic_cycle &&
                dmd_scene_count() > 0) {
                animations_remaining = settings.animations_per_cycle;
            }
            if (animations_remaining > 0) {
                active_scene = next_automatic_scene(
                    active_scene,
                    settings.random_playback);
                animations_remaining--;
                esp_err_t error = dmd_scene_select(active_scene);
                if (error == ESP_OK) {
                    playing_scene = true;
                    dmd_playback_log_scene(active_scene);
                    scene_step = 0;
                    next_scene_frame_at = 0;
                } else {
                    ESP_LOGW(
                        TAG,
                        "Automatic scene unavailable: %s",
                        esp_err_to_name(error));
                    playing_scene = false;
                    animations_remaining = 0;
                    render_clock(&settings);
                    next_mode_at =
                        monotonic_now +
                        (int64_t)settings.clock_display_seconds * 1000000;
                }
                force_render = true;
            } else {
                next_mode_at =
                    monotonic_now +
                    (int64_t)settings.clock_display_seconds * 1000000;
            }
        }

        dmd_scene_info_t scene;
        dmd_scene_get_info(&scene);
        bool visible_clock_tick_changed =
            settings.show_seconds
                ? now != previous_second
                : now / 60 != previous_second / 60;
        if (playing_scene && monotonic_now >= next_scene_frame_at) {
            if (scene_step >= scene.step_count) {
                playing_scene = false;
                scene_step = 0;
                render_clock(&settings);
                if (animations_remaining > 0) {
                    waiting_for_scene = true;
                    next_mode_at =
                        monotonic_now +
                        (int64_t)settings.animation_gap_seconds * 1000000;
                } else {
                    waiting_for_scene = false;
                    next_mode_at =
                        monotonic_now +
                        (int64_t)settings.clock_display_seconds * 1000000;
                }
                force_render = true;
            } else {
                dmd_scene_step_info_t step_info;
                ESP_ERROR_CHECK(
                    dmd_scene_decode_step(
                        scene_step,
                        s_dmd,
                        s_scene_mask,
                        &step_info));
                scene_frame = step_info.frame_index;
                if (dmd_settings_time_is_valid()) {
                    overlay_scene_clock(
                        &settings,
                        &scene,
                        step_info.clock_above,
                        now);
                }
                next_scene_frame_at =
                    monotonic_now + (int64_t)step_info.duration_ms * 1000;
                scene_step++;
                force_render = true;
            }
        } else if (
            !playing_scene &&
            (force_render || visible_clock_tick_changed ||
             settings.revision != previous_revision)) {
            render_clock(&settings);
            force_render = true;
        } else if (settings.revision != previous_revision) {
            force_render = true;
        }

        if (force_render && settings.color_preset == DMD_COLOR_PLASMA) {
            plasma_frames_rendered++;
        }
        uint32_t schedule_override_seconds_remaining =
            schedule_override_active
                ? (uint32_t)(
                    (schedule_awake_until - monotonic_now + 999999) /
                    1000000)
                : 0;
        publish_state(
            playing_scene,
            waiting_for_scene,
            active_scene,
            scene_step,
            scene_frame,
            animations_remaining,
            plasma_phase,
            plasma_frames_rendered,
            display_frames_rendered,
            schedule_override_seconds_remaining,
            touch_test_visible || touch_test_result_visible);
        if (startup_network_status_visible) {
            if (!startup_network_status_painted ||
                startup_network_status_changed ||
                settings.revision != previous_revision) {
                paint_startup_network_status(&settings, &network);
                refresh_display();
                display_frames_rendered++;
                startup_network_status_painted = true;
            }
            force_render = false;
        } else if (setup_qr_visible) {
            if (force_render) {
                paint_setup_qr(&settings, &network);
                refresh_display();
                display_frames_rendered++;
            }
            force_render = false;
        } else if (touch_test_visible) {
            if (force_render) {
                paint_touch_test(
                    &settings,
                    touch_test_target,
                    touch_test_countdown,
                    touch_diagnostics.event_count -
                        touch_test_start_events,
                    &touch_diagnostics);
                refresh_display();
                display_frames_rendered++;
            }
            force_render = false;
        } else if (touch_test_result_visible) {
            if (force_render) {
                paint_touch_test_result(
                    &settings,
                    touch_diagnostics.event_count -
                        touch_test_start_events);
                refresh_display();
                display_frames_rendered++;
            }
            force_render = false;
        } else if (force_render) {
            paint_dmd(
                &settings,
                &s_state,
                &scene,
                now,
                schedule_override_active,
                current_controls_opacity,
                plasma_phase);
            refresh_display();
            display_frames_rendered++;
            force_render = false;
        }
        previous_second = now;
        previous_scheduled_off = scheduled_off;
        previous_schedule_override_active =
            schedule_override_active;
        previous_revision = settings.revision;
        previous_controls_opacity = current_controls_opacity;
        previous_startup_network_status_visible =
            startup_network_status_visible;
        previous_touch_test_visible = touch_test_visible;
        previous_touch_test_result_visible = touch_test_result_visible;
        previous_setup_qr_visible = setup_qr_visible;
        previous_touch_test_target = touch_test_target;
        previous_touch_test_countdown = touch_test_countdown;
        previous_station_connected = network.station_connected;
        strlcpy(
            previous_station_ip,
            network.station_ip,
            sizeof(previous_station_ip));
        vTaskDelay(pdMS_TO_TICKS(5));
    }
}
