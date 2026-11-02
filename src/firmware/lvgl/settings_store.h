#ifndef SETTINGS_STORE_H
#define SETTINGS_STORE_H
#include <stdbool.h>
#include <stdint.h>

enum { SETTINGS_SECTOR_BYTES=512, SETTINGS_DELAY_CYCLES=50000000u,
       SETTINGS_INTERVAL_MIN=1, SETTINGS_INTERVAL_MAX=30 };
typedef struct {
    uint8_t volume,bass,treble,mute,brightness,contrast;
    uint8_t flip,subtitle,effects,sequential,autoplay,interval;
} settings_values_t;
typedef struct {
    int (*read)(void *,uint32_t,uint8_t *);
    int (*write_start)(void *,uint32_t,const uint8_t *);
    int (*write_poll)(void *); /* 0等待，1完成，负值失败。 */
    void *context;
} settings_io_t;
typedef enum {
    SETTINGS_NEW,SETTINGS_SAVED,SETTINGS_PENDING,SETTINGS_WRITING,
    SETTINGS_FAILED,SETTINGS_CORRUPT,SETTINGS_UNAVAILABLE
} settings_state_t;
typedef struct {
    settings_io_t io;
    settings_values_t observed,committed,snapshot;
    uint32_t sectors[2],sequence,changed_at;
    uint8_t buffer[SETTINGS_SECTOR_BYTES];
    unsigned active,target;
    settings_state_t state;
    int error;
    bool have_record;
} settings_store_t;

settings_values_t settings_defaults(void);
bool settings_values_valid(const settings_values_t *values);
void settings_encode(uint8_t *record,const settings_values_t *values,uint32_t sequence);
int settings_decode(const uint8_t *record,settings_values_t *values,uint32_t *sequence);
void settings_open(settings_store_t *store,const settings_io_t *io,const uint32_t *sectors);
void settings_observe(settings_store_t *store,const settings_values_t *values,uint32_t now);
void settings_poll(settings_store_t *store,uint32_t now);
#endif
