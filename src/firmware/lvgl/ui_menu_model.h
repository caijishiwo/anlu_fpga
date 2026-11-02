#ifndef UI_MENU_MODEL_H
#define UI_MENU_MODEL_H
#include <stdint.h>

enum { UI_MENU_COUNT=5, UI_ROW_COUNT=4 };
typedef enum { UI_INFO, UI_ACTION, UI_TOGGLE, UI_NUMBER } ui_row_kind_t;
typedef enum {
    UI_NONE, UI_MUSIC_PREV, UI_MUSIC_NEXT, UI_MUSIC_MODE, UI_TRACK,
    UI_PHOTO_PREV, UI_PHOTO_NEXT, UI_PHOTO_AUTO, UI_PHOTO_POSITION,
    UI_LYRICS_VISIBLE, UI_LYRIC_POSITION, UI_EFFECTS, UI_BRIGHTNESS,
    UI_CONTRAST, UI_FLIP, UI_VOLUME, UI_BASS, UI_TREBLE, UI_MUTE,UI_PHOTO_INTERVAL
} ui_action_t;
typedef struct {
    const char *label;
    ui_row_kind_t kind;
    ui_action_t action;
} ui_row_spec_t;
typedef struct {
    const char *title;
    uint8_t count;
    ui_row_spec_t rows[UI_ROW_COUNT];
} ui_menu_spec_t;

static const ui_menu_spec_t ui_menu_specs[UI_MENU_COUNT]={
    {"音乐",4,{{"上一首",UI_ACTION,UI_MUSIC_PREV},
               {"下一首",UI_ACTION,UI_MUSIC_NEXT},
               {"循环模式",UI_TOGGLE,UI_MUSIC_MODE},
               {"当前曲目",UI_INFO,UI_TRACK}}},
    {"图片",4,{{"上一张",UI_ACTION,UI_PHOTO_PREV},
               {"下一张",UI_ACTION,UI_PHOTO_NEXT},
               {"自动轮播",UI_TOGGLE,UI_PHOTO_AUTO},
               {"轮播间隔",UI_NUMBER,UI_PHOTO_INTERVAL}}},
    {"歌词",3,{{"显示歌词",UI_TOGGLE,UI_LYRICS_VISIBLE},
               {"当前句",UI_INFO,UI_LYRIC_POSITION},
               {"当前曲目",UI_INFO,UI_TRACK}}},
    {"画面",4,{{"切图特效",UI_TOGGLE,UI_EFFECTS},
               {"亮度",UI_NUMBER,UI_BRIGHTNESS},
               {"对比度",UI_NUMBER,UI_CONTRAST},
               {"画面翻转",UI_TOGGLE,UI_FLIP}}},
    {"声音",4,{{"音量",UI_NUMBER,UI_VOLUME},
               {"低音",UI_NUMBER,UI_BASS},
               {"高音",UI_NUMBER,UI_TREBLE},
               {"静音",UI_TOGGLE,UI_MUTE}}},
};

static inline uint8_t ui_menu_step_row(uint8_t page,uint8_t row,int direction)
{
    uint8_t count=ui_menu_specs[page].count;
    do {
        row=(uint8_t)((row+count+direction)%count);
    } while(ui_menu_specs[page].rows[row].kind==UI_INFO);
    return row;
}
#endif
