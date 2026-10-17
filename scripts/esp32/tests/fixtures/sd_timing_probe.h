#pragma once
#include <stdint.h>
#include "esp_err.h"
void timing_probe_step(uint16_t step,uint16_t frame,uint16_t delay,int64_t loop,int64_t decoded);
void timing_probe_finished(int64_t now);
void timing_probe_painted(int64_t now);
void timing_probe_loaded(int64_t start,int64_t end);
void timing_probe_task(void *context);
esp_err_t timing_scene_choose(const char *name);
void timing_scene_hash(char output[65]);
