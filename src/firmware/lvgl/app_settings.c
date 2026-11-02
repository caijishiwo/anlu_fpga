#include "app_settings.h"
#include "app_card.h"
#include "app_trace.h"
#include "music_catalog.h"
#include "ui_home.h"

static settings_store_t store;
static settings_state_t displayed=SETTINGS_UNAVAILABLE;
static uint32_t displayed_at;
static bool restored;
static const char *state_text(settings_state_t state)
{
    switch(state) {
    case SETTINGS_NEW:return "未保存";
    case SETTINGS_SAVED:return "已保存";
    case SETTINGS_PENDING:return "等待保存";
    case SETTINGS_WRITING:return "保存中";
    case SETTINGS_FAILED:return "保存失败";
    case SETTINGS_CORRUPT:return "配置损坏";
    case SETTINGS_UNAVAILABLE:return "缺少配置";
    }
    return "";
}
void app_settings_init(void)
{
    const music_io_t card={app_card_read,NULL,NULL,NULL};
    const settings_io_t io={app_card_read,app_card_write_start,app_card_write_poll,NULL};
    uint32_t sectors[2];
    int error=music_settings_sectors(&card,sectors);
    settings_open(&store,&io,sectors);
    if(error) app_trace_value("SETTINGS FILE ERROR ",(uint32_t)error);
    app_trace_value("SETTINGS LOAD STATE ",store.state);
    app_trace_value("SETTINGS LOAD ERROR ",(uint32_t)store.error);
    ui_home_set_save_status(state_text(store.state));
    restored=true;displayed=store.state;
}
const settings_values_t *app_settings_values(void) {return &store.observed;}
void app_settings_tick(const settings_values_t *values,uint32_t now)
{
    settings_observe(&store,values,now);settings_poll(&store,now);
    if(restored || displayed!=store.state) {
        restored=false;displayed=store.state;displayed_at=now;
        ui_home_set_save_status(state_text(displayed));
        app_trace_value("SETTINGS STATE ",displayed);
        if(store.error) app_trace_value("SETTINGS ERROR ",(uint32_t)store.error);
        if(displayed==SETTINGS_SAVED) app_trace_value("SETTINGS SAVED SEQ ",store.sequence);
    }
    if(displayed==SETTINGS_SAVED && (uint32_t)(now-displayed_at)>=SETTINGS_DELAY_CYCLES)
        ui_home_set_save_status("");
}
