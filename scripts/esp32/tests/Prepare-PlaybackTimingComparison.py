"""Prepare isolated, instrumented Waveshare 7 snapshots; never flashes a device."""
from datetime import datetime, timezone
import hashlib
import io
import json
from pathlib import Path
import shutil
import subprocess
import tarfile
import difflib
import argparse

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / 'output/esp32/timing-comparison' / datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')

HEADER = r'''
#pragma once
#include <stdbool.h>
#include <stdint.h>
void timing_probe_step(uint16_t step, uint16_t frame, uint16_t delay, int64_t loop, int64_t decoded);
void timing_probe_finished(int64_t now);
void timing_probe_painted(int64_t now);
void timing_probe_task(void *context);
'''

PROBE = r'''
#include "timing_probe.h"
#include "dmd_display.h"
#include "dmd_scene.h"
#include "dmd_settings.h"
#include "esp_timer.h"
#include "esp_check.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include <stdio.h>

typedef struct { uint16_t frame, delay; int64_t loop, decoded, painted; } sample_t;
static sample_t samples[514];
static volatile unsigned count;
static volatile int64_t finished;
static volatile bool active;
void timing_probe_step(uint16_t step, uint16_t frame, uint16_t delay, int64_t loop, int64_t decoded) {
    if (!active || step >= 514) return;
    samples[step] = (sample_t){.frame=frame,.delay=delay,.loop=loop,.decoded=decoded};
    count=step+1;
}
void timing_probe_finished(int64_t now) { if (active && count) { finished=now; active=false; } }
void timing_probe_painted(int64_t now) {
    if (active && count && !samples[count-1].painted) samples[count-1].painted=now;
}
void timing_probe_task(void *context) {
    (void)context;
    vTaskDelay(pdMS_TO_TICKS(22000)); // Let the newer startup overlay expire before sampling.
    const uint16_t scenes[] = {1,2,4,7};
    for (unsigned preset=0;preset<2;preset++) {
      for (unsigned repeat=0;repeat<2;repeat++) {
        for (unsigned j=0;j<sizeof(scenes)/sizeof(scenes[0]);j++) {
          dmd_settings_t settings;
          dmd_settings_get(&settings);
          settings.color_preset=preset ? DMD_COLOR_PLASMA : DMD_COLOR_ORANGE;
          ESP_ERROR_CHECK(dmd_settings_update(&settings));
          dmd_display_show_clock();
          vTaskDelay(pdMS_TO_TICKS(300));
          count=0; finished=0; active=true;
          printf("TIMING REQUEST preset=%u repeat=%u index=%u\n",preset,repeat,scenes[j]);
          dmd_display_play_scene(scenes[j]);
          int64_t deadline=esp_timer_get_time()+25000000;
          while (!finished && esp_timer_get_time()<deadline) vTaskDelay(pdMS_TO_TICKS(10));
          active=false;
          if (!finished) { printf("TIMING ERROR timeout count=%u\n",count); vTaskDelete(NULL); return; }
          dmd_scene_info_t scene;
          dmd_scene_get_info(&scene);
          printf("TIMING RESULT name=%s preset=%u repeat=%u count=%u expected_steps=%u start=%lld end=%lld\n",
            scene.file_name,preset,repeat,count,scene.step_count,(long long)samples[0].decoded,(long long)finished);
          for (unsigned k=0;k<count;k++) printf("TIMING STEP n=%u frame=%u delay=%u loop=%lld decoded=%lld painted=%lld\n",
            k,samples[k].frame,samples[k].delay,(long long)samples[k].loop,(long long)samples[k].decoded,(long long)samples[k].painted);
          printf("TIMING END\n");
          vTaskDelay(pdMS_TO_TICKS(300));
        }
      }
    }
    printf("TIMING ALL_DONE\n");
    vTaskDelete(NULL);
}
'''

REFERENCE_DRIVER = r'''
// UART control belongs only to this isolated reference image, not production firmware.
#include "driver/uart.h"
#include <string.h>
#include <sys/time.h>
static void reference_auto(void) {
    active=false; finished=0;
    dmd_settings_t s; dmd_settings_get(&s);
    s.automatic_cycle=true; s.random_playback=false; s.animations_per_cycle=1;
    s.clock_display_seconds=5; s.animation_gap_seconds=0;
    s.color_preset=DMD_COLOR_ORANGE;
    ESP_ERROR_CHECK(dmd_settings_update(&s));
    dmd_display_play_scene(1);
    printf("REFERENCE AUTO\n");
}
void timing_probe_task(void *context) {
    (void)context;
    ESP_ERROR_CHECK(uart_driver_install(UART_NUM_0,2048,0,0,NULL,0));
    vTaskDelay(pdMS_TO_TICKS(2000));
    reference_auto();
    printf("REFERENCE READY source=SOURCE_REV commands=PLAY-index-mode,TIME-epoch,AUTO,STATE\n");
    char line[96]; unsigned used=0; unsigned selected=0, preset=0;
    for (;;) {
        uint8_t input[64];
        int length=uart_read_bytes(UART_NUM_0,input,sizeof(input),pdMS_TO_TICKS(50));
        for (int j=0;j<length;j++) {
            if (input[j]=='\r') continue;
            if (input[j]!='\n') { if (used<sizeof(line)-1) line[used++]=(char)input[j]; continue; }
            line[used]=0; used=0;
            long long epoch;
            if (sscanf(line,"PLAY %u %u",&selected,&preset)==2 && selected<dmd_scene_count() && preset<=1) {
                active=false; finished=0;
                dmd_settings_t s; dmd_settings_get(&s);s.automatic_cycle=false;
                s.color_preset=preset ? DMD_COLOR_PLASMA : DMD_COLOR_ORANGE;
                ESP_ERROR_CHECK(dmd_settings_update(&s));
                dmd_display_show_clock();vTaskDelay(pdMS_TO_TICKS(300));
                count=0;active=true;dmd_display_play_scene(selected);
                printf("REFERENCE PLAY index=%u preset=%u\n",selected,preset);
            } else if (sscanf(line,"TIME %lld",&epoch)==1 && epoch>=1704067200 && epoch<2208988800LL) {
                struct timeval tv={.tv_sec=epoch,.tv_usec=0};settimeofday(&tv,NULL);
                printf("REFERENCE TIME epoch=%lld\n",epoch);
            } else if (strcmp(line,"AUTO")==0) reference_auto();
            else if (strcmp(line,"STATE")==0) {
                dmd_display_state_t s;dmd_display_get_state(&s);
                printf("REFERENCE STATE playing=%u index=%u step=%u frame=%u\n",s.playing_scene,s.scene_index,s.scene_step,s.scene_frame);
            }
        }
        if (finished) {
            dmd_scene_info_t s;dmd_scene_get_info(&s);
            printf("REFERENCE RESULT index=%u preset=%u name=%s count=%u start=%lld end=%lld\n",
                selected,preset,s.file_name,count,(long long)samples[0].decoded,(long long)finished);
            for (unsigned k=0;k<count;k++) printf("TIMING STEP n=%u frame=%u delay=%u loop=%lld decoded=%lld painted=%lld\n",
                k,samples[k].frame,samples[k].delay,(long long)samples[k].loop,(long long)samples[k].decoded,(long long)samples[k].painted);
            printf("REFERENCE END\n");finished=0;
        }
    }
}
'''

def replace(path, old, new, count=None):
    text=path.read_text()
    if old not in text: raise RuntimeError(f'Missing instrumentation anchor in {path}: {old}')
    path.write_text(text.replace(old,new) if count is None else text.replace(old,new,count))


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--snapshot',action='append',help='LABEL=GIT_REF; default is oldest and latest')
    parser.add_argument('--targeted',action='store_true',help='Six Plasma repetitions of RD1116 only')
    parser.add_argument('--reference',action='store_true',help='Continuous reference playback with isolated UART test controls')
    parser.add_argument('--pilot',action='store_true',help='Ten real scenes, one Basic repetition each')
    parser.add_argument('--sd-log',action='store_true',help='SD scenes and durable per-case timing logs with USB control')
    parser.add_argument('--stable-board',choices=['Waveshare7','Waveshare349B'],help='Use common stable hardware drivers, including on oldest hybrid')
    parser.add_argument('--output',type=Path)
    args=parser.parse_args()
    global OUT
    if args.output:OUT=args.output.resolve()
    pairs=[tuple(item.split('=',1)) for item in args.snapshot] if args.snapshot else [('oldest','90cee54'),('latest','v1.8.0')]
    OUT.mkdir(parents=True)
    manifest=[]
    sources={}
    for position,(label,ref) in enumerate(pairs):
        if not label.replace('-','').replace('_','').isalnum():raise RuntimeError('Invalid snapshot label')
        sources[label]=subprocess.check_output(['git','-C',str(ROOT),'rev-parse',f'{ref}^{{commit}}']).decode().strip()
        folder=OUT/label
        folder.mkdir()
        data=subprocess.check_output(['git','-C',str(ROOT),'archive',ref])
        with tarfile.open(fileobj=io.BytesIO(data)) as archive:
            archive.extractall(folder,filter='data')
        project=folder/'firmware/dmdclock-esp32'
        main=project/'main'
        (project/'partitions.timing.csv').write_text('nvs,data,nvs,0x9000,0x6000,\nphy_init,data,phy,0xf000,0x1000,\nfactory,app,factory,0x10000,4M,\n')
        with (project/'sdkconfig.defaults').open('a') as defaults:
            defaults.write('\nCONFIG_PARTITION_TABLE_SINGLE_APP_LARGE=n\nCONFIG_PARTITION_TABLE_CUSTOM=y\nCONFIG_PARTITION_TABLE_CUSTOM_FILENAME="partitions.timing.csv"\n')
            if args.sd_log:defaults.write('CONFIG_FATFS_LFN_NONE=n\nCONFIG_FATFS_LFN_HEAP=y\nCONFIG_FATFS_MAX_LFN=255\n')
        # Same in-flash fixture library and no SD mounting in both hardware builds.
        # CONFIG_DMD_QEMU remains disabled for the panel, CPU, network, and renderer.
        scene=main/'dmd_scene.c'
        if not args.sd_log:replace(scene,'#if CONFIG_DMD_QEMU','#if 1 /* hardware timing fixture library */')
        if not args.sd_log and '#if !CONFIG_DMD_QEMU' in scene.read_text():
            replace(scene,'#if !CONFIG_DMD_QEMU','#if 0 /* hardware timing uses the embedded fixture table */')
        replace(scene,'RD0868.scn','APOLLO_13_009.scn')
        cmake=main/'CMakeLists.txt'
        text=cmake.read_text()
        if not args.sd_log:
            start=text.index('if(CONFIG_DMD_QEMU)')
            middle=text.index('    set(DMD_EMBEDDED_SCENES',start)
            end=text.index('\n    )',middle)+len('\n    )')
            embedded=text[middle:end].replace('RD0868.scn','APOLLO_13_009.scn')
            finish=text.index('foreach(DMD_EMBEDDED_SCENE',end)
            # Only the fixture embedding block is replaced; renderer QEMU flags stay off.
            text=text[:start]+embedded+'\n'+text[finish:]
        text=text.replace('"app_main.c"','"app_main.c"\n        "timing_probe.c"',1)
        if args.reference:text=text.replace('REQUIRES','REQUIRES\n        esp_driver_uart',1)
        if args.sd_log:text=text.replace('REQUIRES','REQUIRES\n        esp_driver_uart\n        esp_driver_usb_serial_jtag\n        mbedtls',1)
        cmake.write_text(text)
        (main/'timing_probe.h').write_text((ROOT/'scripts/esp32/tests/fixtures/sd_timing_probe.h').read_text() if args.sd_log else HEADER)
        probe=PROBE
        if args.sd_log:
            probe=(ROOT/'scripts/esp32/tests/fixtures/sd_timing_probe.c').read_text().replace('@VARIANT@',label).replace('@SOURCE@',sources[label]).replace('@BOARD@',args.stable_board or 'Waveshare7')
        if args.targeted:
            probe=probe.replace('const uint16_t scenes[] = {1,2,4,7};','const uint16_t scenes[] = {4};').replace('unsigned preset=0;','unsigned preset=1;').replace('repeat<2','repeat<6')
        if args.pilot:
            probe=probe.replace('const uint16_t scenes[] = {1,2,4,7};','const uint16_t scenes[] = {1,2,3,4,5,6,7,8,9,10};').replace('preset<2','preset<1').replace('repeat<2','repeat<1').replace('+25000000','+180000000')
        if args.reference:
            driver=REFERENCE_DRIVER.replace('SOURCE_REV',sources[label][:7])
            if 'STARTUP_NETWORK_STATUS_US' in (main/'dmd_display.c').read_text():driver=driver.replace('pdMS_TO_TICKS(2000)','pdMS_TO_TICKS(22000)')
            probe=probe[:probe.index('void timing_probe_task(void *context) {')]+driver
        (main/'timing_probe.c').write_text(probe)
        app=main/'app_main.c'
        replace(app,'#include "dmd_board.h"','#include "timing_probe.h"\n#include <stdio.h>\n#include <sys/time.h>\n#include "dmd_board.h"',1)
        if not args.sd_log:replace(app,'ESP_ERROR_CHECK(dmd_storage_init());','/* Timing comparison: SD card is left unmounted and untouched. */',1)
        common='''
    settings.play_scene=false;
    settings.automatic_cycle=false;
    settings.display_on=true;
    settings.brightness=100;
    settings.glow_strength=50;
    settings.show_information=false;
    settings.show_seconds=false;
    settings.use_24_hour=true;
    settings.color_preset=DMD_COLOR_ORANGE;
    settings.plasma_cycle_ms=8000;
    settings.plasma_palette=0;
    settings.scene_index=0;
    settings.wifi_ssid[0]=0;
    settings.wifi_password[0]=0;
'''
        settings_header=(main/'dmd_settings.h').read_text()
        for field in ['screen_schedule_enabled','reboot_schedule_enabled','hot_core_enabled','playback_log_enabled','mqtt_enabled','lan_only_web']:
            if field in settings_header:common+=f'    settings.{field}=false;\n'
        if 'orientation_mode' in settings_header:common+='    settings.orientation_mode=DMD_ORIENTATION_FIXED;\n    settings.fixed_rotation=0;\n'
        if 'clock_font_id' in settings_header:common+='    snprintf(settings.clock_font_id,sizeof(settings.clock_font_id),"builtin-5x7");\n'
        common+='''
    ESP_ERROR_CHECK(dmd_settings_update(&settings));
    struct timeval timing_now={.tv_sec=1704067200,.tv_usec=0};
    settimeofday(&timing_now,NULL);
'''
        replace(app,'dmd_settings_get(&settings);','dmd_settings_get(&settings);'+common,1)
        replace(app,'ESP_ERROR_CHECK(created == pdPASS ? ESP_OK : ESP_ERR_NO_MEM);',
            'ESP_ERROR_CHECK(created == pdPASS ? ESP_OK : ESP_ERR_NO_MEM);\n    BaseType_t probe_created=xTaskCreatePinnedToCore(timing_probe_task,"timing_probe",8192,NULL,3,NULL,1);\n    ESP_ERROR_CHECK(probe_created == pdPASS ? ESP_OK : ESP_ERR_NO_MEM);',1)
        if args.sd_log:replace(app,'"timing_probe",8192,NULL','"timing_probe",16384,NULL',1)
        display=main/'dmd_display.c'
        replace(display,'#include "dmd_display.h"','#include "dmd_display.h"\n#include "timing_probe.h"',1)
        replace(display,'if (scene_step >= scene.step_count) {','if (scene_step >= scene.step_count) {\n                timing_probe_finished(esp_timer_get_time());',1)
        replace(display,'next_scene_frame_at =\n                    monotonic_now + (int64_t)step_info.duration_ms * 1000;',
            'timing_probe_step(scene_step,step_info.frame_index,step_info.duration_ms,monotonic_now,esp_timer_get_time());\n                next_scene_frame_at =\n                    monotonic_now + (int64_t)step_info.duration_ms * 1000;',1)
        replace(display,'refresh_display();','refresh_display();\n                timing_probe_painted(esp_timer_get_time());')
        if args.stable_board:
            stable=ROOT/'firmware/dmdclock-esp32/main'
            # Adapt only hardware initialization/presentation in the oldest monolithic display.
            if 'static esp_lcd_panel_handle_t s_panel;' in display.read_text():
                text=display.read_text().replace('static esp_lcd_panel_handle_t s_panel;','')
                begin=text.index('#define LCD_WIDTH 800');end=text.index('#define CONTROL_VISIBLE_US',begin)
                text=text[:begin]+'#include "dmd_geometry.h"\n#include "dmd_panel.h"\n\n'+text[end:]
                begin=text.index('static void refresh_display(void)');end=text.index('esp_err_t dmd_display_init(void)',begin)
                text=text[:begin]+'''static void refresh_display(void) {
    ESP_ERROR_CHECK(dmd_panel_present(0));
    s_framebuffer=dmd_panel_begin_frame();
    timing_probe_painted(esp_timer_get_time());
}

'''+text[end:]
                begin=text.index('#if CONFIG_DMD_QEMU',text.index('esp_err_t dmd_display_init(void)'))
                end=text.index('    s_state_lock = xSemaphoreCreateMutex();',begin)
                text=text[:begin]+'''    ESP_RETURN_ON_ERROR(dmd_panel_init(),TAG,"stable panel init");
    s_framebuffer=dmd_panel_begin_frame();
'''+text[end:]
                display.write_text(text)
                for name in ['dmd_board.c','dmd_board.h','dmd_geometry.h','dmd_panel.h','dmd_panel_waveshare7.c','dmd_panel_waveshare349b.c','Kconfig.projbuild','idf_component.yml']:
                    shutil.copyfile(stable/name,main/name)
                if args.sd_log:
                    for name in ['dmd_storage.c','dmd_storage.h']:shutil.copyfile(stable/name,main/name)
                text=cmake.read_text().replace('"dmd_display.c"','"dmd_display.c"\n        "dmd_panel_waveshare7.c"\n        "dmd_panel_waveshare349b.c"',1)
                text=text.replace('REQUIRES','REQUIRES\n        esp_driver_spi',1)
                cmake.write_text(text)
            with (project/'sdkconfig.defaults').open('a') as defaults:
                defaults.write('\nCONFIG_DMD_QEMU=n\nCONFIG_ESPTOOLPY_FLASHMODE_QIO=n\nCONFIG_ESPTOOLPY_FLASHMODE_DIO=y\n')
                if args.stable_board=='Waveshare349B':defaults.write('CONFIG_DMD_BOARD_WAVESHARE_7=n\nCONFIG_DMD_BOARD_3_49_LANDSCAPE=y\n')
        if args.sd_log:
            replace(scene,'#include "dmd_scene.h"','#include "dmd_scene.h"\n#include "timing_probe.h"\n#include "esp_timer.h"\n#include "mbedtls/sha256.h"',1)
            anchor='ESP_RETURN_ON_ERROR(load_scene_data(scene), TAG, "load scene data");'
            replace(scene,anchor,'int64_t timing_load_start=esp_timer_get_time();\n    '+anchor+'\n    timing_probe_loaded(timing_load_start,esp_timer_get_time());',1)
            with scene.open('a') as target:
                target.write('''
// Diagnostic selection only: retain each snapshot's parser, decoder, and scheduler.
static char timing_selected_name[96];
esp_err_t timing_scene_choose(const char *name) {
    if (!dmd_storage_available() || s_scene_count==0 || strlen(name)>=sizeof(timing_selected_name)) return ESP_ERR_INVALID_STATE;
    xSemaphoreTake(s_lock,portMAX_DELAY);
    strcpy(timing_selected_name,name);
    s_scenes[0]=(scene_blob_t){.file_name=timing_selected_name,.display_name=timing_selected_name};
    s_info.index=UINT8_MAX; // invalidate the original same-index selection cache
    xSemaphoreGive(s_lock);
    return dmd_scene_select(0);
}
void timing_scene_hash(char output[65]) {
    unsigned char digest[32];mbedtls_sha256(s_data,s_size,digest,0);
    for(unsigned i=0;i<32;i++) sprintf(output+i*2,"%02x",digest[i]);
    output[64]=0;
}
''')
        if args.pilot:
            # Include the longest real fixture as well as the existing timing cases.
            replace(scene,'RD1701.scn','got03.scn')
            replace(cmake,'RD1701.scn','got03.scn')
            replace(scene,'RD1385.scn','RD0033.scn')
            replace(cmake,'RD1385.scn','RD0033.scn')
        names=['got06','afm01','APOLLO_13_009','RD0959','RD1116','RD1385','RD1448','RD1474','RD1695','RD1701','RD1891']
        if args.pilot:names[9]='got03';names[5]='RD0033'
        (folder/'scenes').mkdir(exist_ok=True)
        for name in names:
            source=ROOT/'scenes'/f'{name}.scn'
            shutil.copyfile(source,folder/'scenes'/source.name)
            if position==0:manifest.append(dict(name=source.name,sha256=hashlib.sha256(source.read_bytes()).hexdigest()))
        # Copy component dependencies; do not share a mutable manager directory.
        shutil.copytree(ROOT/'firmware/dmdclock-esp32/managed_components',project/'managed_components',dirs_exist_ok=True)
        (folder/'timing-modifications.diff').write_text(''.join(''.join(difflib.unified_diff(
            subprocess.check_output(['git','-C',str(ROOT),'show',f'{ref}:firmware/dmdclock-esp32/main/{name}']).decode().splitlines(True),
            (main/name).read_text().splitlines(True),fromfile=f'{ref}/{name}',tofile=f'instrumented/{name}'))
            for name in ['app_main.c','dmd_display.c','dmd_scene.c','CMakeLists.txt']))
        print(f'{label}: {project}',flush=True)
    (OUT/'scene-manifest.json').write_text(json.dumps(manifest,indent=2))
    (OUT/'probe-source.json').write_text(json.dumps(dict(snapshots=sources,targeted=args.targeted,referenceMode=args.reference,pilot=args.pilot,sdLog=args.sd_log,stableBoard=args.stable_board,qualification=('SD scene loading with durable diagnostic logs; parser/decoder/scheduler retained. Oldest uses stable board/panel/storage drivers and diagnostic scene selection; hybrid.' if args.sd_log else 'Instrumented hardware snapshots. In-flash identical fixtures, SD unmounted, scene deadlines retained. Oldest plus stable-board is a hardware-driver hybrid.')),indent=2))
    print(OUT)

if __name__=='__main__':main()
