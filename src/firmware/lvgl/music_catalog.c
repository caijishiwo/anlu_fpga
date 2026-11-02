#include "music_catalog.h"
#include <string.h>

enum { SECTOR=512, ENTRY=32, ATTR_DIR=16, ATTR_LFN=15 };
typedef struct {
    const music_io_t *io;
    uint32_t base,fat,data,root,root_sectors,clusters,spc,fat_cache_sector;
    uint8_t fat_cache[SECTOR];
    int fat32,error;
    uint32_t music,lyrics;
    uint32_t settings[2];
    music_catalog_t result;
} volume_t;
typedef int (*entry_fn)(volume_t *,const uint8_t *);

static uint32_t u16(const uint8_t *p) { return p[0]|((uint32_t)p[1]<<8); }
static uint32_t u32(const uint8_t *p) { return u16(p)|(u16(p+2)<<16); }
static int read_sector(volume_t *v,uint32_t sector,uint8_t *data)
{
    if(v->io->read(v->io->context,sector,data)) v->error=MUSIC_IO_ERROR;
    return !v->error;
}
static uint32_t first_sector(const volume_t *v,uint32_t cluster)
{
    return v->data+(cluster-2)*v->spc;
}
static uint32_t entry_cluster(const volume_t *v,const uint8_t *entry)
{
    return u16(entry+26)|(v->fat32 ? u16(entry+20)<<16 : 0);
}
static uint32_t next_cluster(volume_t *v,uint32_t cluster)
{
    uint32_t width=v->fat32 ? 4 : 2;
    uint32_t sector=v->fat+cluster*width/SECTOR;
    if(sector!=v->fat_cache_sector) {
        if(!read_sector(v,sector,v->fat_cache)) return 0;
        v->fat_cache_sector=sector;
    }
    const uint8_t *p=v->fat_cache+(cluster*width)%SECTOR;
    uint32_t next=v->fat32 ? u32(p)&0x0fffffff : u16(p);
    if(next>=(v->fat32 ? 0x0ffffff8u : 0xfff8u)) return 0;
    if(next<2 || next>=v->clusters+2) v->error=MUSIC_BAD_CHAIN;
    return v->error ? 0 : next;
}
static int mount(volume_t *v)
{
    uint8_t b[SECTOR];
    if(!read_sector(v,0,b)) return 0;
    if(u16(b+11)!=SECTOR) {
        v->base=u32(b+454);
        if(u16(b+510)!=0xaa55 || !v->base) return 0;
        if(!read_sector(v,v->base,b)) return 0;
    }
    uint32_t reserved=u16(b+14),fats=b[16],fat_size=u16(b+22);
    uint32_t total=u16(b+19) ? u16(b+19) : u32(b+32);
    v->spc=b[13];v->fat32=fat_size==0;
    if(v->fat32) fat_size=u32(b+36);
    v->root_sectors=(u16(b+17)*ENTRY+SECTOR-1)/SECTOR;
    uint32_t overhead=reserved+fats*fat_size+v->root_sectors;
    if(u16(b+510)!=0xaa55 || u16(b+11)!=SECTOR || !v->spc ||
       (v->spc&(v->spc-1)) || !reserved || !fats || !fat_size || total<=overhead)
        return 0;
    v->fat=v->base+reserved;
    v->data=v->base+overhead;
    v->root=v->fat32 ? u32(b+44) : v->fat+fats*fat_size;
    v->clusters=(total-overhead)/v->spc;
    return v->fat32 ? v->root>=2 && v->root<v->clusters+2 : v->clusters>=4085;
}
static int directory_sector(volume_t *v,uint32_t sector,entry_fn visit)
{
    uint8_t data[SECTOR];
    if(!read_sector(v,sector,data)) return 0;
    for(unsigned offset=0;offset<SECTOR;offset+=ENTRY) {
        const uint8_t *entry=data+offset;
        if(!entry[0]) return 0;
        if(entry[0]==0xe5 || entry[11]==ATTR_LFN || (entry[11]&8)) continue;
        if(!visit(v,entry) || v->error) return 0;
    }
    return 1;
}
static void directory(volume_t *v,uint32_t cluster,entry_fn visit)
{
    uint32_t remaining=v->clusters;
    while(cluster && !v->error) {
        if(cluster<2 || cluster>=v->clusters+2 || !remaining--) {
            v->error=MUSIC_BAD_CHAIN;return;
        }
        uint32_t sector=first_sector(v,cluster);
        for(uint32_t index=0;index<v->spc;index++)
            if(!directory_sector(v,sector+index,visit)) return;
        cluster=next_cluster(v,cluster);
    }
}
static int find_folders(volume_t *v,const uint8_t *entry)
{
    if(!(entry[11]&ATTR_DIR)) return 1;
    if(!memcmp(entry,"MUSIC      ",11)) v->music=entry_cluster(v,entry);
    if(!memcmp(entry,"LYRIC      ",11)) v->lyrics=entry_cluster(v,entry);
    return 1;
}
static int contiguous(volume_t *v,uint32_t cluster,uint32_t bytes)
{
    uint32_t count=(bytes-1)/(v->spc*SECTOR)+1;
    if(cluster<2 || cluster>=v->clusters+2 || count>v->clusters) {
        v->error=MUSIC_BAD_CHAIN;return 0;
    }
    while(--count) {
        uint32_t next=next_cluster(v,cluster);
        if(v->error) return 0;
        if(next!=cluster+1) {v->error=MUSIC_FRAGMENTED;return 0;}
        cluster=next;
    }
    return 1;
}
static void short_name(char *name,const uint8_t *entry)
{
    unsigned out=0;
    for(unsigned i=0;i<8 && entry[i]!=' ';i++) name[out++]=(char)entry[i];
    name[out]=0;
}
static int add_track(volume_t *v,const uint8_t *entry)
{
    if((entry[11]&ATTR_DIR) || memcmp(entry+8,"BIN",3)) return 1;
    uint32_t cluster=entry_cluster(v,entry),bytes=u32(entry+28);
    uint8_t header[SECTOR];
    if(bytes<SECTOR || cluster<2 || cluster>=v->clusters+2) {
        v->error=MUSIC_BAD_FILE;return 0;
    }
    uint32_t sector=first_sector(v,cluster);
    if(!read_sector(v,sector,header)) return 0;
    uint32_t frames=u32(header+8);
    if(memcmp(header,"ANLUWAV1",8) || !frames || frames>(bytes-SECTOR)/4 ||
       u16(header+12)!=48000 || u16(header+14)!=16 || u16(header+16)!=2) {
        v->error=MUSIC_BAD_FILE;return 0;
    }
    if(!contiguous(v,cluster,SECTOR+frames*4)) return 0;
    music_track_t *track=v->io->allocate(sizeof(*track));
    if(!track) {v->error=MUSIC_NO_MEMORY;return 0;}
    memset(track,0,sizeof(*track));
    track->sector=sector;track->frames=frames;short_name(track->name,entry);
    music_track_t **position=&v->result.first;
    while(*position && strcmp((*position)->name,track->name)<0) position=&(*position)->next;
    track->next=*position;*position=track;v->result.count++;
    return 1;
}
static int add_lyric(volume_t *v,const uint8_t *entry)
{
    if((entry[11]&ATTR_DIR) || memcmp(entry+8,"LYR",3)) return 1;
    char name[13];short_name(name,entry);
    for(music_track_t *track=v->result.first;track;track=track->next) {
        if(strcmp(track->name,name)) continue;
        uint32_t bytes=u32(entry+28),cluster=entry_cluster(v,entry);
        if(!bytes || !contiguous(v,cluster,bytes)) return 0;
        track->lyric_sector=first_sector(v,cluster);
    }
    return 1;
}
void music_catalog_free(const music_io_t *io,music_catalog_t *catalog)
{
    music_track_t *track=catalog->first;
    while(track) {music_track_t *next=track->next;io->release(track);track=next;}
    catalog->first=NULL;catalog->count=0;
}
music_catalog_t music_catalog_load(const music_io_t *io)
{
    volume_t v={0};v.io=io;v.fat_cache_sector=0xffffffffu;
    if(!mount(&v)) {v.result.error=v.error ? v.error : MUSIC_BAD_FS;return v.result;}
    if(v.fat32) directory(&v,v.root,find_folders);
    else for(uint32_t i=0;i<v.root_sectors;i++)
        if(!directory_sector(&v,v.root+i,find_folders)) break;
    if(!v.error && !v.music) v.error=MUSIC_NO_FOLDER;
    if(!v.error) directory(&v,v.music,add_track);
    if(!v.error && v.lyrics) directory(&v,v.lyrics,add_lyric);
    v.result.error=v.error;
    if(v.error) music_catalog_free(io,&v.result);
    return v.result;
}

static int find_settings(volume_t *v,const uint8_t *entry)
{
    if(memcmp(entry,"SETTINGSBIN",11)) return 1;
    uint32_t cluster=entry_cluster(v,entry);
    if(v->settings[0] || (entry[11]&(ATTR_DIR|1u)) || u32(entry+28)!=2*SECTOR ||
       cluster<2 || cluster>=v->clusters+2) {
        v->error=MUSIC_SETTINGS_INVALID;return 0;
    }
    uint32_t next=next_cluster(v,cluster);
    if(v->error) return 0;
    v->settings[0]=first_sector(v,cluster);
    v->settings[1]=v->settings[0]+1;
    if(v->spc==1) {
        if(!next || next==cluster) {v->error=MUSIC_BAD_CHAIN;return 0;}
        v->settings[1]=first_sector(v,next);
        next_cluster(v,next);
    }
    return !v->error;
}
int music_settings_sectors(const music_io_t *io,uint32_t *sectors)
{
    volume_t v={0};v.io=io;v.fat_cache_sector=UINT32_MAX;
    sectors[0]=sectors[1]=0;
    if(!mount(&v)) return v.error ? v.error : MUSIC_BAD_FS;
    if(v.fat32) directory(&v,v.root,find_settings);
    else for(uint32_t i=0;i<v.root_sectors;i++)
        if(!directory_sector(&v,v.root+i,find_settings)) break;
    if(v.error) return v.error;
    if(!v.settings[0]) return MUSIC_SETTINGS_MISSING;
    sectors[0]=v.settings[0];sectors[1]=v.settings[1];return 0;
}
