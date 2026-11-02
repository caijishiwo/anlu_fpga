#ifndef APP_MUSIC_H
#define APP_MUSIC_H
#include <stdbool.h>
#include <stdint.h>
void app_music_init(void);
void app_music_tick(void);
void app_music_action(unsigned row);
bool app_music_sequential(void);
void app_music_set_sequential(bool enabled);
const char *app_music_name(void);
unsigned app_music_count(void);
uint32_t app_music_total_frames(void);
int app_music_error(void);
#endif
