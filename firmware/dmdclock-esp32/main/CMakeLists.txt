idf_component_register(
    SRCS
        "app_main.c"
        "dmd_actions.c"
        "dmd_board.c"
        "dmd_display.c"
        "dmd_diagnostics.c"
        "dmd_font.c"
        "generated/dmd_fonts_generated.c"
        "dmd_mqtt.c"
        "dmd_color.c"
        "dmd_controls.c"
        "dmd_settings.c"
        "dmd_settings_json.c"
        "dmd_storage.c"
        "dmd_network.c"
        "dmd_panel_qemu.c"
        "dmd_panel_waveshare7.c"
        "dmd_panel_waveshare349b.c"
        "dmd_playback_log.c"
        "dmd_plasma.c"
        "dmd_scene.c"
        "dmd_scene_pack.c"
        "dmd_scene_metadata.c"
        "dmd_web.c"
    INCLUDE_DIRS "."
    EMBED_TXTFILES
        "web/index.html"
        "web/api.html"
        "web/timezones/africa.json"
        "web/timezones/america.json"
        "web/timezones/antarctica.json"
        "web/timezones/asia.json"
        "web/timezones/atlantic.json"
        "web/timezones/australia.json"
        "web/timezones/europe.json"
        "web/timezones/pacific.json"
    REQUIRES
        esp_driver_i2c
        esp_driver_tsens
        esp_event
        esp_app_format
        esp_http_client
        esp_http_server
        esp_lcd
        mqtt
        esp_netif
        esp_timer
        fatfs
        sdmmc
        esp_driver_sdmmc
        esp_driver_spi
        esp_wifi
        esp_eth
        json
        lwip
        nvs_flash
        qrcode
        spi_flash
        mbedtls
        zlib
)

set(DMD_FONT_GENERATOR
    "${CMAKE_CURRENT_LIST_DIR}/../../../scripts/esp32/Generate-DmdClockFonts.py")
set(DMD_FONT_SOURCE_DIR
    "${CMAKE_CURRENT_LIST_DIR}/../../../assets/fonts/DotClk")
set(DMD_FONT_GENERATED_DIR
    "${CMAKE_CURRENT_LIST_DIR}/generated")
set_property(
    DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS
    "${DMD_FONT_GENERATOR}"
    "${DMD_FONT_SOURCE_DIR}/ALTERN8.fnt"
    "${DMD_FONT_SOURCE_DIR}/FISHY.fnt"
    "${DMD_FONT_SOURCE_DIR}/TREK.fnt"
    "${DMD_FONT_SOURCE_DIR}/TWILIGHT.fnt"
    "${DMD_FONT_GENERATED_DIR}/dmd_fonts_generated.h"
    "${DMD_FONT_GENERATED_DIR}/dmd_fonts_generated.c")
execute_process(
    COMMAND
        "${PYTHON}"
        "${DMD_FONT_GENERATOR}"
        --source-dir "${DMD_FONT_SOURCE_DIR}"
        --output-dir "${DMD_FONT_GENERATED_DIR}"
        --check
    RESULT_VARIABLE DMD_FONT_CHECK_RESULT)
if(NOT DMD_FONT_CHECK_RESULT EQUAL 0)
    message(FATAL_ERROR
        "Generated ESP32 font assets are stale; run Generate-DmdClockFonts.py")
endif()

target_add_binary_data(
    ${COMPONENT_LIB}
    "${CMAKE_CURRENT_LIST_DIR}/../../../assets/icons/dmdclock.ico"
    BINARY)

if(DMD_BOOTSTRAP_WIFI_HEADER AND NOT CONFIG_DMD_QEMU)
    set(DMD_BOOTSTRAP_WIFI_PATH
        "${CMAKE_CURRENT_LIST_DIR}/dmd_bootstrap_wifi.h")
    if(NOT EXISTS "${DMD_BOOTSTRAP_WIFI_PATH}")
        message(FATAL_ERROR
            "Bootstrap Wi-Fi was enabled but dmd_bootstrap_wifi.h is missing")
    endif()
    target_compile_definitions(
        ${COMPONENT_LIB} PRIVATE DMD_HAS_BOOTSTRAP_WIFI=1)
else()
    target_compile_definitions(
        ${COMPONENT_LIB} PRIVATE DMD_HAS_BOOTSTRAP_WIFI=0)
endif()

if(CONFIG_DMD_QEMU)
    set(DMD_SCENE_METADATA_BUILD_FILE
        "${CMAKE_CURRENT_BINARY_DIR}/scene_metadata.json")
    set(DMD_SCENE_METADATA_SOURCE_FILE
        "${DMD_SCENE_SOURCE_DIR}/scene-metadata.json"
    )
    set(DMD_SCENE_METADATA_TOOL
        "${DMD_SCENE_SOURCE_DIR}/../scripts/esp32/New-DmdSceneMetadataSubset.py")
    set_property(
        DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS
        "${DMD_SCENE_METADATA_SOURCE_FILE}"
        "${DMD_SCENE_METADATA_TOOL}")
    execute_process(
        COMMAND
            "${PYTHON}"
            "${DMD_SCENE_METADATA_TOOL}"
            "${DMD_SCENE_METADATA_SOURCE_FILE}"
            "${DMD_SCENE_METADATA_BUILD_FILE}"
            got06.scn
            afm01.scn
            RD0868.scn
            RD0959.scn
            RD1116.scn
            RD1385.scn
            RD1448.scn
            RD1474.scn
            RD1695.scn
            RD1701.scn
            RD1891.scn
        RESULT_VARIABLE DMD_SCENE_METADATA_RESULT)
    if(NOT DMD_SCENE_METADATA_RESULT EQUAL 0)
        message(FATAL_ERROR "Could not generate QEMU scene metadata subset")
    endif()
    target_add_binary_data(
        ${COMPONENT_LIB}
        "${DMD_SCENE_METADATA_BUILD_FILE}"
        TEXT)
    set(DMD_EMBEDDED_SCENES
        "scene_00.scn|got06.scn"
        "scene_01.scn|afm01.scn"
        "scene_02.scn|RD0868.scn"
        "scene_03.scn|RD0959.scn"
        "scene_04.scn|RD1116.scn"
        "scene_05.scn|RD1385.scn"
        "scene_06.scn|RD1448.scn"
        "scene_07.scn|RD1474.scn"
        "scene_08.scn|RD1695.scn"
        "scene_09.scn|RD1701.scn"
        "scene_10.scn|RD1891.scn"
    )
endif()
foreach(DMD_EMBEDDED_SCENE IN LISTS DMD_EMBEDDED_SCENES)
    string(REPLACE "|" ";" DMD_SCENE_PAIR "${DMD_EMBEDDED_SCENE}")
    list(GET DMD_SCENE_PAIR 0 DMD_SCENE_BUILD_NAME)
    list(GET DMD_SCENE_PAIR 1 DMD_SCENE_SOURCE_NAME)
    set(DMD_SCENE_BUILD_FILE
        "${CMAKE_CURRENT_BINARY_DIR}/${DMD_SCENE_BUILD_NAME}")
    configure_file(
        "${DMD_SCENE_SOURCE_DIR}/${DMD_SCENE_SOURCE_NAME}"
        "${DMD_SCENE_BUILD_FILE}"
        COPYONLY)
    target_add_binary_data(
        ${COMPONENT_LIB}
        "${DMD_SCENE_BUILD_FILE}"
        BINARY)
endforeach()
