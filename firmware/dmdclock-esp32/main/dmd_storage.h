#pragma once

#include <stdbool.h>

#include "esp_err.h"

#define DMD_STORAGE_ROOT "/sd/dmd"
#define DMD_STORAGE_SCENES DMD_STORAGE_ROOT "/scenes"
#define DMD_STORAGE_PLASMA DMD_STORAGE_ROOT "/plasma"

esp_err_t dmd_storage_init(void);
bool dmd_storage_available(void);
