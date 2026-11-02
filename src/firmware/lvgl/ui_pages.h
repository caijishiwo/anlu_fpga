#ifndef UI_PAGES_H
#define UI_PAGES_H

#include <stdint.h>
#include <stdbool.h>
#include "lvgl.h"

void ui_pages_create(lv_obj_t *parent);
void ui_pages_show(uint8_t page);
void ui_pages_hide(void);
void ui_pages_select(uint8_t row);
void ui_pages_set_editing(bool editing);
void ui_pages_set_value(uint8_t row, const char *value);

#endif
