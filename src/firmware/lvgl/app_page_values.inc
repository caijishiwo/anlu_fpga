static const char *transport_value(ui_action_t action,uint8_t row)
{
    uint32_t images=UI_IMAGE_INFO;
    unsigned count=(images>>5)&63u;
    if(action==UI_PHOTO_POSITION) {
        lv_snprintf(number_text[row],sizeof(number_text[row]),"%u/%u",
                    count ? (images&31u)+1u : 0u,count);
        return number_text[row];
    }
    if(action==UI_MUSIC_MODE) return app_music_sequential() ? "顺序" : "单曲";
    if(action==UI_TRACK) return app_music_error() ? "异常" : app_music_name();
    if(action==UI_PHOTO_AUTO) return autoplay_on ? "开" : "关";
    if(action==UI_PHOTO_INTERVAL) {
        lv_snprintf(number_text[row],sizeof(number_text[row]),"%u秒",photo_interval);
        return number_text[row];
    }
    return "切换";
}

static const char *display_value(ui_action_t action,uint8_t row)
{
    switch(action) {
    case UI_LYRICS_VISIBLE: return subtitle_on ? "开" : "关";
    case UI_LYRIC_POSITION: return decimal_value(row,UI_LYRIC_LINE+1u);
    case UI_EFFECTS: return effects_on ? "开" : "关";
    case UI_BRIGHTNESS: return decimal_value(row,brightness);
    case UI_CONTRAST: return decimal_value(row,contrast);
    case UI_FLIP: return flip_on ? "开" : "关";
    default: return "--";
    }
}

static const char *audio_value(ui_action_t action)
{
    static const char *const volume[]={"0%","13%","25%","38%","50%",
                                      "63%","75%","88%","100%"};
    static const char *const tone[]={"-2","-1","0","+1","+2"};
    switch(action) {
    case UI_VOLUME: return volume[audio_controls.volume];
    case UI_BASS: return tone[audio_controls.bass];
    case UI_TREBLE: return tone[audio_controls.treble];
    case UI_MUTE: return audio_controls.mute ? "开" : "关";
    default: return "--";
    }
}

static void update_page(uint32_t now)
{
    static uint32_t last_update;
    if(!page_open || (uint32_t)(now-last_update)<CPU_HZ/4u) return;
    last_update=now;
    for(uint8_t row=0;row<ui_menu_specs[selected].count;row++) {
        ui_action_t action=ui_menu_specs[selected].rows[row].action;
        const char *value=action<=UI_PHOTO_POSITION || action==UI_PHOTO_INTERVAL ? transport_value(action,row) :
                          action<UI_VOLUME ? display_value(action,row) : audio_value(action);
        ui_pages_set_value(row,value);
    }
}
