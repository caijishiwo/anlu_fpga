/* 按键只按当前上下文分发一次，避免菜单操作穿透到媒体页面。 */
enum { BRIGHTNESS_STEP=32, BRIGHTNESS_MAX=255,
       CONTRAST_STEP=32, CONTRAST_LOW=64, CONTRAST_HIGH=224,
       PHOTO_NEXT=1, PHOTO_PREV=2 };

static void trace_key_event(uint32_t events)
{
    const char *name="KEY COMBINED ";
    if(events&EVENT_EXIT) name="KEY4 LONG ";
    else if(events&EVENT_MENU) name="KEY4 SHORT ";
    else if(events==EVENT_NEXT) name="KEY2 ";
    else if(events==EVENT_PREV) name="KEY3 ";
    app_trace_value(name,events);
}

static void trace_ui_state(void)
{
    app_trace_value(player_mode ? "STATE LYRICS " : "STATE PHOTO ",menu_visible);
    if(menu_visible) {
        const char *name=editing ? "MENU EDIT " :
                         page_open ? "MENU DETAIL " : "MENU ROOT ";
        app_trace_value(name,selected);
        app_trace_value("MENU ROW ",selected_row);
    }
    app_trace_value("UI CTRL ",UI_CONTROL);
    app_trace_value("OSD CTRL ",OSD_CONTROL);
    if(editing) {
        app_trace_value("PICTURE LEVELS ",UI_LEVELS);
        app_trace_value("AUDIO SETTINGS ",UI_AUDIO_SETTINGS);
    }
}

static void trace_menu_action(ui_action_t action)
{
    static const char *const names[]={
        "NONE ","TRACK PREV ","TRACK NEXT ","TRACK MODE ","TRACK INFO ",
        "PHOTO PREV ","PHOTO NEXT ","PHOTO AUTO ","PHOTO INFO ",
        "LYRICS VISIBLE ","LYRIC INFO ","EFFECTS ","BRIGHTNESS ",
        "CONTRAST ","FLIP ","VOLUME ","BASS ","TREBLE ","MUTE ","PHOTO INTERVAL "};
    app_trace_value(names[action],action);
}

static void set_editing(bool enabled)
{
    editing=enabled;
    ui_pages_set_editing(enabled);
    app_trace_value(enabled ? "EDIT BEGIN " : "EDIT END ",selected_row);
}

static uint8_t picture_level_step(uint8_t value,int direction,bool is_contrast)
{
    int minimum=is_contrast ? CONTRAST_LOW : 0;
    int maximum=is_contrast ? CONTRAST_HIGH : BRIGHTNESS_MAX;
    int step=is_contrast ? CONTRAST_STEP : BRIGHTNESS_STEP;
    int result=value+direction*step;
    if(result<minimum) result=minimum;
    if(result>maximum) result=maximum;
    return (uint8_t)result;
}

static void adjust_parameter(int direction)
{
    ui_action_t action=ui_menu_specs[selected].rows[selected_row].action;
    if(action==UI_PHOTO_INTERVAL) {
        int seconds=photo_interval+direction;
        if(seconds<SETTINGS_INTERVAL_MIN) seconds=SETTINGS_INTERVAL_MIN;
        if(seconds>SETTINGS_INTERVAL_MAX) seconds=SETTINGS_INTERVAL_MAX;
        photo_interval=(uint8_t)seconds;set_photo_settings();return;
    }
    if(action==UI_BRIGHTNESS || action==UI_CONTRAST) {
        if(action==UI_BRIGHTNESS)
            brightness=picture_level_step(brightness,direction,false);
        else contrast=picture_level_step(contrast,direction,true);
        set_levels();
        return;
    }
    audio_controls=audio_controls_step(audio_controls,selected_row,direction);
    set_audio_controls();
}

static void activate_transport(ui_action_t action)
{
    if(action<=UI_MUSIC_MODE) {
        app_music_action(action-UI_MUSIC_PREV);
    } else if(action==UI_PHOTO_AUTO) {
        autoplay_on=!autoplay_on;set_photo_settings();
    } else {
        UI_PHOTO_COMMAND=action==UI_PHOTO_PREV ? PHOTO_PREV : PHOTO_NEXT;
    }
}

static void activate_toggle(ui_action_t action)
{
    switch(action) {
    case UI_LYRICS_VISIBLE: subtitle_on=!subtitle_on; break;
    case UI_EFFECTS: effects_on=!effects_on; break;
    case UI_FLIP: flip_on=!flip_on; break;
    case UI_MUTE:
        audio_controls.mute=!audio_controls.mute;
        set_audio_controls(); break;
    default: break;
    }
}

static void activate_row(void)
{
    const ui_row_spec_t *row=&ui_menu_specs[selected].rows[selected_row];
    if(row->kind==UI_INFO) {
        app_trace_value("MENU READONLY ",row->action);
        return;
    }
    trace_menu_action(row->action);
    if(row->kind==UI_NUMBER) {
        set_editing(!editing);
        return;
    }
    if(row->action<=UI_PHOTO_AUTO) activate_transport(row->action);
    else activate_toggle(row->action);
}

static void handle_long_key(void)
{
    if(!menu_visible) {
        app_trace_value("MENU IGNORE LONG ",selected);
        return;
    }
    if(editing) { set_editing(false); return; }
    if(page_open) {
        page_open=false;
        ui_pages_hide();
        app_trace_value("MENU BACK ",selected);
        return;
    }
    menu_visible=false;
    ui_home_exit();
    app_trace_value("MENU CLOSE ",selected);
}

static void advance_media(int direction)
{
    bool next=direction>0;
    const char *name;
    if(player_mode) {
        name=next ? "TRACK NEXT " : "TRACK PREV ";
        app_music_action(next ? 1u : 0u);
    } else {
        name=next ? "PHOTO NEXT " : "PHOTO PREV ";
        UI_PHOTO_COMMAND=next ? PHOTO_NEXT : PHOTO_PREV;
    }
    app_trace_value(name,next ? PHOTO_NEXT : PHOTO_PREV);
}

static void advance_selection(uint32_t events)
{
    int direction=((events&EVENT_NEXT)!=0)-((events&EVENT_PREV)!=0);
    if(direction==0) return;
    if(!menu_visible) {
        advance_media(direction);
        return;
    }
    if(editing) { adjust_parameter(direction); return; }
    if(page_open) {
        selected_row=ui_menu_step_row(selected,selected_row,direction);
        ui_pages_select(selected_row);
        return;
    }
    selected=(uint8_t)((selected+NAV_ITEMS+direction)%NAV_ITEMS);
    ui_home_select(selected);
}
