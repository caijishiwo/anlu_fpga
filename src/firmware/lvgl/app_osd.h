#ifndef APP_OSD_H
#define APP_OSD_H
#include "lvgl.h"
#define OSD_CONTROL (*(volatile uint32_t *)0x0300003cu)
#define OSD_MEMORY ((volatile uint32_t *)0x05000000u)
#define OSD_WIDTH 384u
#define OSD_HEIGHT 320u
#define OSD_PALETTE_BYTES 8u
#define OSD_WORDS_PER_ROW (OSD_WIDTH / 32u)
#define OSD_BUFFER_BYTES (OSD_WIDTH * OSD_HEIGHT / 8u + OSD_PALETTE_BYTES)

static void osd_copy_area(const lv_area_t *area, const uint8_t *pixels,
                          volatile uint32_t *destination)
{
    const uint32_t *source = (const uint32_t *)(pixels + OSD_PALETTE_BYTES);
    uint32_t first = (uint32_t)area->x1 / 32u;
    uint32_t last = (uint32_t)area->x2 / 32u;
    for (uint32_t row = area->y1; row <= (uint32_t)area->y2; row++) {
        uint32_t offset = row * OSD_WORDS_PER_ROW;
        for (uint32_t column = first; column <= last; column++)
            destination[offset + column] = source[offset + column];
    }
}
#endif
