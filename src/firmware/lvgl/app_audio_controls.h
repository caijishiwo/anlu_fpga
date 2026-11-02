#ifndef APP_AUDIO_CONTROLS_H
#define APP_AUDIO_CONTROLS_H
#include <stdint.h>
#include <stdbool.h>

typedef struct {
    uint8_t volume,bass,treble;
    bool mute;
} audio_controls_t;

enum { AUDIO_VOLUME_MAX=8u, AUDIO_TONE_MAX=4u };
static uint8_t audio_level_step(uint8_t value,uint8_t maximum,int direction)
{
    if(direction>0 && value<maximum) return value+1u;
    if(direction<0 && value>0u) return value-1u;
    return value;
}

static audio_controls_t audio_controls_step(audio_controls_t state,uint8_t row,int direction)
{
    switch(row) {
    case 0u:state.volume=audio_level_step(state.volume,AUDIO_VOLUME_MAX,direction);break;
    case 1u:state.bass=audio_level_step(state.bass,AUDIO_TONE_MAX,direction);break;
    case 2u:state.treble=audio_level_step(state.treble,AUDIO_TONE_MAX,direction);break;
    case 3u:state.mute=!state.mute;break;
    default:break;
    }
    return state;
}

static uint32_t audio_controls_pack(audio_controls_t state)
{
    return state.volume | (uint32_t)state.bass<<4 |
           (uint32_t)state.treble<<7 | (uint32_t)state.mute<<10;
}
#endif
