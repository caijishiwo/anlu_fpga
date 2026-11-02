#ifndef UI_HOME_H
#define UI_HOME_H

#include <stdbool.h>
#include <stdint.h>
#include "lvgl.h"

lv_obj_t *ui_home_create(void);
bool ui_home_select(uint8_t selected);
void ui_home_enter(void);
void ui_home_exit(void);
void ui_home_set_status(uint32_t seconds, uint32_t photo);
void ui_home_set_track(const char *name);
void ui_home_set_save_status(const char *text);
void ui_home_set_key_diagnostics(uint8_t event,bool menu_open,bool menu_drawn);
void ui_home_set_image_count(uint32_t count);
void ui_home_set_progress(uint32_t frames, uint32_t total_frames);

#endif
