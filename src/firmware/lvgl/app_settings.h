#ifndef APP_SETTINGS_H
#define APP_SETTINGS_H
#include "settings_store.h"
void app_settings_init(void);
const settings_values_t *app_settings_values(void);
void app_settings_tick(const settings_values_t *values,uint32_t now);
#endif
