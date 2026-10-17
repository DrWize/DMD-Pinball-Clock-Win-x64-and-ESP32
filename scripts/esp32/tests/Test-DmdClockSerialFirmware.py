"""Run the production serial reader/protocol with simulated ESP-IDF transports."""
from pathlib import Path
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[3]
GCC = Path(r'C:\msys64\mingw64\bin\gcc.exe')
IDF = ROOT.parent / '.tools/esp-idf/v5.5.2/esp-idf'
JSON = IDF / 'components/json/cJSON'
STUBS = {
    'sdkconfig.h': '#define CONFIG_DMD_QEMU 0\n#define CONFIG_DMD_BOARD_3_49_LANDSCAPE 1\n#define CONFIG_ESP_CONSOLE_SECONDARY_USB_SERIAL_JTAG 1\n#define CONFIG_DMD_DMD_SCALE 5\n#define CONFIG_DMD_DISPLAY_WIDTH 640\n#define CONFIG_DMD_DISPLAY_HEIGHT 172\n',
    'esp_err.h': '#pragma once\ntypedef int esp_err_t;\n#define ESP_OK 0\n#define ESP_ERR_NOT_SUPPORTED 1\n#define ESP_ERR_NO_MEM 2\n',
    'esp_app_desc.h': '#pragma once\ntypedef struct {char version[32];} esp_app_desc_t;\nconst esp_app_desc_t *esp_app_get_description(void);\n',
    'esp_mac.h': '#pragma once\n#include <stdint.h>\n#include "esp_err.h"\n#define ESP_MAC_WIFI_STA 0\nesp_err_t esp_read_mac(uint8_t *, int);\n',
    'esp_timer.h': '#pragma once\n#include <stdint.h>\nint64_t esp_timer_get_time(void);\n',
    'esp_wifi.h': '#pragma once\n#include <stdint.h>\n#include "esp_err.h"\ntypedef struct {uint8_t ssid[33];} wifi_ap_record_t;\nesp_err_t esp_wifi_sta_get_ap_info(wifi_ap_record_t *);\n',
    'freertos/FreeRTOS.h': '#pragma once\n#define pdPASS 1\n#define pdMS_TO_TICKS(x) (x)\n',
    'freertos/task.h': '#pragma once\nint xTaskCreate(void (*)(void *),const char *,unsigned,void *,unsigned,void *);\nvoid vTaskDelay(int);\n',
    'driver/usb_serial_jtag.h': '#pragma once\n#include <stdbool.h>\n#include <stdint.h>\n#include "esp_err.h"\ntypedef struct {uint32_t tx_buffer_size; uint32_t rx_buffer_size;} usb_serial_jtag_driver_config_t;\nbool usb_serial_jtag_is_driver_installed(void);\nesp_err_t usb_serial_jtag_driver_install(usb_serial_jtag_driver_config_t *);\nesp_err_t usb_serial_jtag_driver_uninstall(void);\n',
    'driver/uart.h': '#pragma once\n#include <stdbool.h>\n#include <stdint.h>\n#include "esp_err.h"\n#define UART_NUM_0 0\nbool uart_is_driver_installed(int);\nesp_err_t uart_driver_install(int,int,int,int,void*,int);\nesp_err_t uart_driver_delete(int);\nint uart_read_bytes(int,void*,uint32_t,int);\n',
    'driver/uart_vfs.h': '#pragma once\nvoid uart_vfs_dev_use_driver(int);\nvoid uart_vfs_dev_use_nonblocking(int);\n',
    'driver/usb_serial_jtag_vfs.h': '#pragma once\nvoid usb_serial_jtag_vfs_use_driver(void);\nvoid usb_serial_jtag_vfs_use_nonblocking(void);\n',
}

if not GCC.is_file() or not (JSON / 'cJSON.c').is_file():
    raise SystemExit('Requires the existing MinGW GCC and ESP-IDF 5.5.2 installation.')
env = dict(os.environ, PATH=str(GCC.parent) + os.pathsep + os.environ['PATH'])
with tempfile.TemporaryDirectory(prefix='dmd-serial-test-') as folder:
    temp = Path(folder)
    STUBS['driver/usb_serial_jtag.h'] += 'int usb_serial_jtag_read_bytes(void*,uint32_t,int);\n'
    STUBS['driver/usb_serial_jtag.h'] += '#include <stddef.h>\nint usb_serial_jtag_write_bytes(const void*,size_t,int);\n'
    STUBS['driver/uart.h'] += '#include <stddef.h>\nint uart_write_bytes(int,const void*,size_t);\n'
    for name, text in STUBS.items():
        path = temp / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
    exe = temp / 'serial-test.exe'
    subprocess.run([str(GCC), '-std=gnu11', '-Wall', '-Wextra', '-Werror',
        '-Wno-unused-parameter', '-I', str(temp), '-I', str(JSON),
        '-I', str(ROOT / 'firmware/dmdclock-esp32/main'),
        str(Path(__file__).with_suffix('.c')), str(JSON / 'cJSON.c'),
        '-o', str(exe)], check=True, env=env)
    subprocess.run([str(exe)], check=True, env=env)
