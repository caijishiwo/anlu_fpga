#include <stdbool.h>
#include <stdint.h>
#include "lvgl.h"
#include "ui_home.h"
#include "ui_pages.h"
#include "app_trace.h"
#include "app_runtime.h"
#include "app_osd.h"
#include "app_music.h"
#include "app_audio_controls.h"
#include "ui_menu_model.h"
#include "app_settings.h"
#ifndef APP_KEY_DIAGNOSTICS
#define APP_KEY_DIAGNOSTICS 0
#endif
#define UI_EVENTS (*(volatile uint32_t *)0x03000004u)
#define UI_CONTROL (*(volatile uint32_t *)0x0300000cu)
#define UI_IMAGE_INFO (*(volatile uint32_t *)0x03000008u)
#define UI_LEVELS (*(volatile uint32_t *)0x03000010u)
#define UI_AUDIO_FRAME (*(volatile uint32_t *)0x03000014u)
#define UI_LYRIC_LINE (*(volatile uint32_t *)0x03000018u)
#define UI_SD_STATUS (*(volatile uint32_t *)0x0300001cu)
#define UI_AUDIO_SETTINGS (*(volatile uint32_t *)0x03000040u)
#define UI_PHOTO_COMMAND (*(volatile uint32_t *)0x03000044u)
#define UI_PHOTO_SETTINGS (*(volatile uint32_t *)0x03000048u)
#define FRAME_A ((void *)0x04000000u)
#define CPU_HZ 25000000u
#define AUDIO_SAMPLE_RATE 48000u
#define CYCLES_PER_MS (CPU_HZ / 1000u)
#define EVENT_NEXT (1u << 0)
#define EVENT_PREV (1u << 1)
#define EVENT_MENU (1u << 2)
#define EVENT_EXIT (1u << 3)
#define NAV_ITEMS 5u
#define PHOTO_MENU_ITEM 1u
#define LYRICS_MENU_ITEM 2u
#define UI_BASE_CONTROL 1u

static bool menu_visible, frame_ready, page_open;
static bool player_mode;
static bool editing;
static bool displayed_menu, displayed_page;
static uint32_t render_started;
static bool subtitle_on = true, effects_on = true;
static bool flip_on;
static bool autoplay_on;
static uint8_t photo_interval=SETTINGS_INTERVAL_MIN;
static uint8_t selected, selected_row;
static uint8_t brightness = 255u, contrast = 128u;
static audio_controls_t audio_controls={8u,2u,2u,false};
static char number_text[4][12];
#if APP_KEY_DIAGNOSTICS
static uint8_t last_key_event;
#endif
static uint32_t read_cycles(void)
{
    uint32_t cycles;
    __asm__ volatile ("rdcycle %0" : "=r"(cycles));
    return cycles;
}
static void set_control(void)
{
    UI_CONTROL = UI_BASE_CONTROL |
                 ((uint32_t)frame_ready << 9) |
                 ((uint32_t)(menu_visible || player_mode) << 1) |
                 ((uint32_t)selected << 2) |
                 ((uint32_t)flip_on << 5) |
                 ((uint32_t)subtitle_on << 6) |
                 ((uint32_t)effects_on << 7) |
                 ((uint32_t)!player_mode << 8);
    OSD_CONTROL = (uint32_t)frame_ready |
                  ((uint32_t)player_mode << 1) |
                  ((uint32_t)(displayed_menu && menu_visible) << 2) |
                  ((uint32_t)displayed_page << 3) |
                  ((uint32_t)player_mode << 4);
}
static void set_levels(void)
{
    UI_LEVELS = ((uint32_t)contrast << 8) | brightness;
}
static void set_audio_controls(void)
{
    UI_AUDIO_SETTINGS=audio_controls_pack(audio_controls);
}

static void flush_display(lv_display_t *display, const lv_area_t *area,
                          uint8_t *pixels)
{
    static uint32_t logged_selection=UINT32_MAX;
    static bool logged_editing;
    bool state_changed=!frame_ready || displayed_menu!=menu_visible ||
                       displayed_page!=page_open;
    uint32_t selection=selected*UI_ROW_COUNT+selected_row;
    osd_copy_area(area, pixels, OSD_MEMORY);
    if (!frame_ready) app_trace("FIRST FRAME\r\n");
    frame_ready = true;
    if (lv_display_flush_is_last(display)) {
        displayed_menu = menu_visible;
        displayed_page = page_open;
        set_control();
        // 普通歌词/计时刷新不刷屏；记录菜单状态、选项和编辑框提交。
        if(state_changed || logged_selection!=selection || logged_editing!=editing) {
            app_trace_value("OSD COMMIT ",OSD_CONTROL);
            app_trace_value("DRAW CYCLES ",read_cycles()-render_started);
            logged_selection=selection;
            logged_editing=editing;
        }
    }
    lv_display_flush_ready(display);
}
#include "app_settings_binding.inc"
#include "app_view_actions.inc"

static void handle_menu_key(void)
{
    if (!menu_visible) {
        menu_visible = true;
        ui_home_enter();
        app_trace_value("MENU OPEN ",selected);
    } else if (!page_open) {
        if (selected == PHOTO_MENU_ITEM) {
            player_mode = false;
            app_trace_value("VIEW PHOTO ",selected);
        } else if (selected == LYRICS_MENU_ITEM) {
            player_mode = true;
            menu_visible = false;
            ui_home_exit();
            app_trace_value("VIEW LYRICS ",selected);
            app_trace_value("MENU CLOSE ",selected);
            return;
        }
        page_open = true;
        selected_row = 0u;
        ui_pages_show(selected);
        app_trace_value("MENU ENTER ",selected);
    } else {
        activate_row();
    }
}

static void handle_keys(void)
{
    uint32_t events = UI_EVENTS;
    if (events == 0u)
        return;
    UI_EVENTS = events;
#if APP_KEY_DIAGNOSTICS
    last_key_event=(uint8_t)events;
#endif
    trace_key_event(events);
    if (events & EVENT_EXIT)
        handle_long_key();
    else if (events & EVENT_MENU)
        handle_menu_key();
    else advance_selection(events);
    set_control();
    trace_ui_state();
}
static void update_player(uint32_t now)
{
    static uint32_t last_status;
    if ((uint32_t)(now-last_status)<CPU_HZ)
        return;
    last_status=now;
    uint32_t frames=UI_AUDIO_FRAME, images=UI_IMAGE_INFO;
    ui_home_set_status(frames/AUDIO_SAMPLE_RATE,(images&31u)+1u);
    ui_home_set_image_count((images>>5)&63u);
    ui_home_set_progress(frames,app_music_total_frames());
    ui_home_set_track(app_music_name());
}
static const char *decimal_value(uint8_t row, uint32_t value)
{
    char reversed[10];
    uint8_t count = 0u;
    do {
        reversed[count++] = (char)('0' + value % 10u);
        value /= 10u;
    } while (value != 0u);
    for (uint8_t index = 0; index < count; index++)
        number_text[row][index] = reversed[count - index - 1u];
    number_text[row][count] = '\0';
    return number_text[row];
}
#include "app_page_values.inc"

static void show_key_diagnostics(void)
{
#if APP_KEY_DIAGNOSTICS
    ui_home_set_key_diagnostics(last_key_event,menu_visible,displayed_menu);
#endif
}

static void create_display(void)
{
    lv_init();
    app_trace("LV INIT OK\r\n");
    lv_display_t *display = lv_display_create(OSD_WIDTH, OSD_HEIGHT);
    lv_display_set_color_format(display, LV_COLOR_FORMAT_I1);
    lv_display_set_buffers(display, FRAME_A, NULL,
                           OSD_BUFFER_BYTES,
                           LV_DISPLAY_RENDER_MODE_DIRECT);
    lv_display_set_flush_cb(display, flush_display);
    lv_obj_t *screen = ui_home_create();
    app_trace("HOME OK\r\n");
    ui_pages_create(screen);
    app_trace("PAGES OK\r\n");
    ui_home_select(0u);
    set_levels();
    set_audio_controls();
    set_control();
    render_started = read_cycles();
    lv_timer_handler();
}

int main(void)
{
    app_trace("APP MAIN KEY4_MENU LOG_V1\r\n");
    if ((OSD_CONTROL & 0xffffffe0u) != 0x4f534500u ||
        UI_PHOTO_COMMAND != 0x50484f31u) {
        app_trace("OSD BIT REQUIRED\r\n");
        for (;;) __asm__ volatile ("wfi");
    }
    create_display();
    restore_settings();
    app_music_init();
    app_music_set_sequential(app_settings_values()->sequential!=0);
    app_trace("APP READY KEY2/3 MEDIA KEY4 MENU\r\n");
    trace_ui_state();
    uint32_t last_tick = read_cycles();
    for (;;) {
        uint32_t now = read_cycles();
        last_tick = app_advance_tick(now, last_tick, CYCLES_PER_MS);
        handle_keys();
        app_music_tick();
        update_player(now);
        update_page(now);
        update_settings(now);
        show_key_diagnostics();
        render_started = read_cycles();
        lv_timer_handler();
    }
}
