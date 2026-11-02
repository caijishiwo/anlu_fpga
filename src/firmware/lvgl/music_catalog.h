#ifndef MUSIC_CATALOG_H
#define MUSIC_CATALOG_H
#include <stdint.h>
#include <stddef.h>

typedef struct music_track {
    struct music_track *next;
    uint32_t sector, frames, lyric_sector;
    char name[13];
} music_track_t;
typedef struct {
    int (*read)(void *context, uint32_t sector, uint8_t *data);
    void *(*allocate)(size_t bytes);
    void (*release)(void *memory);
    void *context;
} music_io_t;
typedef struct {
    music_track_t *first;
    uint32_t count;
    int error;
} music_catalog_t;
enum { MUSIC_IO_ERROR=1, MUSIC_BAD_FS, MUSIC_NO_FOLDER, MUSIC_BAD_FILE,
       MUSIC_FRAGMENTED, MUSIC_NO_MEMORY, MUSIC_BAD_CHAIN,
       MUSIC_SETTINGS_MISSING,MUSIC_SETTINGS_INVALID };
int music_settings_sectors(const music_io_t *io,uint32_t *sectors);
music_catalog_t music_catalog_load(const music_io_t *io);
void music_catalog_free(const music_io_t *io, music_catalog_t *catalog);
#endif
