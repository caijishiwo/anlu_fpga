#ifndef APP_CARD_H
#define APP_CARD_H
#include <stdint.h>
int app_card_read(void *context,uint32_t sector,uint8_t *data);
int app_card_write_start(void *context,uint32_t sector,const uint8_t *data);
int app_card_write_poll(void *context);
#endif
