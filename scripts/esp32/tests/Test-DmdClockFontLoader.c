#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "dmd_font.h"
#include "dmd_font_loader.h"

int main(int argc, char **argv)
{
    if (argc >= 2 && strcmp(argv[1], "inspect") == 0) {
        if (argc != 5) return 2;
        dmd_font_catalog_entry_t entry;
        char error[DMD_FONT_ERROR_MAX] = {0};
        int actual = dmd_font_loader_inspect(
            argv[2], argv[3], &entry, error, sizeof(error)) ? 1 : 0;
        int expected = atoi(argv[4]);
        if (actual != expected) {
            fprintf(stderr, "inspect expected %d, got %d: %s\n", expected, actual, error);
            return 1;
        }
        return 0;
    }
    if (argc >= 2 && strcmp(argv[1], "catalog") == 0) {
        if (argc != 4 || !dmd_font_init_directory(argv[2])) return 2;
        size_t expected = (size_t)strtoul(argv[3], NULL, 10);
        if (dmd_font_count() != expected ||
            (expected > 1 &&
             (!dmd_font_is_available("TrEk") ||
              strcmp(dmd_font_canonical_id("TrEk"), "trek") != 0))) {
            fprintf(stderr, "catalog expected %u, got %u\n",
                (unsigned)expected, (unsigned)dmd_font_count());
            return 1;
        }
        return 0;
    }
    return 2;
}
