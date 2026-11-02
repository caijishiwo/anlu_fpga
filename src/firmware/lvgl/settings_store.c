#include "settings_store.h"
#include <string.h>

enum { VERSION_OFFSET=8, SEQUENCE_OFFSET=12, VALUES_OFFSET=16,
       CRC_OFFSET=508, RECORD_VERSION=1, RECORD_OK=1, RECORD_EMPTY=0,
       RECORD_BAD=-1, IO_ERROR=-2, VERIFY_ERROR=-3 };
static const uint8_t signature[8]={'A','N','L','U','C','F','G','1'};

static uint32_t get32(const uint8_t *bytes)
{
    uint32_t value=0;
    for(unsigned i=0;i<4;i++) value|=(uint32_t)bytes[i]<<(i*8u);
    return value;
}
static void put32(uint8_t *bytes,uint32_t value)
{
    for(unsigned i=0;i<4;i++) bytes[i]=(uint8_t)(value>>(i*8u));
}
static uint32_t crc32(const uint8_t *bytes)
{
    uint32_t crc=UINT32_MAX;
    for(unsigned i=0;i<CRC_OFFSET;i++) {
        crc^=bytes[i];
        for(unsigned bit=0;bit<8;bit++) crc=(crc>>1)^((0u-(crc&1u))&0xedb88320u);
    }
    return ~crc;
}
settings_values_t settings_defaults(void)
{
    return (settings_values_t){8,2,2,0,255,128,0,1,1,1,0,1};
}
bool settings_values_valid(const settings_values_t *v)
{
    return v->volume<=8 && v->bass<=4 && v->treble<=4 && v->mute<=1 &&
        v->contrast>=64 && v->contrast<=224 && v->flip<=1 && v->subtitle<=1 &&
        v->effects<=1 && v->sequential<=1 && v->autoplay<=1 &&
        v->interval>=SETTINGS_INTERVAL_MIN && v->interval<=SETTINGS_INTERVAL_MAX;
}
void settings_encode(uint8_t *record,const settings_values_t *values,uint32_t sequence)
{
    memset(record,0,SETTINGS_SECTOR_BYTES);
    memcpy(record,signature,sizeof(signature));
    put32(record+VERSION_OFFSET,RECORD_VERSION);
    put32(record+SEQUENCE_OFFSET,sequence);
    memcpy(record+VALUES_OFFSET,values,sizeof(*values));
    put32(record+CRC_OFFSET,crc32(record));
}
int settings_decode(const uint8_t *record,settings_values_t *values,uint32_t *sequence)
{
    bool empty=true;
    for(unsigned i=0;i<SETTINGS_SECTOR_BYTES;i++) empty=empty && record[i]==0;
    if(empty) return RECORD_EMPTY;
    if(memcmp(record,signature,sizeof(signature)) ||
       get32(record+VERSION_OFFSET)!=RECORD_VERSION ||
       get32(record+CRC_OFFSET)!=crc32(record)) return RECORD_BAD;
    settings_values_t result;
    memcpy(&result,record+VALUES_OFFSET,sizeof(result));
    if(!settings_values_valid(&result)) return RECORD_BAD;
    *values=result;*sequence=get32(record+SEQUENCE_OFFSET);
    return RECORD_OK;
}
static void fail(settings_store_t *store,int error)
{
    store->error=error;store->state=SETTINGS_FAILED;
}
void settings_open(settings_store_t *s,const settings_io_t *io,const uint32_t *sectors)
{
    memset(s,0,sizeof(*s));s->io=*io;
    s->committed=s->observed=settings_defaults();
    s->sectors[0]=sectors[0];s->sectors[1]=sectors[1];
    if(!sectors[0] || !sectors[1] || sectors[0]==sectors[1]) {
        s->state=SETTINGS_UNAVAILABLE;return;
    }
    bool damaged=false;
    for(unsigned slot=0;slot<2;slot++) {
        settings_values_t value;uint32_t sequence;
        if(io->read(io->context,sectors[slot],s->buffer)) {fail(s,IO_ERROR);return;}
        int result=settings_decode(s->buffer,&value,&sequence);
        damaged=damaged || result==RECORD_BAD;
        if(result!=RECORD_OK) continue;
        if(s->have_record && sequence==s->sequence &&
           memcmp(&value,&s->committed,sizeof(value))) {
            s->state=SETTINGS_CORRUPT;return;
        }
        if(s->have_record && (int32_t)(sequence-s->sequence)<=0) continue;
        s->have_record=true;s->active=slot;s->sequence=sequence;
        s->committed=s->observed=value;
    }
    s->state=s->have_record ? SETTINGS_SAVED : damaged ? SETTINGS_CORRUPT : SETTINGS_NEW;
    if(damaged && s->have_record) s->error=RECORD_BAD;
}
void settings_observe(settings_store_t *s,const settings_values_t *values,uint32_t now)
{
    if(!memcmp(values,&s->observed,sizeof(*values))) return;
    if(!settings_values_valid(values)) {fail(s,RECORD_BAD);return;}
    s->observed=*values;s->changed_at=now;
    if(s->state==SETTINGS_WRITING || s->state==SETTINGS_CORRUPT ||
       s->state==SETTINGS_UNAVAILABLE) return;
    s->state=memcmp(values,&s->committed,sizeof(*values)) ? SETTINGS_PENDING :
             s->have_record ? SETTINGS_SAVED : SETTINGS_NEW;
    s->error=0;
}
static void verify_write(settings_store_t *s)
{
    uint8_t record[SETTINGS_SECTOR_BYTES];
    if(s->io.read(s->io.context,s->sectors[s->target],record)) {fail(s,IO_ERROR);return;}
    if(memcmp(record,s->buffer,sizeof(record))) {fail(s,VERIFY_ERROR);return;}
    s->active=s->target;s->sequence++;s->have_record=true;s->committed=s->snapshot;
    s->state=memcmp(&s->observed,&s->committed,sizeof(s->observed)) ?
             SETTINGS_PENDING : SETTINGS_SAVED;
}
void settings_poll(settings_store_t *s,uint32_t now)
{
    if(s->state==SETTINGS_WRITING) {
        int result=s->io.write_poll(s->io.context);
        if(result<0) fail(s,result);
        else if(result>0) verify_write(s);
        return;
    }
    if(s->state!=SETTINGS_PENDING || (uint32_t)(now-s->changed_at)<SETTINGS_DELAY_CYCLES)
        return;
    s->target=s->have_record ? s->active^1u : 0u;s->snapshot=s->observed;
    settings_encode(s->buffer,&s->snapshot,s->sequence+1u);
    int result=s->io.write_start(s->io.context,s->sectors[s->target],s->buffer);
    if(result) {fail(s,result);return;}
    s->state=SETTINGS_WRITING;
}
