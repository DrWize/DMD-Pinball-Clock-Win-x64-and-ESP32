#include "dmd_mqtt.h"

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "cJSON.h"
#include "dmd_actions.h"
#include "dmd_diagnostics.h"
#include "dmd_display.h"
#include "dmd_network.h"
#include "dmd_scene.h"
#include "dmd_settings.h"
#include "esp_app_desc.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"
#include "mqtt_client.h"

#define MQTT_TOPIC_MAX 192
#define MQTT_ID_MAX 40
#define MQTT_STATE_INTERVAL_MS 30000

static const char *TAG = "dmd_mqtt";
static SemaphoreHandle_t s_lock;
static esp_mqtt_client_handle_t s_client;
static dmd_mqtt_info_t s_info;
static dmd_settings_t s_active_settings;
static char s_device_name[33];
static char s_device_id[MQTT_ID_MAX];
static char s_base_topic[64];
static char s_availability_topic[MQTT_TOPIC_MAX];
static char s_command_topic[MQTT_TOPIC_MAX];
static char s_client_id[MQTT_ID_MAX];

static void set_connected(bool connected)
{
    xSemaphoreTake(s_lock, portMAX_DELAY);
    s_info.connected = connected;
    if (connected) {
        s_info.connect_count++;
    } else {
        s_info.disconnect_count++;
    }
    xSemaphoreGive(s_lock);
}

static void note_error(void)
{
    xSemaphoreTake(s_lock, portMAX_DELAY);
    s_info.error_count++;
    xSemaphoreGive(s_lock);
}

static bool topic_equals(const esp_mqtt_event_handle_t event, const char *topic)
{
    size_t length = strlen(topic);
    return event->topic_len == (int)length &&
        memcmp(event->topic, topic, length) == 0;
}

static bool payload_equals(
    const esp_mqtt_event_handle_t event,
    const char *payload)
{
    size_t length = strlen(payload);
    return event->data_len == (int)length &&
        memcmp(event->data, payload, length) == 0;
}

static int publish(const char *topic, const char *payload, int qos, int retain)
{
    if (s_client == NULL) {
        return -1;
    }
    int id = esp_mqtt_client_publish(
        s_client,
        topic,
        payload,
        0,
        qos,
        retain);
    if (id < 0) {
        note_error();
    }
    return id;
}

static void add_device(cJSON *json)
{
    const esp_app_desc_t *app = esp_app_get_description();
    cJSON *device = cJSON_AddObjectToObject(json, "device");
    cJSON *identifiers = cJSON_AddArrayToObject(device, "identifiers");
    cJSON_AddItemToArray(identifiers, cJSON_CreateString(s_device_id));
    cJSON_AddStringToObject(device, "name", s_device_name);
    cJSON_AddStringToObject(device, "manufacturer", "DMDClock");
    cJSON_AddStringToObject(device, "model", "Waveshare ESP32-S3 Touch LCD 7");
    cJSON_AddStringToObject(device, "sw_version", app->version);
}

static void publish_discovery_entity(
    const char *component,
    const char *object_suffix,
    const char *name,
    const char *state_topic,
    const char *command_topic,
    const char *device_class,
    const char *unit,
    const char *value_template)
{
    char topic[MQTT_TOPIC_MAX];
    char unique_id[MQTT_ID_MAX + 32];
    snprintf(
        topic,
        sizeof(topic),
        "%s/%s/%s_%s/config",
        s_active_settings.mqtt_discovery_prefix,
        component,
        s_device_id,
        object_suffix);
    snprintf(
        unique_id,
        sizeof(unique_id),
        "%s_%s",
        s_device_id,
        object_suffix);

    cJSON *json = cJSON_CreateObject();
    cJSON_AddStringToObject(json, "name", name);
    cJSON_AddStringToObject(json, "unique_id", unique_id);
    if (state_topic != NULL) {
        cJSON_AddStringToObject(json, "state_topic", state_topic);
    }
    if (command_topic != NULL) {
        cJSON_AddStringToObject(json, "command_topic", command_topic);
    }
    cJSON_AddStringToObject(
        json,
        "availability_topic",
        s_availability_topic);
    if (device_class != NULL) {
        cJSON_AddStringToObject(json, "device_class", device_class);
    }
    if (unit != NULL) {
        cJSON_AddStringToObject(json, "unit_of_measurement", unit);
    }
    if (value_template != NULL) {
        cJSON_AddStringToObject(json, "value_template", value_template);
    }
    if (strcmp(component, "switch") == 0) {
        cJSON_AddStringToObject(json, "payload_on", "ON");
        cJSON_AddStringToObject(json, "payload_off", "OFF");
    } else if (strcmp(component, "number") == 0) {
        cJSON_AddNumberToObject(json, "min", 0);
        cJSON_AddNumberToObject(json, "max", 100);
        cJSON_AddNumberToObject(json, "step", 1);
        cJSON_AddStringToObject(json, "mode", "slider");
    }
    add_device(json);
    char *payload = cJSON_PrintUnformatted(json);
    cJSON_Delete(json);
    if (payload != NULL) {
        publish(topic, payload, 1, 1);
        free(payload);
    }
}

static void publish_discovery(void)
{
    char state_topic[MQTT_TOPIC_MAX];
    char command_topic[MQTT_TOPIC_MAX];
    snprintf(state_topic, sizeof(state_topic), "%s/state", s_base_topic);

    snprintf(
        command_topic,
        sizeof(command_topic),
        "%s/command/display",
        s_base_topic);
    publish_discovery_entity(
        "switch",
        "display",
        "Display",
        state_topic,
        command_topic,
        NULL,
        NULL,
        "{{ value_json.display }}");

    snprintf(
        command_topic,
        sizeof(command_topic),
        "%s/command/brightness",
        s_base_topic);
    publish_discovery_entity(
        "number",
        "brightness",
        "Brightness",
        state_topic,
        command_topic,
        NULL,
        "%",
        "{{ value_json.brightness }}");

    const struct {
        const char *suffix;
        const char *name;
    } buttons[] = {
        {"next_pinball", "Next pinball"},
        {"next_scene", "Next scene"},
        {"sync_ntp", "Synchronize time"},
    };
    for (size_t index = 0; index < sizeof(buttons) / sizeof(buttons[0]); index++) {
        snprintf(
            command_topic,
            sizeof(command_topic),
            "%s/command/%s",
            s_base_topic,
            buttons[index].suffix);
        publish_discovery_entity(
            "button",
            buttons[index].suffix,
            buttons[index].name,
            NULL,
            command_topic,
            NULL,
            NULL,
            NULL);
    }

    const struct {
        const char *suffix;
        const char *name;
        const char *device_class;
        const char *unit;
        const char *value_template;
    } sensors[] = {
        {"scene", "Current scene", NULL, NULL, "{{ value_json.scene }}"},
        {"uptime", "Uptime", "duration", "s", "{{ value_json.uptime }}"},
        {"wifi_rssi", "Wi-Fi signal", "signal_strength", "dBm", "{{ value_json.wifiRssi }}"},
        {"chip_temperature", "Chip temperature (approximate)", "temperature", "°C", "{{ value_json.chipTemperature }}"},
        {"free_heap", "Free heap", "data_size", "B", "{{ value_json.freeHeap }}"},
        {"sd_free", "SD card free", "data_size", "B", "{{ value_json.sdFree }}"},
        {"firmware", "Firmware", NULL, NULL, "{{ value_json.firmware }}"},
    };
    for (size_t index = 0; index < sizeof(sensors) / sizeof(sensors[0]); index++) {
        publish_discovery_entity(
            "sensor",
            sensors[index].suffix,
            sensors[index].name,
            state_topic,
            NULL,
            sensors[index].device_class,
            sensors[index].unit,
            sensors[index].value_template);
    }

    const struct {
        const char *suffix;
        const char *name;
        const char *value_template;
    } binary_sensors[] = {
        {"sd_card", "SD card", "{{ value_json.sdAvailable }}"},
        {"time_sync", "Time synchronized", "{{ value_json.timeSynchronized }}"},
    };
    for (size_t index = 0;
         index < sizeof(binary_sensors) / sizeof(binary_sensors[0]);
         index++) {
        publish_discovery_entity(
            "binary_sensor",
            binary_sensors[index].suffix,
            binary_sensors[index].name,
            state_topic,
            NULL,
            NULL,
            NULL,
            binary_sensors[index].value_template);
    }
}

static void publish_state(void)
{
    dmd_settings_t settings;
    dmd_settings_get(&settings);
    dmd_network_info_t network;
    dmd_network_get_info(&network);
    dmd_diagnostics_t diagnostics;
    dmd_diagnostics_get(&diagnostics);
    dmd_scene_info_t scene;
    dmd_scene_get_info(&scene);
    const esp_app_desc_t *app = esp_app_get_description();

    cJSON *json = cJSON_CreateObject();
    cJSON_AddStringToObject(json, "display", settings.display_on ? "ON" : "OFF");
    cJSON_AddNumberToObject(json, "brightness", settings.brightness);
    cJSON_AddStringToObject(json, "scene", scene.display_name);
    cJSON_AddNumberToObject(
        json,
        "uptime",
        (double)(esp_timer_get_time() / 1000000));
    if (diagnostics.wifi_rssi_available) {
        cJSON_AddNumberToObject(json, "wifiRssi", diagnostics.wifi_rssi_dbm);
    } else {
        cJSON_AddNullToObject(json, "wifiRssi");
    }
    if (diagnostics.chip_temperature_available) {
        cJSON_AddNumberToObject(
            json,
            "chipTemperature",
            diagnostics.chip_temperature_c);
    } else {
        cJSON_AddNullToObject(json, "chipTemperature");
    }
    cJSON_AddNumberToObject(json, "freeHeap", diagnostics.free_heap_bytes);
    cJSON_AddNumberToObject(json, "sdFree", (double)diagnostics.sd_free_bytes);
    cJSON_AddStringToObject(json, "firmware", app->version);
    cJSON_AddStringToObject(
        json,
        "sdAvailable",
        diagnostics.sd_available ? "ON" : "OFF");
    cJSON_AddStringToObject(
        json,
        "timeSynchronized",
        network.ntp_synced ? "ON" : "OFF");

    char *payload = cJSON_PrintUnformatted(json);
    cJSON_Delete(json);
    if (payload != NULL) {
        char topic[MQTT_TOPIC_MAX];
        snprintf(topic, sizeof(topic), "%s/state", s_base_topic);
        publish(topic, payload, 0, 1);
        free(payload);
    }
}

static void handle_command(esp_mqtt_event_handle_t event)
{
    char topic[MQTT_TOPIC_MAX];
    dmd_settings_t settings;
    dmd_settings_get(&settings);
    esp_err_t result = ESP_ERR_INVALID_ARG;

    snprintf(topic, sizeof(topic), "%s/command/display", s_base_topic);
    if (topic_equals(event, topic)) {
        if (payload_equals(event, "ON") || payload_equals(event, "OFF")) {
            settings.display_on = payload_equals(event, "ON");
            result = dmd_settings_update(&settings);
        }
    } else {
        snprintf(topic, sizeof(topic), "%s/command/brightness", s_base_topic);
        if (topic_equals(event, topic)) {
            char value[8];
            if (event->data_len > 0 &&
                event->data_len < (int)sizeof(value)) {
                memcpy(value, event->data, event->data_len);
                value[event->data_len] = '\0';
                char *end = NULL;
                long parsed = strtol(value, &end, 10);
                if (end != value && *end == '\0' &&
                    parsed >= 0 && parsed <= 100) {
                    settings.brightness = (uint8_t)parsed;
                    result = dmd_settings_update(&settings);
                }
            }
        } else {
            snprintf(topic, sizeof(topic), "%s/command/next_pinball", s_base_topic);
            if (topic_equals(event, topic) && payload_equals(event, "PRESS")) {
                result = dmd_action_execute(DMD_ACTION_PINBALL_NEXT);
            } else {
                snprintf(topic, sizeof(topic), "%s/command/next_scene", s_base_topic);
                if (topic_equals(event, topic) && payload_equals(event, "PRESS")) {
                    result = dmd_action_execute(DMD_ACTION_SCENE_NEXT);
                } else {
                    snprintf(topic, sizeof(topic), "%s/command/sync_ntp", s_base_topic);
                    if (topic_equals(event, topic) && payload_equals(event, "PRESS")) {
                        result = dmd_action_execute(DMD_ACTION_SYNC_NTP);
                    }
                }
            }
        }
    }

    if (result == ESP_OK) {
        xSemaphoreTake(s_lock, portMAX_DELAY);
        s_info.command_count++;
        xSemaphoreGive(s_lock);
        publish_state();
    } else {
        note_error();
        ESP_LOGW(TAG, "Rejected MQTT command");
    }
}

static void mqtt_event(
    void *argument,
    esp_event_base_t event_base,
    int32_t event_id,
    void *event_data)
{
    (void)argument;
    (void)event_base;
    esp_mqtt_event_handle_t event = event_data;
    if (event_id == MQTT_EVENT_CONNECTED) {
        set_connected(true);
        publish(s_availability_topic, "online", 1, 1);
        publish_discovery();
        publish_state();
        esp_mqtt_client_subscribe(s_client, s_command_topic, 1);
        esp_mqtt_client_subscribe(s_client, "homeassistant/status", 0);
        ESP_LOGI(TAG, "Connected and published Home Assistant discovery");
    } else if (event_id == MQTT_EVENT_DISCONNECTED) {
        set_connected(false);
        ESP_LOGW(TAG, "Broker disconnected; standalone operation continues");
    } else if (event_id == MQTT_EVENT_DATA) {
        if (topic_equals(event, "homeassistant/status")) {
            if (payload_equals(event, "online")) {
                publish_discovery();
                publish_state();
            }
        } else {
            handle_command(event);
        }
    } else if (event_id == MQTT_EVENT_ERROR) {
        note_error();
    }
}

static void normalize_id(const char *name, char *output, size_t capacity)
{
    size_t write = 0;
    for (size_t read = 0; name[read] != '\0' && write + 1 < capacity; read++) {
        unsigned char value = (unsigned char)name[read];
        output[write++] = isalnum(value)
            ? (char)tolower(value)
            : '_';
    }
    output[write] = '\0';
}

static bool connection_settings_equal(
    const dmd_settings_t *left,
    const dmd_settings_t *right)
{
    return left->mqtt_enabled == right->mqtt_enabled &&
        left->mqtt_port == right->mqtt_port &&
        strcmp(left->mqtt_host, right->mqtt_host) == 0 &&
        strcmp(left->mqtt_username, right->mqtt_username) == 0 &&
        strcmp(left->mqtt_password, right->mqtt_password) == 0 &&
        strcmp(
            left->mqtt_discovery_prefix,
            right->mqtt_discovery_prefix) == 0;
}

static void stop_client(void)
{
    if (s_client == NULL) {
        return;
    }
    publish(s_availability_topic, "offline", 1, 1);
    esp_mqtt_client_stop(s_client);
    esp_mqtt_client_destroy(s_client);
    s_client = NULL;
    xSemaphoreTake(s_lock, portMAX_DELAY);
    s_info.connected = false;
    xSemaphoreGive(s_lock);
}

static void start_client(const dmd_settings_t *settings)
{
    dmd_network_info_t network;
    dmd_network_get_info(&network);
    strlcpy(s_device_name, network.device_name, sizeof(s_device_name));
    normalize_id(s_device_name, s_device_id, sizeof(s_device_id));
    snprintf(s_client_id, sizeof(s_client_id), "%s", s_device_id);
    snprintf(s_base_topic, sizeof(s_base_topic), "dmdclock/%s", s_device_id);
    snprintf(
        s_availability_topic,
        sizeof(s_availability_topic),
        "%s/availability",
        s_base_topic);
    snprintf(
        s_command_topic,
        sizeof(s_command_topic),
        "%s/command/#",
        s_base_topic);
    s_active_settings = *settings;

    esp_mqtt_client_config_t config = {
        .broker.address.hostname = s_active_settings.mqtt_host,
        .broker.address.transport = MQTT_TRANSPORT_OVER_TCP,
        .broker.address.port = s_active_settings.mqtt_port,
        .credentials.username =
            s_active_settings.mqtt_username[0] != '\0'
                ? s_active_settings.mqtt_username
                : NULL,
        .credentials.client_id = s_client_id,
        .credentials.authentication.password =
            s_active_settings.mqtt_password[0] != '\0'
                ? s_active_settings.mqtt_password
                : NULL,
        .session.last_will.topic = s_availability_topic,
        .session.last_will.msg = "offline",
        .session.last_will.qos = 1,
        .session.last_will.retain = 1,
        .network.reconnect_timeout_ms = 10000,
        .network.timeout_ms = 5000,
        .task.priority = 3,
        .task.stack_size = 6144,
        .buffer.size = 2048,
        .buffer.out_size = 2048,
        .outbox.limit = 16384,
    };
    s_client = esp_mqtt_client_init(&config);
    if (s_client == NULL) {
        note_error();
        ESP_LOGE(TAG, "Could not create MQTT client");
        return;
    }
    esp_mqtt_client_register_event(
        s_client,
        ESP_EVENT_ANY_ID,
        mqtt_event,
        NULL);
    esp_err_t error = esp_mqtt_client_start(s_client);
    if (error != ESP_OK) {
        note_error();
        ESP_LOGE(TAG, "Could not start MQTT client: %s", esp_err_to_name(error));
        esp_mqtt_client_destroy(s_client);
        s_client = NULL;
    } else {
        ESP_LOGI(
            TAG,
            "MQTT enabled for broker %s:%u",
            s_active_settings.mqtt_host,
            s_active_settings.mqtt_port);
    }
}

static void mqtt_supervisor_task(void *context)
{
    (void)context;
    uint32_t active_revision = UINT32_MAX;
    int64_t next_state_at = 0;
    while (true) {
        dmd_settings_t settings;
        dmd_settings_get(&settings);
        bool configured =
            settings.mqtt_enabled && settings.mqtt_host[0] != '\0';
        xSemaphoreTake(s_lock, portMAX_DELAY);
        s_info.enabled = settings.mqtt_enabled;
        s_info.configured = configured;
        bool connected = s_info.connected;
        xSemaphoreGive(s_lock);

        if (!configured) {
            stop_client();
            active_revision = settings.revision;
        } else if (s_client == NULL ||
                   !connection_settings_equal(&settings, &s_active_settings)) {
            stop_client();
            start_client(&settings);
            active_revision = settings.revision;
            next_state_at = esp_timer_get_time() / 1000 + MQTT_STATE_INTERVAL_MS;
        } else {
            int64_t now = esp_timer_get_time() / 1000;
            if (connected &&
                (settings.revision != active_revision || now >= next_state_at)) {
                publish_state();
                active_revision = settings.revision;
                next_state_at = now + MQTT_STATE_INTERVAL_MS;
            }
        }
        vTaskDelay(pdMS_TO_TICKS(2000));
    }
}

esp_err_t dmd_mqtt_init(void)
{
    s_lock = xSemaphoreCreateMutex();
    if (s_lock == NULL) {
        return ESP_ERR_NO_MEM;
    }
    memset(&s_info, 0, sizeof(s_info));
    memset(&s_active_settings, 0, sizeof(s_active_settings));
    return xTaskCreate(
               mqtt_supervisor_task,
               "dmd_mqtt_supervisor",
               6144,
               NULL,
               2,
               NULL) == pdPASS
        ? ESP_OK
        : ESP_ERR_NO_MEM;
}

void dmd_mqtt_get_info(dmd_mqtt_info_t *info)
{
    if (info == NULL || s_lock == NULL) {
        return;
    }
    xSemaphoreTake(s_lock, portMAX_DELAY);
    *info = s_info;
    xSemaphoreGive(s_lock);
}
