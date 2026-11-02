#include "app_card.h"
#define SD_REQUEST (*(volatile uint32_t *)0x03002000u)
#define SD_STATUS (*(volatile uint32_t *)0x03002004u)
#define SD_WRITE (*(volatile uint32_t *)0x03002008u)
#define SD_ID (*(volatile uint32_t *)0x0300200cu)
#define SD_DATA ((volatile uint32_t *)0x03002100u)
enum { SECTOR_BYTES=512, WORD_BYTES=4, BUSY=1, DONE=2, ERROR=4,
       WRITE_ID=0x53445731, BAD_STATUS=-10, PORT_BUSY=-11, OLD_BIT=-12 };

static int result(uint32_t status)
{
    if(status&ERROR) return BAD_STATUS;
    if(status&BUSY) return 0;
    if(!(status&DONE)) return BAD_STATUS;
    return (status>>3)==SECTOR_BYTES ? 1 : BAD_STATUS;
}
int app_card_read(void *context,uint32_t sector,uint8_t *data)
{
    (void)context;
    if(SD_STATUS&BUSY) return PORT_BUSY;
    SD_REQUEST=sector;
    uint32_t status;
    do {status=SD_STATUS;} while(status&BUSY);
    if(result(status)!=1) return BAD_STATUS;
    for(unsigned i=0;i<SECTOR_BYTES/WORD_BYTES;i++) {
        uint32_t value=SD_DATA[i];
        for(unsigned byte=0;byte<WORD_BYTES;byte++)
            data[i*WORD_BYTES+byte]=(uint8_t)(value>>(byte*8u));
    }
    return 0;
}
int app_card_write_start(void *context,uint32_t sector,const uint8_t *data)
{
    (void)context;
    if(SD_ID!=WRITE_ID) return OLD_BIT;
    if(SD_STATUS&BUSY) return PORT_BUSY;
    for(unsigned i=0;i<SECTOR_BYTES/WORD_BYTES;i++) {
        uint32_t value=0;
        for(unsigned byte=0;byte<WORD_BYTES;byte++)
            value|=(uint32_t)data[i*WORD_BYTES+byte]<<(byte*8u);
        SD_DATA[i]=value;
    }
    SD_WRITE=sector;return 0;
}
int app_card_write_poll(void *context)
{
    (void)context;return result(SD_STATUS);
}
