#pragma once
#include "esp_err.h"
#include <stdbool.h>
#include <stdint.h>

typedef struct {
    bool running;
    uint32_t polls;
    uint32_t uart_rx_bytes;
    uint32_t usb_rx_bytes;
    uint32_t requests;
} dmd_serial_diagnostics_t;

esp_err_t dmd_serial_init(void);
void dmd_serial_get_diagnostics(dmd_serial_diagnostics_t *out);
// Timing replies use the request's transport and one atomic driver write.
bool dmd_serial_timing_reply(const char *json);
