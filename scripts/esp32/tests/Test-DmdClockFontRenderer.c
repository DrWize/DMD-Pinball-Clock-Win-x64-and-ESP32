#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "dmd_font.h"

#define FRAME_WIDTH 128
#define FRAME_HEIGHT 32
#define FRAME_BYTES (FRAME_WIDTH * FRAME_HEIGHT)

static int parse_int(const char *text, int *value)
{
    char *end = NULL;
    errno = 0;
    long parsed = strtol(text, &end, 10);
    if (errno != 0 || end == text || *end != '\0' || parsed < -32768 || parsed > 32767) {
        return 0;
    }
    *value = (int)parsed;
    return 1;
}

int main(int argc, char **argv)
{
    if (argc != 8) {
        fprintf(stderr, "usage: renderer FONT_DIRECTORY FONT TEXT BUILTIN_SCALE CENTER_X CENTER_Y OUTPUT\n");
        return 2;
    }

    if (!dmd_font_init_directory(argv[1])) {
        fputs("font catalog initialization failed\n", stderr);
        return 3;
    }
    const char *font = argv[2];
    if (strcmp(font, "invalid-id") != 0 && !dmd_font_activate(font)) {
        fprintf(stderr, "unknown test font: %s (%s)\n", font, dmd_font_last_error());
        return 2;
    }
    if (!dmd_font_is_available("TrEk") ||
        dmd_font_is_available("not-a-font") ||
        strcmp(dmd_font_display_name("TrEk"), "TREK") != 0) {
        fputs("font lookup/fallback contract failed\n", stderr);
        return 3;
    }

    int scale;
    int center_x;
    int center_y;
    if (!parse_int(argv[4], &scale) || scale < 1 || scale > 4 ||
        !parse_int(argv[5], &center_x) || !parse_int(argv[6], &center_y)) {
        fputs("invalid scale or center\n", stderr);
        return 2;
    }

    uint8_t intensities[FRAME_BYTES];
    uint8_t mask[FRAME_BYTES];
    dmd_font_render_frame(
        intensities,
        mask,
        FRAME_WIDTH,
        FRAME_HEIGHT,
        argv[3],
        font,
        center_x,
        center_y,
        (uint8_t)scale);

    FILE *output = fopen(argv[7], "wb");
    if (output == NULL) {
        perror("could not open renderer output");
        return 4;
    }
    size_t intensity_written = fwrite(intensities, 1, sizeof(intensities), output);
    size_t mask_written = fwrite(mask, 1, sizeof(mask), output);
    int close_result = fclose(output);
    if (intensity_written != sizeof(intensities) ||
        mask_written != sizeof(mask) || close_result != 0) {
        fputs("could not write complete renderer output\n", stderr);
        return 4;
    }
    return 0;
}
