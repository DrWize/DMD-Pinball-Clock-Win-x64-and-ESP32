// Compiled only into isolated diagnostic firmware. No production behavior changes.
#include "timing_probe.h"
#include "dmd_display.h"
#include "dmd_scene.h"
#include "dmd_storage.h"
#include "driver/uart.h"
#include "driver/usb_serial_jtag.h"
#include "esp_timer.h"
#include "esp_check.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "mbedtls/sha256.h"
#include "sdkconfig.h"
#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <unistd.h>

#define VARIANT "@VARIANT@"
#define SOURCE "@SOURCE@"
#define BOARD "@BOARD@"
#define LOG_ROOT DMD_STORAGE_LOGS "/timing"
#define SAMPLE_CAPACITY 514
typedef struct {uint16_t frame,delay;int64_t loop,decoded,painted;} sample_t;
static sample_t samples[SAMPLE_CAPACITY];
static volatile unsigned count;
static volatile bool active,overflow;
static volatile int64_t finished,load_start,load_end;
static char emission[2048];
static unsigned char file_block[4096];

void timing_probe_step(uint16_t step,uint16_t frame,uint16_t delay,int64_t loop,int64_t decoded) {
    if(!active)return;
    if(step>=SAMPLE_CAPACITY){overflow=true;return;}
    samples[step]=(sample_t){.frame=frame,.delay=delay,.loop=loop,.decoded=decoded};count=step+1;
}
void timing_probe_finished(int64_t now){if(active&&count){finished=now;active=false;}}
void timing_probe_painted(int64_t now){if(active&&count&&!samples[count-1].painted)samples[count-1].painted=now;}
void timing_probe_loaded(int64_t start,int64_t end){if(active){load_start=start;load_end=end;}}

static void send_bytes(const char *text,size_t size) {
#if CONFIG_DMD_BOARD_3_49_LANDSCAPE
    while(size){int n=usb_serial_jtag_write_bytes(text,size,pdMS_TO_TICKS(5000));if(n<=0)return;text+=n;size-=n;}
#else
    uart_write_bytes(UART_NUM_0,text,size);
#endif
}
static void emit(const char *format,...) {
    va_list arguments;va_start(arguments,format);int n=vsnprintf(emission,sizeof(emission),format,arguments);va_end(arguments);
    if(n>0&&n<(int)sizeof(emission))send_bytes(emission,(size_t)n);
}
static int receive(unsigned char *buffer,unsigned size) {
#if CONFIG_DMD_BOARD_3_49_LANDSCAPE
    return usb_serial_jtag_read_bytes(buffer,size,pdMS_TO_TICKS(100));
#else
    return uart_read_bytes(UART_NUM_0,buffer,size,pdMS_TO_TICKS(100));
#endif
}
static bool token(const char *value,unsigned limit) {
    unsigned n=strlen(value);if(!n||n>limit)return false;
    for(unsigned i=0;i<n;i++)if(!isalnum((unsigned char)value[i])&&value[i]!='-'&&value[i]!='_')return false;
    return true;
}
static void hex_name(const char *name,char *out) {
    for(unsigned i=0;name[i];i++)sprintf(out+i*2,"%02x",(unsigned char)name[i]);
}
static bool unhex(const char *hex,char *out,unsigned capacity) {
    unsigned length=strlen(hex);if(!length||length%2||length/2>=capacity)return false;
    for(unsigned i=0;i<length/2;i++){
        char pair[3]={hex[i*2],hex[i*2+1],0};char *end;long value=strtol(pair,&end,16);
        if(*end||value<32||value>126||value=='/'||value=='\\')return false;
        out[i]=(char)value;
    }
    out[length/2]=0;return strstr(out,"..") == NULL;
}
static bool file_hash(const char *path,char output[65],long *size) {
    FILE *file=fopen(path,"rb");if(!file)return false;
    mbedtls_sha256_context context;mbedtls_sha256_init(&context);mbedtls_sha256_starts(&context,0);
    unsigned char digest[32];size_t read;long total=0;
    while((read=fread(file_block,1,sizeof(file_block),file))){mbedtls_sha256_update(&context,file_block,read);total+=read;if((total&65535)==0)vTaskDelay(1);}
    bool ok=!ferror(file);fclose(file);mbedtls_sha256_finish(&context,digest);mbedtls_sha256_free(&context);
    for(unsigned i=0;i<32;i++)sprintf(output+i*2,"%02x",digest[i]);
    output[64]=0;if(size)*size=total;return ok;
}
static void inventory(void) {
    if(!dmd_storage_available()){emit("TIMING2 ERROR SD_UNAVAILABLE\n");return;}
    DIR *directory=opendir(DMD_STORAGE_SCENES);if(!directory){emit("TIMING2 ERROR SCENE_DIRECTORY\n");return;}
    unsigned files=0,failed=0;struct dirent *entry;
    while((entry=readdir(directory))){
        const char *ext=strrchr(entry->d_name,'.');if(!ext||strcasecmp(ext,".scn"))continue;
        char path[512],hex[192],hash[65];long size;
        if(strlen(entry->d_name)>90){failed++;continue;}
        snprintf(path,sizeof(path),"%s/%s",DMD_STORAGE_SCENES,entry->d_name);hex_name(entry->d_name,hex);
        if(!file_hash(path,hash,&size)){failed++;emit("TIMING2 INVENTORY_ERROR %s\n",hex);continue;}
        emit("TIMING2 INVENTORY %s %ld %s\n",hex,size,hash);files++;
    }
    closedir(directory);emit("TIMING2 INVENTORY_END %u %u\n",files,failed);
}
static bool case_path(char *out,size_t capacity,const char *run,const char *variant,const char *id,unsigned repetition) {
    if(!token(run,48)||!token(id,48)||(strcmp(variant,"oldest")&&strcmp(variant,"latest"))||repetition>9)return false;
    snprintf(out,capacity,LOG_ROOT "/%s/%s/%s-r%u.jsonl",run,variant,id,repetition);return true;
}
static bool committed_file(const char *path,char hash[65],long *size) {
    FILE *f=fopen(path,"rb");if(!f)return false;
    if(fseek(f,0,SEEK_END)!=0){fclose(f);return false;}long length=ftell(f);long start=length>120?length-120:0;
    fseek(f,start,SEEK_SET);char tail[121]={0};fread(tail,1,sizeof(tail)-1,f);fclose(f);
    return strstr(tail,"\"kind\":\"commit\"")&&file_hash(path,hash,size);
}
static bool make_directories(const char *run) {
    char path[192];mkdir(DMD_STORAGE_LOGS,0755);mkdir(LOG_ROOT,0755);
    snprintf(path,sizeof(path),LOG_ROOT "/%s",run);mkdir(path,0755);
    snprintf(path,sizeof(path),LOG_ROOT "/%s/" VARIANT,run);mkdir(path,0755);
    struct stat status;
    if(stat(path,&status)==0&&S_ISDIR(status.st_mode))return true;
    emit("TIMING2 LOG_DIRECTORY_ERROR errno=%d path=%s\n",errno,path);return false;
}
static void get_file(const char *run,const char *variant,const char *id,unsigned repetition) {
    char path[256],hash[65];long size;
    if(!case_path(path,sizeof(path),run,variant,id,repetition)||!committed_file(path,hash,&size)){emit("TIMING2 NOT_FOUND\n");return;}
    emit("TIMING2 FILE %ld %s\n",size,hash);
    FILE *f=fopen(path,"rb");if(!f){emit("TIMING2 ERROR READ\n");return;}
    char line[1536];while(fgets(line,sizeof(line),f))emit("TIMING2 RECORD %s",line);
    fclose(f);emit("TIMING2 FILE_END %s\n",hash);
}
static void run_case(const char *run,const char *id,unsigned repetition,const char *expected_hash,const char *name_hex,unsigned timeout_ms) {
    char path[256],temporary[272],actual_hash[65],name[96],saved_hash[65];long saved_size;
    if(!case_path(path,sizeof(path),run,VARIANT,id,repetition)||strlen(expected_hash)!=64||!unhex(name_hex,name,sizeof(name))||timeout_ms<1000||timeout_ms>3600000){emit("TIMING2 ERROR ARGUMENT\n");return;}
    if(committed_file(path,saved_hash,&saved_size)){emit("TIMING2 DONE %s %ld %s CACHED\n",id,saved_size,saved_hash);return;}
    dmd_display_show_clock();vTaskDelay(pdMS_TO_TICKS(150));
    int64_t prepared_load_start=esp_timer_get_time();
    if(timing_scene_choose(name)!=ESP_OK){emit("TIMING2 ERROR SELECT %s\n",id);return;}
    int64_t prepared_load_end=esp_timer_get_time();
    timing_scene_hash(actual_hash);if(strcmp(actual_hash,expected_hash)){emit("TIMING2 ERROR SCENE_HASH %s %s\n",id,actual_hash);return;}
    dmd_scene_info_t info;dmd_scene_get_info(&info);
    struct timeval fixed_start={.tv_sec=1704067200,.tv_usec=0};settimeofday(&fixed_start,NULL);
    count=0;finished=0;overflow=false;load_start=prepared_load_start;load_end=prepared_load_end;active=true;
    int64_t command_at=esp_timer_get_time();dmd_display_play_scene(0);int64_t deadline=command_at+(int64_t)timeout_ms*1000;
    while(!finished&&esp_timer_get_time()<deadline)vTaskDelay(pdMS_TO_TICKS(10));
    active=false;
    if(!finished||overflow||count!=info.step_count){dmd_display_show_clock();emit("TIMING2 ERROR PLAYBACK %s %u %u\n",id,count,info.step_count);return;}
    timing_scene_hash(actual_hash);if(strcmp(actual_hash,expected_hash)){emit("TIMING2 ERROR LOADED_HASH %s\n",id);return;}
    if(!make_directories(run)){emit("TIMING2 ERROR MKDIR\n");return;}
    snprintf(temporary,sizeof(temporary),"%s.tmp",path);FILE *file=fopen(temporary,"wb");if(!file){emit("TIMING2 ERROR LOG_OPEN\n");return;}
    fprintf(file,"{\"kind\":\"header\",\"schemaVersion\":1,\"runId\":\"%s\",\"caseId\":\"%s\",\"repeat\":%u,\"board\":\"" BOARD "\",\"variant\":\"" VARIANT "\",\"source\":\"" SOURCE "\",\"nameHex\":\"%s\",\"sha256\":\"%s\",\"frames\":%u,\"steps\":%u,\"commandUs\":%lld,\"loadStartUs\":%lld,\"loadEndUs\":%lld}\n",run,id,repetition,name_hex,actual_hash,info.frame_count,info.step_count,(long long)command_at,(long long)load_start,(long long)load_end);
    for(unsigned i=0;i<count;i++)fprintf(file,"{\"kind\":\"step\",\"n\":%u,\"frame\":%u,\"delay\":%u,\"loop\":%lld,\"decoded\":%lld,\"painted\":%lld}\n",i,samples[i].frame,samples[i].delay,(long long)samples[i].loop,(long long)samples[i].decoded,(long long)samples[i].painted);
    fprintf(file,"{\"kind\":\"result\",\"count\":%u,\"start\":%lld,\"end\":%lld,\"firstPaintUs\":%lld,\"status\":\"Completed\"}\n",count,(long long)samples[0].decoded,(long long)finished,(long long)samples[0].painted);
    fprintf(file,"{\"kind\":\"commit\",\"count\":%u}\n",count);
    bool ok=!ferror(file)&&fflush(file)==0;if(ok)ok=fsync(fileno(file))==0;if(fclose(file)!=0)ok=false;
    if(!ok||rename(temporary,path)!=0||!committed_file(path,saved_hash,&saved_size)){emit("TIMING2 ERROR LOG_COMMIT\n");return;}
    emit("TIMING2 DONE %s %ld %s\n",id,saved_size,saved_hash);
}
void timing_probe_task(void *context) {
    (void)context;
#if CONFIG_DMD_BOARD_3_49_LANDSCAPE
    usb_serial_jtag_driver_config_t usb=USB_SERIAL_JTAG_DRIVER_CONFIG_DEFAULT();usb.rx_buffer_size=4096;usb.tx_buffer_size=4096;
    ESP_ERROR_CHECK(usb_serial_jtag_driver_install(&usb));
#else
    ESP_ERROR_CHECK(uart_driver_install(UART_NUM_0,4096,4096,0,NULL,0));
#endif
    vTaskDelay(pdMS_TO_TICKS(22000));
    emit("TIMING2 READY " BOARD " " VARIANT " " SOURCE " sd=%u\n",dmd_storage_available());
    char line[512];unsigned used=0;
    for(;;){
        unsigned char bytes[128];int length=receive(bytes,sizeof(bytes));
        for(int i=0;i<length;i++){
            if(bytes[i]=='\r')continue;
            if(bytes[i]!='\n'){if(used<sizeof(line)-1)line[used++]=(char)bytes[i];continue;}
            line[used]=0;used=0;
            char run[49],id[49],hash[65],hex[193],variant[16];unsigned repetition,timeout;
            if(!strcmp(line,"HELLO"))emit("TIMING2 READY " BOARD " " VARIANT " " SOURCE " sd=%u\n",dmd_storage_available());
            else if(!strcmp(line,"INVENTORY"))inventory();
            else if(sscanf(line,"RUN %48s %48s %u %64s %192s %u",run,id,&repetition,hash,hex,&timeout)==6)run_case(run,id,repetition,hash,hex,timeout);
            else if(sscanf(line,"GET %48s %15s %48s %u",run,variant,id,&repetition)==4)get_file(run,variant,id,repetition);
            else if(!strcmp(line,"STATUS"))emit("TIMING2 STATUS idle\n");
            else emit("TIMING2 ERROR COMMAND\n");
        }
    }
}
