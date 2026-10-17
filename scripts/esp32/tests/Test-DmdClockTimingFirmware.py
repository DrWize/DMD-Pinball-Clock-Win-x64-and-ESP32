"""Exercise the production capture module with simulated display/SD failures."""
import ast
from pathlib import Path
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[3]
GCC = Path(r'C:\msys64\mingw64\bin\gcc.exe')
JSON = ROOT.parent / '.tools/esp-idf/v5.5.2/esp-idf/components/json/cJSON'
tree = ast.parse(Path(__file__).with_name('Test-DmdClockSerialFirmware.py').read_text())
stubs = ast.literal_eval(next(node.value for node in tree.body if isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == 'STUBS' for t in node.targets)))
stubs.update({
    'esp_app_desc.h': '#pragma once\n#include <stdint.h>\ntypedef struct {char version[32]; uint8_t app_elf_sha256[32];} esp_app_desc_t;\nconst esp_app_desc_t *esp_app_get_description(void);\n',
    'esp_heap_caps.h': '#pragma once\n#include <stddef.h>\n#define MALLOC_CAP_SPIRAM 1\n#define MALLOC_CAP_8BIT 2\nvoid *heap_caps_calloc(size_t,size_t,int);\n',
    'freertos/FreeRTOS.h': '#pragma once\n#define pdTRUE 1\n#define pdPASS 1\n#define pdMS_TO_TICKS(x) (x)\n',
    'freertos/semphr.h': '#pragma once\ntypedef void *SemaphoreHandle_t;\nSemaphoreHandle_t xSemaphoreCreateBinary(void);\nint xSemaphoreTake(SemaphoreHandle_t,int);\nint xSemaphoreGive(SemaphoreHandle_t);\n',
    'mbedtls/sha256.h': '#pragma once\n#include <stddef.h>\ntypedef struct {int unused;} mbedtls_sha256_context;\nvoid mbedtls_sha256_init(mbedtls_sha256_context*);\nvoid mbedtls_sha256_free(mbedtls_sha256_context*);\nint mbedtls_sha256_starts(mbedtls_sha256_context*,int);\nint mbedtls_sha256_update(mbedtls_sha256_context*,const unsigned char*,size_t);\nint mbedtls_sha256_finish(mbedtls_sha256_context*,unsigned char*);\n',
})
env = dict(os.environ, PATH=str(GCC.parent) + os.pathsep + os.environ['PATH'])
with tempfile.TemporaryDirectory(prefix='dmd-capture-test-') as folder:
    temp = Path(folder)
    for name, text in stubs.items():
        path = temp / name; path.parent.mkdir(parents=True, exist_ok=True); path.write_text(text)
    exe = temp / 'capture-test.exe'
    subprocess.run([str(GCC), '-std=gnu11', '-Wall', '-Wextra', '-Werror', '-Wno-unused-parameter',
        '-I', str(temp), '-I', str(JSON), '-I', str(ROOT / 'firmware/dmdclock-esp32/main'),
        str(Path(__file__).with_suffix('.c')), str(JSON / 'cJSON.c'), '-o', str(exe)], check=True, env=env)
    subprocess.run([str(exe)], check=True, env=env, cwd=temp)
