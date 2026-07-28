#include "dmd_network.h"

#include <stdio.h>
#include <string.h>

#include "dmd_settings.h"
#include "esp_check.h"
#include "esp_event.h"
#include "esp_log.h"
#include "esp_netif.h"
#include "esp_netif_sntp.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "sdkconfig.h"

#if CONFIG_DMD_QEMU
#include "esp_eth.h"
#include "esp_eth_mac_openeth.h"
#include "esp_eth_phy.h"
#else
#include "esp_wifi.h"
#endif

static const char *TAG = "dmd_network";
#if !CONFIG_DMD_QEMU
static const char *AP_PASSWORD = "dmdclock";
static esp_netif_t *s_station_netif;
#endif
static SemaphoreHandle_t s_info_lock;
static dmd_network_info_t s_info;
static bool s_sntp_initialized;

static void ntp_sync_callback(struct timeval *value)
{
    xSemaphoreTake(s_info_lock, portMAX_DELAY);
    s_info.ntp_started = true;
    s_info.ntp_syncing = false;
    s_info.ntp_synced = true;
    s_info.ntp_last_sync = value != NULL ? value->tv_sec : time(NULL);
    strlcpy(s_info.time_source, "NTP", sizeof(s_info.time_source));
    xSemaphoreGive(s_info_lock);
    ESP_LOGI(TAG, "NTP time synchronized");
}

static void start_sntp_once(void)
{
    if (s_sntp_initialized) {
        return;
    }
    esp_sntp_config_t config = ESP_NETIF_SNTP_DEFAULT_CONFIG_MULTIPLE(
        2,
        ESP_SNTP_SERVER_LIST("pool.ntp.org", "time.cloudflare.com"));
    config.wait_for_sync = false;
    config.sync_cb = ntp_sync_callback;
    esp_err_t error = esp_netif_sntp_init(&config);
    if (error == ESP_OK) {
        s_sntp_initialized = true;
        xSemaphoreTake(s_info_lock, portMAX_DELAY);
        s_info.ntp_started = true;
        s_info.ntp_syncing = true;
        xSemaphoreGive(s_info_lock);
        ESP_LOGI(TAG, "SNTP started");
    } else {
        ESP_LOGW(TAG, "SNTP start failed: %s", esp_err_to_name(error));
    }
}

static void set_station_state(bool connected, const char *ip)
{
    xSemaphoreTake(s_info_lock, portMAX_DELAY);
    s_info.station_connected = connected;
    strlcpy(s_info.station_ip, ip != NULL ? ip : "", sizeof(s_info.station_ip));
    xSemaphoreGive(s_info_lock);
}

#if CONFIG_DMD_QEMU

static esp_eth_handle_t s_eth_handle;
static esp_eth_netif_glue_handle_t s_eth_glue;

static void qemu_ip_event(
    void *argument,
    esp_event_base_t event_base,
    int32_t event_id,
    void *event_data)
{
    (void)argument;
    (void)event_base;
    if (event_id == IP_EVENT_ETH_GOT_IP) {
        const ip_event_got_ip_t *event = event_data;
        char address[16];
        snprintf(address, sizeof(address), IPSTR, IP2STR(&event->ip_info.ip));
        set_station_state(true, address);
        ESP_LOGI(TAG, "QEMU Ethernet ready at %s", address);
        start_sntp_once();
    }
}

esp_err_t dmd_network_apply_credentials(const char *ssid, const char *password)
{
    (void)ssid;
    (void)password;
    return ESP_OK;
}

esp_err_t dmd_network_init(void)
{
    s_info_lock = xSemaphoreCreateMutex();
    if (s_info_lock == NULL) {
        return ESP_ERR_NO_MEM;
    }
    memset(&s_info, 0, sizeof(s_info));
    strlcpy(s_info.time_source, "Unset", sizeof(s_info.time_source));
    strlcpy(s_info.access_point_ssid, "QEMU", sizeof(s_info.access_point_ssid));
    strlcpy(s_info.access_point_ip, "localhost:8080", sizeof(s_info.access_point_ip));

    ESP_RETURN_ON_ERROR(esp_netif_init(), TAG, "initialize TCP/IP");
    ESP_RETURN_ON_ERROR(
        esp_event_loop_create_default(),
        TAG,
        "create event loop");

    esp_netif_config_t netif_config = ESP_NETIF_DEFAULT_ETH();
    esp_netif_t *netif = esp_netif_new(&netif_config);
    if (netif == NULL) {
        return ESP_ERR_NO_MEM;
    }

    eth_mac_config_t mac_config = ETH_MAC_DEFAULT_CONFIG();
    eth_phy_config_t phy_config = ETH_PHY_DEFAULT_CONFIG();
    phy_config.autonego_timeout_ms = 100;
    esp_eth_mac_t *mac = esp_eth_mac_new_openeth(&mac_config);
    esp_eth_phy_t *phy = esp_eth_phy_new_dp83848(&phy_config);
    if (mac == NULL || phy == NULL) {
        return ESP_ERR_NO_MEM;
    }
    esp_eth_config_t eth_config = ETH_DEFAULT_CONFIG(mac, phy);
    ESP_RETURN_ON_ERROR(
        esp_eth_driver_install(&eth_config, &s_eth_handle),
        TAG,
        "install QEMU Ethernet");
    s_eth_glue = esp_eth_new_netif_glue(s_eth_handle);
    if (s_eth_glue == NULL) {
        return ESP_ERR_NO_MEM;
    }
    ESP_RETURN_ON_ERROR(
        esp_netif_attach(netif, s_eth_glue),
        TAG,
        "attach QEMU Ethernet");
    ESP_RETURN_ON_ERROR(
        esp_event_handler_register(
            IP_EVENT,
            IP_EVENT_ETH_GOT_IP,
            qemu_ip_event,
            NULL),
        TAG,
        "register QEMU IP event");
    ESP_RETURN_ON_ERROR(esp_eth_start(s_eth_handle), TAG, "start QEMU Ethernet");
    ESP_LOGI(TAG, "QEMU remote uses host forwarding at http://localhost:8080/");
    return ESP_OK;
}

#else

static void network_event(
    void *argument,
    esp_event_base_t event_base,
    int32_t event_id,
    void *event_data)
{
    (void)argument;
    if (event_base == WIFI_EVENT && event_id == WIFI_EVENT_STA_START) {
        dmd_settings_t settings;
        dmd_settings_get(&settings);
        if (settings.wifi_ssid[0] != '\0') {
            esp_wifi_connect();
        }
    } else if (event_base == WIFI_EVENT &&
               event_id == WIFI_EVENT_STA_DISCONNECTED) {
        set_station_state(false, "");
        dmd_settings_t settings;
        dmd_settings_get(&settings);
        if (settings.wifi_ssid[0] != '\0') {
            ESP_LOGW(TAG, "Home Wi-Fi disconnected; reconnecting");
            esp_wifi_connect();
        }
    } else if (event_base == IP_EVENT && event_id == IP_EVENT_STA_GOT_IP) {
        const ip_event_got_ip_t *event = event_data;
        char address[16];
        snprintf(address, sizeof(address), IPSTR, IP2STR(&event->ip_info.ip));
        set_station_state(true, address);
        ESP_LOGI(TAG, "Home Wi-Fi connected at %s", address);
        start_sntp_once();
    }
}

esp_err_t dmd_network_apply_credentials(const char *ssid, const char *password)
{
    if (ssid == NULL || password == NULL) {
        return ESP_ERR_INVALID_ARG;
    }

    wifi_config_t station = {0};
    strlcpy((char *)station.sta.ssid, ssid, sizeof(station.sta.ssid));
    strlcpy((char *)station.sta.password, password, sizeof(station.sta.password));
    station.sta.threshold.authmode = WIFI_AUTH_OPEN;
    station.sta.pmf_cfg.capable = true;
    station.sta.pmf_cfg.required = false;

    esp_wifi_disconnect();
    ESP_RETURN_ON_ERROR(
        esp_wifi_set_config(WIFI_IF_STA, &station),
        TAG,
        "set station configuration");
    if (ssid[0] == '\0') {
        set_station_state(false, "");
        return ESP_OK;
    }
    return esp_wifi_connect();
}

esp_err_t dmd_network_init(void)
{
    s_info_lock = xSemaphoreCreateMutex();
    if (s_info_lock == NULL) {
        return ESP_ERR_NO_MEM;
    }
    memset(&s_info, 0, sizeof(s_info));
    strlcpy(s_info.time_source, "Unset", sizeof(s_info.time_source));
    strlcpy(s_info.access_point_ip, "192.168.4.1", sizeof(s_info.access_point_ip));

    ESP_RETURN_ON_ERROR(esp_netif_init(), TAG, "initialize TCP/IP");
    ESP_RETURN_ON_ERROR(
        esp_event_loop_create_default(),
        TAG,
        "create event loop");
    s_station_netif = esp_netif_create_default_wifi_sta();
    esp_netif_t *ap_netif = esp_netif_create_default_wifi_ap();
    if (s_station_netif == NULL || ap_netif == NULL) {
        return ESP_ERR_NO_MEM;
    }

    wifi_init_config_t init = WIFI_INIT_CONFIG_DEFAULT();
    ESP_RETURN_ON_ERROR(esp_wifi_init(&init), TAG, "initialize Wi-Fi");
    ESP_RETURN_ON_ERROR(
        esp_event_handler_register(WIFI_EVENT, ESP_EVENT_ANY_ID, network_event, NULL),
        TAG,
        "register Wi-Fi events");
    ESP_RETURN_ON_ERROR(
        esp_event_handler_register(IP_EVENT, IP_EVENT_STA_GOT_IP, network_event, NULL),
        TAG,
        "register IP events");

    uint8_t mac[6];
    ESP_RETURN_ON_ERROR(esp_wifi_get_mac(WIFI_IF_AP, mac), TAG, "read MAC");
    snprintf(
        s_info.access_point_ssid,
        sizeof(s_info.access_point_ssid),
        "DMDClock-%02X%02X",
        mac[4],
        mac[5]);

    wifi_config_t access_point = {0};
    strlcpy(
        (char *)access_point.ap.ssid,
        s_info.access_point_ssid,
        sizeof(access_point.ap.ssid));
    access_point.ap.ssid_len = strlen(s_info.access_point_ssid);
    strlcpy(
        (char *)access_point.ap.password,
        AP_PASSWORD,
        sizeof(access_point.ap.password));
    access_point.ap.channel = 6;
    access_point.ap.max_connection = 4;
    access_point.ap.authmode = WIFI_AUTH_WPA2_PSK;
    access_point.ap.pmf_cfg.capable = true;
    access_point.ap.pmf_cfg.required = false;

    dmd_settings_t settings;
    dmd_settings_get(&settings);
    wifi_config_t station = {0};
    strlcpy(
        (char *)station.sta.ssid,
        settings.wifi_ssid,
        sizeof(station.sta.ssid));
    strlcpy(
        (char *)station.sta.password,
        settings.wifi_password,
        sizeof(station.sta.password));
    station.sta.threshold.authmode = WIFI_AUTH_OPEN;
    station.sta.pmf_cfg.capable = true;
    station.sta.pmf_cfg.required = false;

    ESP_RETURN_ON_ERROR(esp_wifi_set_mode(WIFI_MODE_APSTA), TAG, "set AP+station mode");
    ESP_RETURN_ON_ERROR(
        esp_wifi_set_config(WIFI_IF_AP, &access_point),
        TAG,
        "configure access point");
    ESP_RETURN_ON_ERROR(
        esp_wifi_set_config(WIFI_IF_STA, &station),
        TAG,
        "configure station");
    ESP_RETURN_ON_ERROR(esp_wifi_start(), TAG, "start Wi-Fi");

    ESP_LOGI(
        TAG,
        "Remote control: connect to %s using password '%s', then open http://192.168.4.1/",
        s_info.access_point_ssid,
        AP_PASSWORD);
    return ESP_OK;
}

#endif

void dmd_network_get_info(dmd_network_info_t *info)
{
    if (info == NULL || s_info_lock == NULL) {
        return;
    }
    xSemaphoreTake(s_info_lock, portMAX_DELAY);
    *info = s_info;
    xSemaphoreGive(s_info_lock);
}

esp_err_t dmd_network_request_ntp_sync(void)
{
    if (!s_sntp_initialized) {
        return ESP_ERR_INVALID_STATE;
    }
    xSemaphoreTake(s_info_lock, portMAX_DELAY);
    s_info.ntp_syncing = true;
    xSemaphoreGive(s_info_lock);
    esp_err_t error = esp_netif_sntp_start();
    if (error != ESP_OK) {
        xSemaphoreTake(s_info_lock, portMAX_DELAY);
        s_info.ntp_syncing = false;
        xSemaphoreGive(s_info_lock);
    }
    return error;
}

void dmd_network_note_browser_time(void)
{
    if (s_info_lock == NULL) {
        return;
    }
    xSemaphoreTake(s_info_lock, portMAX_DELAY);
    if (!s_info.ntp_synced) {
        strlcpy(s_info.time_source, "Browser", sizeof(s_info.time_source));
    }
    xSemaphoreGive(s_info_lock);
}
