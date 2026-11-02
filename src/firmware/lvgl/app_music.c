#include "app_music.h"
#include "music_player.h"
#include "lvgl.h"
#include "app_trace.h"
#include "app_card.h"
#define MUSIC_REG ((volatile uint32_t *)0x03004000u)
enum { SECTOR_BYTES=512, WORD_BYTES=4, MUSIC_ID=0x4d555331,
       SECTOR_REG=0, FRAME_REG=1, LYRIC_REG=2, COMMIT_REG=3,
       STATUS_REG=4, ID_REG=6, INCOMPATIBLE_BIT=8 };
static music_catalog_t catalog;
static music_player_t player;

static uint32_t music_status(void *context)
{
    (void)context;
    return MUSIC_REG[STATUS_REG];
}
static void music_submit(void *context,const music_track_t *track)
{
    (void)context;
    MUSIC_REG[SECTOR_REG]=track->sector;
    MUSIC_REG[FRAME_REG]=track->frames;
    MUSIC_REG[LYRIC_REG]=track->lyric_sector;
    MUSIC_REG[COMMIT_REG]=1;
    app_trace("TRACK ");app_trace(track->name);app_trace("\r\n");
}
static const music_transport_t transport={music_status,music_submit,NULL};
void app_music_init(void)
{
    if(MUSIC_REG[ID_REG]!=MUSIC_ID) {
        catalog.error=INCOMPATIBLE_BIT;
        app_trace("MUSIC BIT REQUIRED\r\n");return;
    }
    const music_io_t io={app_card_read,lv_malloc,lv_free,NULL};
    app_trace("CATALOG BEGIN\r\n");
    catalog=music_catalog_load(&io);
    app_trace_value("CATALOG COUNT ",catalog.count);
    if(catalog.error) app_trace_value("CATALOG ERROR ",catalog.error);
    player=music_player_create(catalog.first);
    app_music_tick();
}
void app_music_tick(void)
{
    int previous=player.error;
    music_player_tick(&player,&transport);
    if(player.error && !previous) app_trace_value("MUSIC ERROR ",player.error);
}
void app_music_action(unsigned row)
{
    if(row<2) music_player_step(&player,row==1);
    if(row==2) player.sequential=!player.sequential;
}
bool app_music_sequential(void) {return player.sequential;}
void app_music_set_sequential(bool enabled) {player.sequential=enabled;}
const char *app_music_name(void)
{
    return player.current ? player.current->name : "--";
}
unsigned app_music_count(void) {return catalog.count;}
uint32_t app_music_total_frames(void)
{
    return player.current ? player.current->frames : 0u;
}
int app_music_error(void) {return catalog.error ? catalog.error : player.error;}
