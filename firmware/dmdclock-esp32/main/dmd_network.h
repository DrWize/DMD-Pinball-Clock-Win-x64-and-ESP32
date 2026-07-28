#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <time.h>

#include "esp_err.h"

typedef struct {
    bool station_connected;
    char station_ip[16];
    char access_point_ssid[33];
    char access_point_ip[16];
    bool ntp_started;
    bool ntp_syncing;
    bool ntp_synced;
    time_t ntp_last_sync;
    char time_source[16];
} dmd_network_info_t;

esp_err_t dmd_network_init(void);
esp_err_t dmd_network_apply_credentials(const char *ssid, const char *password);
void dmd_network_get_info(dmd_network_info_t *info);
esp_err_t dmd_network_request_ntp_sync(void);
void dmd_network_note_browser_time(void);
