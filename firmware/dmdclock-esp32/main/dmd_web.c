#include "dmd_web.h"

#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <time.h>

#include "cJSON.h"
#include "dmd_actions.h"
#include "dmd_board.h"
#include "dmd_display.h"
#include "dmd_diagnostics.h"
#include "dmd_mqtt.h"
#include "dmd_network.h"
#include "dmd_playback_log.h"
#include "dmd_scene.h"
#include "dmd_settings.h"
#include "esp_app_desc.h"
#include "esp_http_server.h"
#include "esp_log.h"
#include "esp_netif.h"
#include "esp_timer.h"
#include "lwip/inet.h"
#include "lwip/sockets.h"

static const char *TAG = "dmd_web";
static httpd_handle_t s_server;

static bool local_ipv4(uint32_t address)
{
    uint32_t host_address = ntohl(address);
    if ((host_address & 0xff000000U) == 0x7f000000U ||
        (host_address & 0xffff0000U) == 0xa9fe0000U) {
        return true;
    }

    static const char *const interface_keys[] = {
        "WIFI_STA_DEF",
        "WIFI_AP_DEF",
        "ETH_DEF",
    };
    for (size_t index = 0;
         index < sizeof(interface_keys) / sizeof(interface_keys[0]);
         index++) {
        esp_netif_t *network =
            esp_netif_get_handle_from_ifkey(interface_keys[index]);
        esp_netif_ip_info_t info;
        if (network != NULL &&
            esp_netif_get_ip_info(network, &info) == ESP_OK &&
            info.ip.addr != 0 &&
            info.netmask.addr != 0 &&
            (address & info.netmask.addr) ==
                (info.ip.addr & info.netmask.addr)) {
            return true;
        }
    }
    return false;
}

static bool local_web_client(const struct sockaddr_storage *peer)
{
    if (peer->ss_family == AF_INET) {
        const struct sockaddr_in *ipv4 =
            (const struct sockaddr_in *)peer;
        return local_ipv4(ipv4->sin_addr.s_addr);
    }
#if LWIP_IPV6
    if (peer->ss_family == AF_INET6) {
        const struct sockaddr_in6 *ipv6 =
            (const struct sockaddr_in6 *)peer;
        const uint8_t *bytes = ipv6->sin6_addr.s6_addr;
        if (IN6_IS_ADDR_LOOPBACK(&ipv6->sin6_addr) ||
            IN6_IS_ADDR_LINKLOCAL(&ipv6->sin6_addr)) {
            return true;
        }
        if (IN6_IS_ADDR_V4MAPPED(&ipv6->sin6_addr)) {
            uint32_t mapped = 0;
            memcpy(&mapped, bytes + 12, sizeof(mapped));
            return local_ipv4(mapped);
        }
    }
#endif
    return false;
}

static esp_err_t web_client_open(httpd_handle_t server, int socket_fd)
{
    (void)server;
    dmd_settings_t settings;
    dmd_settings_get(&settings);
    if (!settings.lan_only_web) {
        return ESP_OK;
    }

    struct sockaddr_storage peer = {0};
    socklen_t peer_length = sizeof(peer);
    if (getpeername(
            socket_fd,
            (struct sockaddr *)&peer,
            &peer_length) == 0 &&
        local_web_client(&peer)) {
        return ESP_OK;
    }

    ESP_LOGW(
        TAG,
        "Rejected non-local web connection (LAN-only web access is enabled)");
    return ESP_FAIL;
}

extern const uint8_t index_html_start[] asm("_binary_index_html_start");
extern const uint8_t index_html_end[] asm("_binary_index_html_end");
extern const uint8_t api_html_start[] asm("_binary_api_html_start");
extern const uint8_t api_html_end[] asm("_binary_api_html_end");
extern const uint8_t dmdclock_ico_start[] asm("_binary_dmdclock_ico_start");
extern const uint8_t dmdclock_ico_end[] asm("_binary_dmdclock_ico_end");

static esp_err_t send_json(httpd_req_t *request, cJSON *json)
{
    char *body = cJSON_PrintUnformatted(json);
    cJSON_Delete(json);
    if (body == NULL) {
        return httpd_resp_send_err(
            request,
            HTTPD_500_INTERNAL_SERVER_ERROR,
            "JSON allocation failed");
    }
    httpd_resp_set_type(request, "application/json");
    httpd_resp_set_hdr(request, "Cache-Control", "no-store");
    esp_err_t error = httpd_resp_sendstr(request, body);
    free(body);
    return error;
}

static cJSON *receive_json(httpd_req_t *request)
{
    if (request->content_len <= 0 || request->content_len > 2048) {
        return NULL;
    }
    char *body = calloc(1, request->content_len + 1);
    if (body == NULL) {
        return NULL;
    }

    size_t received = 0;
    while (received < request->content_len) {
        int result = httpd_req_recv(
            request,
            body + received,
            request->content_len - received);
        if (result <= 0) {
            free(body);
            return NULL;
        }
        received += result;
    }
    cJSON *json = cJSON_Parse(body);
    free(body);
    return json;
}

static void add_rgb_array(
    cJSON *json,
    const char *name,
    const dmd_rgb_t *colors,
    uint8_t count)
{
    cJSON *array = cJSON_AddArrayToObject(json, name);
    for (uint8_t index = 0; index < count; index++) {
        char value[8];
        snprintf(
            value,
            sizeof(value),
            "#%02X%02X%02X",
            colors[index].red,
            colors[index].green,
            colors[index].blue);
        cJSON_AddItemToArray(array, cJSON_CreateString(value));
    }
}

static void add_rgb_value(
    cJSON *json,
    const char *name,
    dmd_rgb_t color)
{
    char value[8];
    snprintf(
        value,
        sizeof(value),
        "#%02X%02X%02X",
        color.red,
        color.green,
        color.blue);
    cJSON_AddStringToObject(json, name, value);
}

static esp_err_t index_get(httpd_req_t *request)
{
    httpd_resp_set_type(request, "text/html; charset=utf-8");
    httpd_resp_set_hdr(request, "Cache-Control", "no-cache");
    return httpd_resp_send(
        request,
        (const char *)index_html_start,
        index_html_end - index_html_start);
}

static esp_err_t state_get(httpd_req_t *request)
{
    dmd_settings_t settings;
    dmd_settings_get(&settings);
    dmd_network_info_t network;
    dmd_network_get_info(&network);
    dmd_scene_info_t scene;
    dmd_scene_get_info(&scene);
    dmd_display_state_t display;
    dmd_display_get_state(&display);
    dmd_touch_diagnostics_t touch;
    dmd_board_get_touch_diagnostics(&touch);
    dmd_diagnostics_t diagnostics;
    dmd_diagnostics_get(&diagnostics);
    dmd_mqtt_info_t mqtt;
    dmd_mqtt_get_info(&mqtt);
    const esp_app_desc_t *app = esp_app_get_description();
    uint64_t uptime_seconds =
        (uint64_t)(esp_timer_get_time() / 1000000);

    time_t now = time(NULL);
    struct tm local;
    localtime_r(&now, &local);
    bool time_valid = dmd_settings_time_is_valid();
    char time_text[24] = "--:--";
    char date_time_text[32] = "Not synchronized";
    if (time_valid) {
        const char *format = settings.show_seconds
            ? (settings.use_24_hour ? "%H:%M:%S" : "%I:%M:%S")
            : (settings.use_24_hour ? "%H:%M" : "%I:%M");
        strftime(time_text, sizeof(time_text), format, &local);
        if (!settings.use_24_hour && time_text[0] == '0') {
            memmove(time_text, time_text + 1, strlen(time_text));
        }
        strftime(
            date_time_text,
            sizeof(date_time_text),
            "%Y-%m-%d %H:%M:%S",
            &local);
    }

    cJSON *json = cJSON_CreateObject();
    cJSON_AddNumberToObject(json, "brightness", settings.brightness);
    cJSON_AddNumberToObject(json, "glowStrength", settings.glow_strength);
    cJSON_AddNumberToObject(json, "plasmaPalette", settings.plasma_palette);
    cJSON_AddStringToObject(
        json,
        "plasmaPaletteName",
        dmd_plasma_palette_name(settings.plasma_palette));
    cJSON_AddNumberToObject(
        json,
        "plasmaCycleMilliseconds",
        settings.plasma_cycle_ms);
    add_rgb_array(
        json,
        "plasmaCustomColors",
        settings.plasma_custom,
        DMD_PLASMA_STOP_COUNT);
    add_rgb_array(json, "basicCustomColors", &settings.basic_custom, 1);
    add_rgb_array(
        json,
        "gradientCustomColors",
        settings.gradient_custom,
        DMD_GRADIENT_CUSTOM_COLOR_COUNT);
    add_rgb_array(
        json,
        "rasterCustomColors",
        settings.raster_custom,
        DMD_RASTER_CUSTOM_COLOR_COUNT);
    cJSON_AddBoolToObject(json, "use24Hour", settings.use_24_hour);
    cJSON_AddBoolToObject(json, "showSeconds", settings.show_seconds);
    cJSON_AddBoolToObject(json, "displayOn", settings.display_on);
    cJSON_AddBoolToObject(
        json,
        "screenScheduleEnabled",
        settings.screen_schedule_enabled);
    cJSON_AddBoolToObject(
        json,
        "screenScheduledOff",
        dmd_settings_screen_scheduled_off(&settings, now));
    cJSON_AddBoolToObject(
        json,
        "rebootScheduleEnabled",
        settings.reboot_schedule_enabled);
    cJSON_AddNumberToObject(
        json,
        "rebootWeekday",
        settings.reboot_weekday);
    cJSON_AddNumberToObject(
        json,
        "rebootHour",
        settings.reboot_hour);
    cJSON_AddNumberToObject(
        json,
        "rebootMinute",
        settings.reboot_minute);
    cJSON_AddNumberToObject(
        json,
        "deviceWeekday",
        time_valid ? local.tm_wday : -1);
    cJSON_AddNumberToObject(
        json,
        "deviceHour",
        time_valid ? local.tm_hour : -1);
    cJSON *screen_schedule =
        cJSON_AddArrayToObject(json, "screenOffSchedule");
    for (uint8_t day = 0; day < DMD_SCHEDULE_DAY_COUNT; day++) {
        char hours[DMD_SCHEDULE_HOUR_COUNT + 1];
        for (uint8_t hour = 0; hour < DMD_SCHEDULE_HOUR_COUNT; hour++) {
            size_t slot =
                (size_t)day * DMD_SCHEDULE_HOUR_COUNT + hour;
            hours[hour] =
                (settings.screen_off_schedule[slot / 8] &
                 (uint8_t)(1U << (slot % 8))) != 0
                    ? '1'
                    : '0';
        }
        hours[DMD_SCHEDULE_HOUR_COUNT] = '\0';
        cJSON_AddItemToArray(
            screen_schedule,
            cJSON_CreateString(hours));
    }
    cJSON_AddBoolToObject(json, "playScene", display.playing_scene);
    cJSON_AddBoolToObject(json, "waitingForScene", display.waiting_for_scene);
    cJSON_AddNumberToObject(json, "sceneIndex", display.scene_index);
    cJSON_AddNumberToObject(json, "sceneStep", display.scene_step);
    cJSON_AddNumberToObject(json, "sceneFrame", display.scene_frame);
    cJSON_AddNumberToObject(
        json,
        "animationsRemaining",
        display.animations_remaining);
    cJSON_AddNumberToObject(json, "plasmaPhase", display.plasma_phase);
    cJSON_AddNumberToObject(
        json,
        "plasmaFramesRendered",
        display.plasma_frames_rendered);
    cJSON_AddNumberToObject(
        json,
        "displayFramesRendered",
        display.display_frames_rendered);
    cJSON_AddBoolToObject(
        json,
        "touchTestRunning",
        display.touch_test_running);
    cJSON_AddNumberToObject(
        json,
        "scheduleOverrideSecondsRemaining",
        display.schedule_override_seconds_remaining);
    cJSON_AddBoolToObject(json, "automaticCycle", settings.automatic_cycle);
    cJSON_AddBoolToObject(json, "randomPlayback", settings.random_playback);
    cJSON_AddBoolToObject(
        json,
        "playbackLogEnabled",
        settings.playback_log_enabled);
    cJSON_AddStringToObject(
        json,
        "playbackLogPath",
        DMD_PLAYBACK_LOG_PATH);
    struct stat playback_log_stat;
    bool playback_log_present =
        stat(DMD_PLAYBACK_LOG_PATH, &playback_log_stat) == 0;
    cJSON_AddBoolToObject(
        json,
        "playbackLogPresent",
        playback_log_present);
    cJSON_AddNumberToObject(
        json,
        "playbackLogBytes",
        playback_log_present ? (double)playback_log_stat.st_size : 0);
    cJSON_AddBoolToObject(json, "showInformation", settings.show_information);
    cJSON_AddNumberToObject(
        json,
        "informationColorMode",
        settings.information_color_mode);
    add_rgb_value(
        json,
        "informationCustomColor",
        settings.information_custom_color);
    cJSON_AddNumberToObject(
        json,
        "animationsPerCycle",
        settings.animations_per_cycle);
    cJSON_AddNumberToObject(
        json,
        "clockDisplaySeconds",
        settings.clock_display_seconds);
    cJSON_AddNumberToObject(
        json,
        "animationGapSeconds",
        settings.animation_gap_seconds);
    cJSON_AddStringToObject(json, "timezone", settings.timezone);
    cJSON_AddStringToObject(json, "wifiSsid", settings.wifi_ssid);
    cJSON_AddBoolToObject(json, "lanOnlyWeb", settings.lan_only_web);
    cJSON_AddBoolToObject(json, "mqttEnabled", settings.mqtt_enabled);
    cJSON_AddStringToObject(json, "mqttHost", settings.mqtt_host);
    cJSON_AddNumberToObject(json, "mqttPort", settings.mqtt_port);
    cJSON_AddStringToObject(json, "mqttUsername", settings.mqtt_username);
    cJSON_AddStringToObject(
        json,
        "mqttDiscoveryPrefix",
        settings.mqtt_discovery_prefix);
    cJSON_AddBoolToObject(json, "mqttConfigured", mqtt.configured);
    cJSON_AddBoolToObject(json, "mqttConnected", mqtt.connected);
    cJSON_AddNumberToObject(json, "mqttConnectCount", mqtt.connect_count);
    cJSON_AddNumberToObject(
        json,
        "mqttDisconnectCount",
        mqtt.disconnect_count);
    cJSON_AddNumberToObject(json, "mqttCommandCount", mqtt.command_count);
    cJSON_AddNumberToObject(json, "mqttErrorCount", mqtt.error_count);
    cJSON_AddBoolToObject(json, "wifiConnected", network.station_connected);
    cJSON_AddStringToObject(json, "stationIp", network.station_ip);
    cJSON_AddStringToObject(json, "deviceName", network.device_name);
    cJSON_AddStringToObject(json, "accessPointSsid", network.access_point_ssid);
    cJSON_AddStringToObject(json, "accessPointIp", network.access_point_ip);
    cJSON_AddBoolToObject(json, "timeValid", time_valid);
    cJSON_AddStringToObject(json, "time", time_text);
    cJSON_AddStringToObject(json, "deviceDateTime", date_time_text);
    cJSON_AddNumberToObject(json, "epoch", (double)now);
    cJSON_AddStringToObject(json, "buildNumber", app->version);
    cJSON_AddNumberToObject(
        json,
        "uptimeSeconds",
        (double)uptime_seconds);
    cJSON_AddBoolToObject(
        json,
        "chipTemperatureAvailable",
        diagnostics.chip_temperature_available);
    if (diagnostics.chip_temperature_available) {
        cJSON_AddNumberToObject(
            json,
            "chipTemperatureCelsius",
            diagnostics.chip_temperature_c);
    } else {
        cJSON_AddNullToObject(json, "chipTemperatureCelsius");
    }
    cJSON_AddStringToObject(
        json,
        "chipTemperatureType",
        "Internal approximate; not ambient");
    cJSON_AddBoolToObject(
        json,
        "wifiRssiAvailable",
        diagnostics.wifi_rssi_available);
    if (diagnostics.wifi_rssi_available) {
        cJSON_AddNumberToObject(
            json,
            "wifiRssiDbm",
            diagnostics.wifi_rssi_dbm);
    } else {
        cJSON_AddNullToObject(json, "wifiRssiDbm");
    }
    cJSON_AddNumberToObject(
        json,
        "freeHeapBytes",
        diagnostics.free_heap_bytes);
    cJSON_AddNumberToObject(
        json,
        "minimumFreeHeapBytes",
        diagnostics.minimum_free_heap_bytes);
    cJSON_AddNumberToObject(
        json,
        "freePsramBytes",
        diagnostics.free_psram_bytes);
    cJSON_AddNumberToObject(
        json,
        "totalPsramBytes",
        diagnostics.total_psram_bytes);
    cJSON_AddBoolToObject(json, "sdAvailable", diagnostics.sd_available);
    cJSON_AddNumberToObject(
        json,
        "sdTotalBytes",
        (double)diagnostics.sd_total_bytes);
    cJSON_AddNumberToObject(
        json,
        "sdFreeBytes",
        (double)diagnostics.sd_free_bytes);
    cJSON_AddNumberToObject(
        json,
        "sdUsedBytes",
        (double)(diagnostics.sd_total_bytes -
                 diagnostics.sd_free_bytes));
    cJSON_AddBoolToObject(
        json,
        "settingsFilePresent",
        diagnostics.settings_file_present);
    cJSON_AddStringToObject(
        json,
        "settingsFilePath",
        "/dmd/config/settings.json");
    cJSON_AddNumberToObject(
        json,
        "flashSizeBytes",
        diagnostics.flash_size_bytes);
    cJSON_AddNumberToObject(
        json,
        "cpuFrequencyMHz",
        diagnostics.cpu_frequency_mhz);
    cJSON_AddNumberToObject(json, "bootCount", diagnostics.boot_count);
    cJSON_AddStringToObject(
        json,
        "resetReason",
        diagnostics.reset_reason);
    cJSON_AddBoolToObject(
        json,
        "settingsSaveOk",
        diagnostics.last_nvs_save_error == ESP_OK &&
        diagnostics.last_sd_save_error == ESP_OK);
    cJSON_AddStringToObject(
        json,
        "lastNvsSaveStatus",
        esp_err_to_name(diagnostics.last_nvs_save_error));
    cJSON_AddStringToObject(
        json,
        "lastSdSaveStatus",
        esp_err_to_name(diagnostics.last_sd_save_error));
    cJSON_AddBoolToObject(json, "ntpStarted", network.ntp_started);
    cJSON_AddBoolToObject(json, "ntpSyncing", network.ntp_syncing);
    cJSON_AddBoolToObject(json, "ntpSynced", network.ntp_synced);
    cJSON_AddNumberToObject(json, "ntpLastSync", (double)network.ntp_last_sync);
    cJSON_AddNumberToObject(
        json,
        "ntpSecondsSinceSync",
        network.ntp_last_sync > 0 && now > network.ntp_last_sync
            ? (double)(now - network.ntp_last_sync)
            : 0);
    cJSON_AddStringToObject(json, "timeSource", network.time_source);
    cJSON_AddStringToObject(
        json,
        "ntpServers",
        "pool.ntp.org, time.cloudflare.com");
    cJSON_AddBoolToObject(json, "touchAvailable", dmd_board_touch_available());
    cJSON_AddNumberToObject(json, "touchEventCount", touch.event_count);
    cJSON_AddNumberToObject(
        json,
        "touchReadErrorCount",
        touch.read_error_count);
    cJSON_AddNumberToObject(json, "touchLastX", touch.last_x);
    cJSON_AddNumberToObject(json, "touchLastY", touch.last_y);
    cJSON_AddNumberToObject(json, "touchLastStatus", touch.last_status);
    cJSON_AddNumberToObject(
        json,
        "touchLastEventMilliseconds",
        touch.last_event_ms);
    cJSON_AddNumberToObject(
        json,
        "touchInterruptLevel",
        touch.interrupt_level);
    cJSON_AddNumberToObject(json, "colorPreset", settings.color_preset);
    cJSON_AddStringToObject(
        json,
        "color",
        dmd_color_name(settings.color_preset));
    cJSON_AddStringToObject(
        json,
        "colorFamily",
        dmd_color_family(settings.color_preset));
    cJSON_AddStringToObject(json, "scene", scene.display_name);
    cJSON_AddStringToObject(json, "sceneFile", scene.file_name);
    dmd_scene_metadata_t active_metadata;
    dmd_scene_get_metadata(scene.index, &active_metadata);
    cJSON_AddStringToObject(json, "sceneTitle", active_metadata.title);
    cJSON_AddStringToObject(json, "sceneGame", active_metadata.game);
    cJSON_AddStringToObject(
        json,
        "sceneManufacturer",
        active_metadata.manufacturer);
    cJSON_AddNumberToObject(json, "sceneYear", active_metadata.year);
    cJSON_AddBoolToObject(
        json,
        "sceneMetadataMatched",
        active_metadata.catalog_match);
    cJSON_AddNumberToObject(json, "sceneCount", dmd_scene_count());
    cJSON_AddNumberToObject(json, "sceneFrames", scene.frame_count);
    cJSON_AddNumberToObject(json, "sceneDelayMs", scene.normal_delay_ms);
    cJSON_AddNumberToObject(json, "revision", settings.revision);
    return send_json(request, json);
}

static esp_err_t api_docs_get(httpd_req_t *request)
{
    httpd_resp_set_type(request, "text/html; charset=utf-8");
    httpd_resp_set_hdr(request, "Cache-Control", "no-cache");
    return httpd_resp_send(
        request,
        (const char *)api_html_start,
        api_html_end - api_html_start);
}

static esp_err_t scenes_get(httpd_req_t *request)
{
    cJSON *json = cJSON_CreateObject();
    cJSON_AddNumberToObject(json, "sceneCount", dmd_scene_count());
    cJSON *scenes = cJSON_AddArrayToObject(json, "scenes");
    for (uint16_t index = 0; index < dmd_scene_count(); index++) {
        dmd_scene_metadata_t metadata;
        dmd_scene_get_metadata(index, &metadata);
        cJSON *entry = cJSON_CreateObject();
        cJSON_AddNumberToObject(entry, "index", index);
        cJSON_AddStringToObject(
            entry,
            "name",
            dmd_scene_display_name(index));
        cJSON_AddStringToObject(
            entry,
            "file",
            dmd_scene_file_name(index));
        cJSON_AddStringToObject(entry, "title", metadata.title);
        cJSON_AddStringToObject(entry, "game", metadata.game);
        cJSON_AddStringToObject(
            entry,
            "manufacturer",
            metadata.manufacturer);
        cJSON_AddNumberToObject(entry, "year", metadata.year);
        cJSON_AddBoolToObject(entry, "metadataMatched", metadata.catalog_match);
        cJSON_AddItemToArray(scenes, entry);
    }
    return send_json(request, json);
}

static void update_bool(cJSON *json, const char *name, bool *value)
{
    cJSON *item = cJSON_GetObjectItemCaseSensitive(json, name);
    if (cJSON_IsBool(item)) {
        *value = cJSON_IsTrue(item);
    }
}

static bool parse_rgb(const char *text, dmd_rgb_t *output)
{
    unsigned red;
    unsigned green;
    unsigned blue;
    if (text == NULL || output == NULL || strlen(text) != 7 ||
        sscanf(text, "#%02x%02x%02x", &red, &green, &blue) != 3) {
        return false;
    }
    output->red = (uint8_t)red;
    output->green = (uint8_t)green;
    output->blue = (uint8_t)blue;
    return true;
}

static bool parse_rgb_array(
    cJSON *json,
    const char *name,
    dmd_rgb_t *output,
    uint8_t count)
{
    cJSON *colors = cJSON_GetObjectItemCaseSensitive(json, name);
    if (colors == NULL) {
        return true;
    }
    if (!cJSON_IsArray(colors) || cJSON_GetArraySize(colors) != count) {
        return false;
    }
    for (uint8_t index = 0; index < count; index++) {
        cJSON *item = cJSON_GetArrayItem(colors, index);
        if (!cJSON_IsString(item) ||
            !parse_rgb(item->valuestring, &output[index])) {
            return false;
        }
    }
    return true;
}

static esp_err_t settings_post(httpd_req_t *request)
{
    cJSON *json = receive_json(request);
    if (json == NULL) {
        return httpd_resp_send_err(
            request,
            HTTPD_400_BAD_REQUEST,
            "Expected a JSON object smaller than 2 KB");
    }

    dmd_settings_t before;
    dmd_settings_get(&before);
    dmd_settings_t updated = before;

    cJSON *brightness = cJSON_GetObjectItemCaseSensitive(json, "brightness");
    if (cJSON_IsNumber(brightness)) {
        int value = brightness->valueint;
        updated.brightness = value < 0 ? 0 : (value > 100 ? 100 : value);
    }
    cJSON *glow = cJSON_GetObjectItemCaseSensitive(json, "glowStrength");
    if (cJSON_IsNumber(glow)) {
        int value = glow->valueint;
        updated.glow_strength = value < 0 ? 0 : (value > 100 ? 100 : value);
    }
    cJSON *plasma_palette =
        cJSON_GetObjectItemCaseSensitive(json, "plasmaPalette");
    if (cJSON_IsNumber(plasma_palette) &&
        dmd_plasma_palette_is_valid((uint8_t)plasma_palette->valueint)) {
        updated.plasma_palette =
            (dmd_plasma_palette_t)plasma_palette->valueint;
    }
    cJSON *plasma_cycle =
        cJSON_GetObjectItemCaseSensitive(json, "plasmaCycleMilliseconds");
    if (cJSON_IsNumber(plasma_cycle)) {
        int value = plasma_cycle->valueint;
        updated.plasma_cycle_ms = (uint16_t)(
            value < DMD_PLASMA_CYCLE_MIN_MS
                ? DMD_PLASMA_CYCLE_MIN_MS
                : (value > DMD_PLASMA_CYCLE_MAX_MS
                    ? DMD_PLASMA_CYCLE_MAX_MS
                    : value));
    }
    if (!parse_rgb_array(
            json,
            "plasmaCustomColors",
            updated.plasma_custom,
            DMD_PLASMA_STOP_COUNT) ||
        !parse_rgb_array(
            json,
            "basicCustomColors",
            &updated.basic_custom,
            1) ||
        !parse_rgb_array(
            json,
            "gradientCustomColors",
            updated.gradient_custom,
            DMD_GRADIENT_CUSTOM_COLOR_COUNT) ||
        !parse_rgb_array(
            json,
            "rasterCustomColors",
            updated.raster_custom,
            DMD_RASTER_CUSTOM_COLOR_COUNT)) {
        cJSON_Delete(json);
        return httpd_resp_send_err(
            request,
            HTTPD_400_BAD_REQUEST,
            "Custom colors must be complete #RRGGBB arrays");
    }
    update_bool(json, "use24Hour", &updated.use_24_hour);
    update_bool(json, "showSeconds", &updated.show_seconds);
    update_bool(json, "displayOn", &updated.display_on);
    update_bool(json, "lanOnlyWeb", &updated.lan_only_web);
    update_bool(
        json,
        "screenScheduleEnabled",
        &updated.screen_schedule_enabled);
    update_bool(
        json,
        "rebootScheduleEnabled",
        &updated.reboot_schedule_enabled);
    update_bool(json, "playScene", &updated.play_scene);
    update_bool(json, "automaticCycle", &updated.automatic_cycle);
    update_bool(json, "randomPlayback", &updated.random_playback);
    update_bool(
        json,
        "playbackLogEnabled",
        &updated.playback_log_enabled);
    update_bool(json, "showInformation", &updated.show_information);
    cJSON *information_color_mode =
        cJSON_GetObjectItemCaseSensitive(json, "informationColorMode");
    if (information_color_mode != NULL) {
        if (!cJSON_IsNumber(information_color_mode) ||
            information_color_mode->valueint <
                DMD_INFORMATION_COLOR_GREY ||
            information_color_mode->valueint >
                DMD_INFORMATION_COLOR_CUSTOM) {
            cJSON_Delete(json);
            return httpd_resp_send_err(
                request,
                HTTPD_400_BAD_REQUEST,
                "Unknown information color mode");
        }
        updated.information_color_mode =
            (dmd_information_color_mode_t)
                information_color_mode->valueint;
    }
    cJSON *information_custom_color =
        cJSON_GetObjectItemCaseSensitive(json, "informationCustomColor");
    if (information_custom_color != NULL &&
        (!cJSON_IsString(information_custom_color) ||
         !parse_rgb(
             information_custom_color->valuestring,
             &updated.information_custom_color))) {
        cJSON_Delete(json);
        return httpd_resp_send_err(
            request,
            HTTPD_400_BAD_REQUEST,
            "Information color must be #RRGGBB");
    }

    cJSON *screen_schedule =
        cJSON_GetObjectItemCaseSensitive(json, "screenOffSchedule");
    if (screen_schedule != NULL) {
        if (!cJSON_IsArray(screen_schedule) ||
            cJSON_GetArraySize(screen_schedule) != DMD_SCHEDULE_DAY_COUNT) {
            cJSON_Delete(json);
            return httpd_resp_send_err(
                request,
                HTTPD_400_BAD_REQUEST,
                "Schedule must contain seven 24-hour rows");
        }
        uint8_t parsed_schedule[DMD_SCHEDULE_BYTES] = {0};
        for (uint8_t day = 0; day < DMD_SCHEDULE_DAY_COUNT; day++) {
            cJSON *row = cJSON_GetArrayItem(screen_schedule, day);
            if (!cJSON_IsString(row) ||
                strlen(row->valuestring) != DMD_SCHEDULE_HOUR_COUNT) {
                cJSON_Delete(json);
                return httpd_resp_send_err(
                    request,
                    HTTPD_400_BAD_REQUEST,
                    "Each schedule row must be 24 zero/one characters");
            }
            for (uint8_t hour = 0; hour < DMD_SCHEDULE_HOUR_COUNT; hour++) {
                char value = row->valuestring[hour];
                if (value != '0' && value != '1') {
                    cJSON_Delete(json);
                    return httpd_resp_send_err(
                        request,
                        HTTPD_400_BAD_REQUEST,
                        "Schedule rows may contain only zero and one");
                }
                if (value == '1') {
                    size_t slot =
                        (size_t)day * DMD_SCHEDULE_HOUR_COUNT + hour;
                    parsed_schedule[slot / 8] |=
                        (uint8_t)(1U << (slot % 8));
                }
            }
        }
        memcpy(
            updated.screen_off_schedule,
            parsed_schedule,
            sizeof(parsed_schedule));
    }

    cJSON *reboot_weekday =
        cJSON_GetObjectItemCaseSensitive(json, "rebootWeekday");
    if (reboot_weekday != NULL) {
        if (!cJSON_IsNumber(reboot_weekday) ||
            reboot_weekday->valueint < 0 ||
            reboot_weekday->valueint >= DMD_SCHEDULE_DAY_COUNT) {
            cJSON_Delete(json);
            return httpd_resp_send_err(
                request,
                HTTPD_400_BAD_REQUEST,
                "Reboot weekday must be between 0 and 6");
        }
        updated.reboot_weekday = (uint8_t)reboot_weekday->valueint;
    }
    cJSON *reboot_hour =
        cJSON_GetObjectItemCaseSensitive(json, "rebootHour");
    if (reboot_hour != NULL) {
        if (!cJSON_IsNumber(reboot_hour) ||
            reboot_hour->valueint < 0 ||
            reboot_hour->valueint >= DMD_SCHEDULE_HOUR_COUNT) {
            cJSON_Delete(json);
            return httpd_resp_send_err(
                request,
                HTTPD_400_BAD_REQUEST,
                "Reboot hour must be between 0 and 23");
        }
        updated.reboot_hour = (uint8_t)reboot_hour->valueint;
    }
    cJSON *reboot_minute =
        cJSON_GetObjectItemCaseSensitive(json, "rebootMinute");
    if (reboot_minute != NULL) {
        if (!cJSON_IsNumber(reboot_minute) ||
            reboot_minute->valueint < 0 ||
            reboot_minute->valueint >= 60) {
            cJSON_Delete(json);
            return httpd_resp_send_err(
                request,
                HTTPD_400_BAD_REQUEST,
                "Reboot minute must be between 0 and 59");
        }
        updated.reboot_minute = (uint8_t)reboot_minute->valueint;
    }

    cJSON *animations =
        cJSON_GetObjectItemCaseSensitive(json, "animationsPerCycle");
    if (cJSON_IsNumber(animations)) {
        updated.animations_per_cycle =
            animations->valueint < 1 ? 1 :
            (animations->valueint > 20 ? 20 : animations->valueint);
    }
    cJSON *clock_seconds =
        cJSON_GetObjectItemCaseSensitive(json, "clockDisplaySeconds");
    if (cJSON_IsNumber(clock_seconds)) {
        updated.clock_display_seconds =
            clock_seconds->valueint < 5 ? 5 :
            (clock_seconds->valueint > 3600 ? 3600 : clock_seconds->valueint);
    }
    cJSON *gap_seconds =
        cJSON_GetObjectItemCaseSensitive(json, "animationGapSeconds");
    if (cJSON_IsNumber(gap_seconds)) {
        updated.animation_gap_seconds =
            gap_seconds->valueint < 0 ? 0 :
            (gap_seconds->valueint > 3600 ? 3600 : gap_seconds->valueint);
    }

    cJSON *scene_index = cJSON_GetObjectItemCaseSensitive(json, "sceneIndex");
    if (cJSON_IsNumber(scene_index)) {
        if (scene_index->valueint < 0 ||
            scene_index->valueint >= dmd_scene_count()) {
            cJSON_Delete(json);
            return httpd_resp_send_err(
                request,
                HTTPD_400_BAD_REQUEST,
                "Unknown SD-card scene");
        }
        updated.scene_index = (uint16_t)scene_index->valueint;
    }

    cJSON *color = cJSON_GetObjectItemCaseSensitive(json, "colorPreset");
    if (cJSON_IsNumber(color)) {
        if (color->valueint < 0 ||
            color->valueint > UINT8_MAX ||
            !dmd_color_is_valid((uint8_t)color->valueint)) {
            cJSON_Delete(json);
            return httpd_resp_send_err(
                request,
                HTTPD_400_BAD_REQUEST,
                "Unknown color preset");
        }
        updated.color_preset = (dmd_color_preset_t)color->valueint;
    }

    cJSON *timezone = cJSON_GetObjectItemCaseSensitive(json, "timezone");
    if (cJSON_IsString(timezone) && timezone->valuestring[0] != '\0') {
        strlcpy(updated.timezone, timezone->valuestring, sizeof(updated.timezone));
    }
    cJSON *ssid = cJSON_GetObjectItemCaseSensitive(json, "wifiSsid");
    if (cJSON_IsString(ssid)) {
        strlcpy(updated.wifi_ssid, ssid->valuestring, sizeof(updated.wifi_ssid));
    }
    cJSON *password = cJSON_GetObjectItemCaseSensitive(json, "wifiPassword");
    if (cJSON_IsString(password)) {
        strlcpy(
            updated.wifi_password,
            password->valuestring,
            sizeof(updated.wifi_password));
    }
    update_bool(json, "mqttEnabled", &updated.mqtt_enabled);
    cJSON *mqtt_host = cJSON_GetObjectItemCaseSensitive(json, "mqttHost");
    if (cJSON_IsString(mqtt_host)) {
        strlcpy(
            updated.mqtt_host,
            mqtt_host->valuestring,
            sizeof(updated.mqtt_host));
    }
    cJSON *mqtt_port = cJSON_GetObjectItemCaseSensitive(json, "mqttPort");
    if (mqtt_port != NULL) {
        if (!cJSON_IsNumber(mqtt_port) ||
            mqtt_port->valueint < 1 ||
            mqtt_port->valueint > UINT16_MAX) {
            cJSON_Delete(json);
            return httpd_resp_send_err(
                request,
                HTTPD_400_BAD_REQUEST,
                "MQTT port must be between 1 and 65535");
        }
        updated.mqtt_port = (uint16_t)mqtt_port->valueint;
    }
    cJSON *mqtt_username =
        cJSON_GetObjectItemCaseSensitive(json, "mqttUsername");
    if (cJSON_IsString(mqtt_username)) {
        strlcpy(
            updated.mqtt_username,
            mqtt_username->valuestring,
            sizeof(updated.mqtt_username));
    }
    cJSON *mqtt_password =
        cJSON_GetObjectItemCaseSensitive(json, "mqttPassword");
    if (cJSON_IsString(mqtt_password)) {
        strlcpy(
            updated.mqtt_password,
            mqtt_password->valuestring,
            sizeof(updated.mqtt_password));
    }
    cJSON *mqtt_discovery =
        cJSON_GetObjectItemCaseSensitive(json, "mqttDiscoveryPrefix");
    if (cJSON_IsString(mqtt_discovery)) {
        const char *value = mqtt_discovery->valuestring;
        if (value[0] == '\0' ||
            strchr(value, '#') != NULL ||
            strchr(value, '+') != NULL) {
            cJSON_Delete(json);
            return httpd_resp_send_err(
                request,
                HTTPD_400_BAD_REQUEST,
                "MQTT discovery prefix must be a non-empty topic without wildcards");
        }
        strlcpy(
            updated.mqtt_discovery_prefix,
            value,
            sizeof(updated.mqtt_discovery_prefix));
    }
    cJSON_Delete(json);

    bool wifi_changed =
        strcmp(before.wifi_ssid, updated.wifi_ssid) != 0 ||
        strcmp(before.wifi_password, updated.wifi_password) != 0;
    esp_err_t error = dmd_settings_update(&updated);
    if (error != ESP_OK) {
        return httpd_resp_send_err(
            request,
            HTTPD_500_INTERNAL_SERVER_ERROR,
            esp_err_to_name(error));
    }
    if (updated.play_scene != before.play_scene ||
        (updated.play_scene && updated.scene_index != before.scene_index)) {
        if (updated.play_scene) {
            dmd_display_play_scene(updated.scene_index);
        } else {
            dmd_display_show_clock();
        }
    }
    if (wifi_changed) {
        error = dmd_network_apply_credentials(
            updated.wifi_ssid,
            updated.wifi_password);
        if (error != ESP_OK) {
            ESP_LOGW(TAG, "Wi-Fi reconfiguration failed: %s", esp_err_to_name(error));
        }
    }

    cJSON *response = cJSON_CreateObject();
    cJSON_AddBoolToObject(response, "ok", true);
    cJSON_AddBoolToObject(response, "wifiReconnecting", wifi_changed);
    return send_json(request, response);
}

static esp_err_t time_post(httpd_req_t *request)
{
    cJSON *json = receive_json(request);
    if (json == NULL) {
        return httpd_resp_send_err(
            request,
            HTTPD_400_BAD_REQUEST,
            "Expected JSON containing epoch");
    }
    cJSON *epoch = cJSON_GetObjectItemCaseSensitive(json, "epoch");
    if (!cJSON_IsNumber(epoch) || epoch->valuedouble < 1700000000.0) {
        cJSON_Delete(json);
        return httpd_resp_send_err(
            request,
            HTTPD_400_BAD_REQUEST,
            "epoch must be Unix time in seconds");
    }
    struct timeval value = {
        .tv_sec = (time_t)epoch->valuedouble,
        .tv_usec = 0,
    };
    cJSON_Delete(json);
    if (settimeofday(&value, NULL) != 0) {
        return httpd_resp_send_err(
            request,
            HTTPD_500_INTERNAL_SERVER_ERROR,
            "Could not set system time");
    }
    dmd_network_note_browser_time();
    cJSON *response = cJSON_CreateObject();
    cJSON_AddBoolToObject(response, "ok", true);
    return send_json(request, response);
}

static esp_err_t action_post(httpd_req_t *request)
{
    cJSON *json = receive_json(request);
    if (json == NULL) {
        return httpd_resp_send_err(
            request,
            HTTPD_400_BAD_REQUEST,
            "Expected JSON containing action");
    }
    cJSON *name = cJSON_GetObjectItemCaseSensitive(json, "action");
    if (!cJSON_IsString(name)) {
        cJSON_Delete(json);
        return httpd_resp_send_err(
            request,
            HTTPD_400_BAD_REQUEST,
            "action must be a string");
    }

    dmd_action_t action;
    if (strcmp(name->valuestring, "colorFamilyNext") == 0) {
        action = DMD_ACTION_COLOR_FAMILY_NEXT;
    } else if (strcmp(name->valuestring, "colorThemeNext") == 0) {
        action = DMD_ACTION_COLOR_THEME_NEXT;
    } else if (strcmp(name->valuestring, "toggleInformation") == 0) {
        action = DMD_ACTION_TOGGLE_INFORMATION;
    } else if (strcmp(name->valuestring, "toggleGlow") == 0) {
        action = DMD_ACTION_TOGGLE_GLOW;
    } else if (strcmp(name->valuestring, "syncNtp") == 0) {
        action = DMD_ACTION_SYNC_NTP;
    } else if (strcmp(name->valuestring, "pinballNext") == 0) {
        action = DMD_ACTION_PINBALL_NEXT;
    } else if (strcmp(name->valuestring, "sceneNext") == 0) {
        action = DMD_ACTION_SCENE_NEXT;
    } else if (strcmp(name->valuestring, "toggleRandom") == 0) {
        action = DMD_ACTION_TOGGLE_RANDOM;
    } else if (strcmp(name->valuestring, "showClock") == 0) {
        action = DMD_ACTION_SHOW_CLOCK;
    } else if (strcmp(name->valuestring, "touchTest") == 0) {
        action = DMD_ACTION_TOUCH_TEST;
    } else if (strcmp(name->valuestring, "setupQr") == 0) {
        action = DMD_ACTION_SETUP_QR;
    } else if (strcmp(name->valuestring, "reboot") == 0) {
        action = DMD_ACTION_REBOOT;
    } else {
        cJSON_Delete(json);
        return httpd_resp_send_err(
            request,
            HTTPD_400_BAD_REQUEST,
            "Unknown action");
    }
    cJSON_Delete(json);

    esp_err_t error = dmd_action_execute(action);
    if (error == ESP_ERR_INVALID_STATE) {
        httpd_resp_set_status(request, "409 Conflict");
        return httpd_resp_sendstr(
            request,
            "NTP is waiting for a network connection");
    }
    if (error != ESP_OK) {
        return httpd_resp_send_err(
            request,
            HTTPD_500_INTERNAL_SERVER_ERROR,
            esp_err_to_name(error));
    }
    cJSON *response = cJSON_CreateObject();
    cJSON_AddBoolToObject(response, "ok", true);
    return send_json(request, response);
}

static esp_err_t favicon_get(httpd_req_t *request)
{
    httpd_resp_set_type(request, "image/x-icon");
    httpd_resp_set_hdr(request, "Cache-Control", "public, max-age=86400");
    return httpd_resp_send(
        request,
        (const char *)dmdclock_ico_start,
        dmdclock_ico_end - dmdclock_ico_start);
}

esp_err_t dmd_web_start(void)
{
    httpd_config_t config = HTTPD_DEFAULT_CONFIG();
    config.max_uri_handlers = 8;
    config.stack_size = 6144;
    config.lru_purge_enable = true;
    config.open_fn = web_client_open;
    esp_err_t error = httpd_start(&s_server, &config);
    if (error != ESP_OK) {
        return error;
    }

    const httpd_uri_t routes[] = {
        {.uri = "/", .method = HTTP_GET, .handler = index_get},
        {.uri = "/api-docs", .method = HTTP_GET, .handler = api_docs_get},
        {.uri = "/api/state", .method = HTTP_GET, .handler = state_get},
        {.uri = "/api/scenes", .method = HTTP_GET, .handler = scenes_get},
        {.uri = "/api/settings", .method = HTTP_POST, .handler = settings_post},
        {.uri = "/api/time", .method = HTTP_POST, .handler = time_post},
        {.uri = "/api/action", .method = HTTP_POST, .handler = action_post},
        {.uri = "/favicon.ico", .method = HTTP_GET, .handler = favicon_get},
    };
    for (size_t index = 0; index < sizeof(routes) / sizeof(routes[0]); index++) {
        error = httpd_register_uri_handler(s_server, &routes[index]);
        if (error != ESP_OK) {
            httpd_stop(s_server);
            s_server = NULL;
            return error;
        }
    }
    ESP_LOGI(TAG, "Web remote started");
    return ESP_OK;
}
