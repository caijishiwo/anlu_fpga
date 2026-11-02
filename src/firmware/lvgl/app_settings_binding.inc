static void set_photo_settings(void)
{
    UI_PHOTO_SETTINGS=((uint32_t)autoplay_on<<5)|photo_interval;
}
static void restore_settings(void)
{
    app_settings_init();
    const settings_values_t *v=app_settings_values();
    audio_controls=(audio_controls_t){v->volume,v->bass,v->treble,v->mute!=0};
    brightness=v->brightness;contrast=v->contrast;flip_on=v->flip!=0;
    subtitle_on=v->subtitle!=0;effects_on=v->effects!=0;
    autoplay_on=v->autoplay!=0;photo_interval=v->interval;
    set_photo_settings();set_levels();set_audio_controls();set_control();
}
static void update_settings(uint32_t now)
{
    const settings_values_t v={audio_controls.volume,audio_controls.bass,
        audio_controls.treble,audio_controls.mute,brightness,contrast,flip_on,
        subtitle_on,effects_on,app_music_sequential(),autoplay_on,photo_interval};
    app_settings_tick(&v,now);
}
