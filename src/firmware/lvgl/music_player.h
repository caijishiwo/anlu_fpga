#ifndef MUSIC_PLAYER_H
#define MUSIC_PLAYER_H
#include "music_catalog.h"
#include <stdbool.h>
enum { MUSIC_BUSY=1, MUSIC_FINISHED=2, MUSIC_TRANSFER_ERROR=4 };
typedef struct {
    music_track_t *first, *current, *wanted, *submitted;
    bool sequential, pending, request;
    int error;
} music_player_t;
typedef struct {
    uint32_t (*status)(void *context);
    void (*submit)(void *context, const music_track_t *track);
    void *context;
} music_transport_t;
music_player_t music_player_create(music_track_t *first);
void music_player_step(music_player_t *player, bool next);
void music_player_tick(music_player_t *player, const music_transport_t *io);
#endif
