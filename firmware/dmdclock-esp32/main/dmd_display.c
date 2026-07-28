#include "dmd_display.h"

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

#include "dmd_actions.h"
#include "dmd_board.h"
#include "dmd_color.h"
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

static const char *TAG = "dmd_display";
static esp_lcd_panel_handle_t s_panel;
static uint16_t *s_framebuffer;
static uint8_t s_dmd[DMD_WIDTH * DMD_HEIGHT];
static uint8_t s_clock_dmd[DMD_WIDTH * DMD_HEIGHT];
static uint8_t s_scene_mask[DMD_WIDTH * DMD_HEIGHT];
static dmd_rgb_t s_plasma_palette[DMD_PLASMA_PALETTE_SIZE];
static dmd_plasma_palette_t s_cached_plasma_palette = UINT8_MAX;
static dmd_rgb_t s_cached_plasma_custom[DMD_PLASMA_STOP_COUNT];
static SemaphoreHandle_t s_state_lock;
static dmd_display_state_t s_state;
static uint32_t s_command_revision;
static bool s_command_play_scene;
static uint8_t s_command_scene_index;
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
    for (size_t index = 0; index < sizeof(GLYPHS) / sizeof(GLYPHS[0]); index++) {
        if (GLYPHS[index].character == character) {
            return &GLYPHS[index];
        }
    }
    return &GLYPHS[11];
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

static void draw_button(
    int x,
    int width,
    const char *label,
    uint16_t accent,
    uint8_t opacity)
{
    const int y = 400;
    const int height = 56;
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

static void draw_screen_chrome(
    const dmd_settings_t *settings,
    const dmd_scene_info_t *scene,
    uint8_t controls_opacity_value)
{
    dmd_rgb_t rgb = dmd_color_at(settings->color_preset, 64, 16);
    uint16_t accent = rgb565(rgb.red, rgb.green, rgb.blue);

    if (settings->show_information) {
        dmd_scene_metadata_t metadata;
        dmd_scene_get_metadata(scene->index, &metadata);
        char source[256];
        char info[256];
        int information_y = 50;
        if (metadata.game[0] != '\0') {
            snprintf(source, sizeof(source), "PINBALL  %s", metadata.game);
            uppercase_copy(info, sizeof(info), source);
            draw_lcd_text_fit(
                info,
                20,
                information_y,
                2,
                LCD_WIDTH - 40,
                accent);
            information_y += 24;
        }
        if (metadata.title[0] != '\0') {
            snprintf(source, sizeof(source), "SCENE  %s", metadata.title);
            uppercase_copy(info, sizeof(info), source);
            draw_lcd_text_fit(
                info,
                20,
                information_y,
                2,
                LCD_WIDTH - 40,
                accent);
            information_y += 24;
        }

        if (metadata.year > 0 && metadata.manufacturer[0] != '\0') {
            snprintf(
                source,
                sizeof(source),
                "YEAR  %u    MANUFACTURER  %s",
                metadata.year,
                metadata.manufacturer);
        } else if (metadata.year > 0) {
            snprintf(source, sizeof(source), "YEAR  %u", metadata.year);
        } else if (metadata.manufacturer[0] != '\0') {
            snprintf(
                source,
                sizeof(source),
                "MANUFACTURER  %s",
                metadata.manufacturer);
        } else {
            source[0] = '\0';
        }
        if (source[0] != '\0') {
            uppercase_copy(info, sizeof(info), source);
            draw_lcd_text_fit(
                info,
                20,
                information_y,
                2,
                LCD_WIDTH - 40,
                accent);
        }
    }

    if (controls_opacity_value > 0) {
        draw_button(10, 148, "COLOR -", accent, controls_opacity_value);
        draw_button(168, 148, "COLOR +", accent, controls_opacity_value);
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
        draw_button(642, 148, "SYNC NTP", accent, controls_opacity_value);
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
    draw_screen_chrome(
        settings,
        scene,
        controls_opacity_value);
    for (int dmd_y = 0; dmd_y < DMD_HEIGHT; dmd_y++) {
        for (int dmd_x = 0; dmd_x < DMD_WIDTH; dmd_x++) {
            uint8_t intensity = s_dmd[dmd_y * DMD_WIDTH + dmd_x];
            dmd_rgb_t theme_color =
                settings->color_preset == DMD_COLOR_PLASMA
                    ? s_plasma_palette[dmd_plasma_palette_index(
                        (uint8_t)dmd_x,
                        (uint8_t)dmd_y,
                        plasma_phase)]
                    : dmd_color_at(
                        settings->color_preset,
                        (uint8_t)dmd_x,
                        (uint8_t)dmd_y);
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
#endif
}

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
        .num_fbs = 1,
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
    ESP_RETURN_ON_ERROR(
        esp_lcd_rgb_panel_get_frame_buffer(s_panel, 1, (void **)&s_framebuffer),
        TAG,
        "get framebuffer");

#endif
    s_state_lock = xSemaphoreCreateMutex();
    if (s_state_lock == NULL) {
        return ESP_ERR_NO_MEM;
    }
    memset(&s_state, 0, sizeof(s_state));
    memset(s_framebuffer, 0, LCD_WIDTH * LCD_HEIGHT * sizeof(uint16_t));
    refresh_display();
    return ESP_OK;
}

void dmd_display_play_scene(uint8_t scene_index)
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
    uint8_t scene_index,
    uint16_t scene_step,
    uint16_t scene_frame,
    uint8_t animations_remaining,
    uint8_t plasma_phase,
    uint32_t plasma_frames_rendered,
    uint32_t schedule_override_seconds_remaining)
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
    s_state.schedule_override_seconds_remaining =
        schedule_override_seconds_remaining;
    xSemaphoreGive(s_state_lock);
}

static uint8_t next_automatic_scene(
    uint8_t current,
    bool random_playback)
{
    if (!random_playback || dmd_scene_count() <= 1) {
        return (current + 1) % dmd_scene_count();
    }
    uint8_t next = current;
    while (next == current) {
        next = (uint8_t)(esp_random() % dmd_scene_count());
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

static bool handle_touch(int64_t now)
{
    static int64_t last_touch_at;
    uint16_t x;
    uint16_t y;
    if (!dmd_board_read_touch(&x, &y) ||
        now - last_touch_at < 350000) {
        return false;
    }

    bool controls_hidden = controls_opacity(now) == 0;
    last_touch_at = now;
    s_controls_last_interaction_at = now;
    if (controls_hidden || y < 390) {
        return true;
    }

    if (x < 160) {
        dmd_action_execute(DMD_ACTION_COLOR_PREVIOUS);
    } else if (x < 320) {
        dmd_action_execute(DMD_ACTION_COLOR_NEXT);
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
    dmd_settings_t settings;
    dmd_settings_get(&settings);

    bool playing_scene = settings.play_scene;
    bool waiting_for_scene = false;
    uint8_t active_scene = settings.scene_index;
    uint8_t animations_remaining = 0;
    uint16_t scene_step = 0;
    uint16_t scene_frame = 0;
    uint32_t previous_revision = 0;
    uint32_t handled_command_revision = 0;
    time_t previous_second = 0;
    time_t previous_reboot_minute = -1;
    int64_t schedule_awake_until = 0;
    bool previous_schedule_override_active = false;
    bool previous_scheduled_off = false;
    int64_t monotonic_now = esp_timer_get_time();
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
    bool force_render = true;

    if (playing_scene) {
        esp_err_t error = dmd_scene_select(active_scene);
        if (error != ESP_OK) {
            ESP_LOGW(TAG, "Initial scene unavailable: %s", esp_err_to_name(error));
            playing_scene = false;
            render_clock(&settings);
        }
    }

    while (true) {
        dmd_settings_get(&settings);
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
        bool schedule_override_active =
            monotonic_now < schedule_awake_until;
        if (handle_touch(monotonic_now)) {
            schedule_awake_until =
                monotonic_now + TOUCH_SCHEDULE_OVERRIDE_US;
            schedule_override_active = true;
            force_render = true;
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
        uint8_t command_scene_index = 0;
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
            } else if (settings.automatic_cycle) {
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
            (force_render || now != previous_second ||
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
            schedule_override_seconds_remaining);
        if (force_render) {
            paint_dmd(
                &settings,
                &s_state,
                &scene,
                now,
                schedule_override_active,
                current_controls_opacity,
                plasma_phase);
            refresh_display();
            force_render = false;
        }
        previous_second = now;
        previous_scheduled_off = scheduled_off;
        previous_schedule_override_active =
            schedule_override_active;
        previous_revision = settings.revision;
        previous_controls_opacity = current_controls_opacity;
        vTaskDelay(pdMS_TO_TICKS(5));
    }
}
