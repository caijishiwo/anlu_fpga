#include "ui_home.h"
#include "ui_menu_model.h"
extern const lv_font_t ui_font_chinese_20;
extern const lv_font_t ui_font_chinese_16;
enum { ITEM_COUNT=5, MENU_X=224, MENU_WIDTH=160, MENU_HEIGHT=228,
       ROW_TOP=42, ROW_STEP=32, ROW_HEIGHT=24, MENU_LETTER_SPACE=1,
       MARK_WIDTH=2, MARK_HEIGHT=20,
       COUNTER_Y=56, PROGRESS_Y=104, PROGRESS_WIDTH=96,
       SAMPLE_RATE=48000, TIME_X=128, TIME_WIDTH=80 };
static lv_obj_t *screen, *menu_layer, *marks[ITEM_COUNT];
static lv_obj_t *elapsed_label, *duration_label, *photo_label, *track_label;
static lv_obj_t *cue_label;
static char save_status[32];
static lv_obj_t *progress_line;
static uint8_t selected_item=ITEM_COUNT;
static uint32_t photo_number=1, photo_count;
static const char *const icons[ITEM_COUNT]={LV_SYMBOL_AUDIO,LV_SYMBOL_IMAGE,
    LV_SYMBOL_LIST,LV_SYMBOL_EYE_OPEN,LV_SYMBOL_SETTINGS};
static void flat(lv_obj_t *object)
{
    lv_obj_remove_style_all(object);
    lv_obj_set_scrollable(object,false);
    lv_obj_set_style_bg_color(object,lv_color_black(),0);
    lv_obj_set_style_bg_opa(object,LV_OPA_COVER,0);
}
static void navigation_row(uint8_t index)
{
    int32_t y=ROW_TOP+index*ROW_STEP;
    marks[index]=lv_obj_create(menu_layer);
    flat(marks[index]);
    lv_obj_set_pos(marks[index],8,y+(ROW_HEIGHT-MARK_HEIGHT)/2);
    lv_obj_set_size(marks[index],MARK_WIDTH,MARK_HEIGHT);
    lv_obj_t *icon=lv_label_create(menu_layer);
    lv_label_set_text(icon,icons[index]);
    lv_obj_set_style_text_font(icon,&lv_font_montserrat_14,0);
    lv_obj_set_style_text_color(icon,lv_color_white(),0);
    lv_obj_set_pos(icon,24,y+(ROW_HEIGHT-lv_font_montserrat_14.line_height)/2);
    lv_obj_t *name=lv_label_create(menu_layer);
    lv_label_set_text(name,ui_menu_specs[index].title);
    lv_obj_set_style_text_font(name,&ui_font_chinese_20,0);
    lv_obj_set_style_text_letter_space(name,MENU_LETTER_SPACE,0);
    lv_obj_set_style_text_color(name,lv_color_white(),0);
    lv_obj_set_pos(name,48,y);
}
static lv_obj_t *footer_label(const char *text, int32_t y)
{
    lv_obj_t *label=lv_label_create(screen);
    lv_label_set_text(label,text);
    lv_obj_set_style_text_font(label,&ui_font_chinese_16,0);
    lv_obj_set_style_text_color(label,lv_color_white(),0);
    lv_obj_set_pos(label,0,y);
    return label;
}
static void create_footer(void)
{
    track_label=footer_label("--",0);
    lv_obj_set_width(track_label,192);
    lv_obj_set_style_text_align(track_label,LV_TEXT_ALIGN_CENTER,0);
    lv_obj_t *cue=footer_label("正在播放",24);
    cue_label=cue;
    lv_obj_set_width(cue,128);
    lv_obj_set_style_text_align(cue,LV_TEXT_ALIGN_CENTER,0);
    elapsed_label=footer_label("00:00",24);
    lv_obj_set_x(elapsed_label,TIME_X);
    lv_obj_set_style_text_font(elapsed_label,&lv_font_montserrat_14,0);
    duration_label=footer_label("00:00",56);
    lv_obj_set_x(duration_label,TIME_X);
    lv_obj_set_width(duration_label,TIME_WIDTH);
    lv_obj_set_style_text_align(duration_label,LV_TEXT_ALIGN_RIGHT,0);
    lv_obj_set_style_text_font(duration_label,&lv_font_montserrat_14,0);
    photo_label=footer_label("01 / 00",COUNTER_Y);
    lv_obj_set_style_text_font(photo_label,&lv_font_montserrat_14,0);
    lv_obj_set_width(photo_label,128);
    lv_obj_set_style_text_align(photo_label,LV_TEXT_ALIGN_RIGHT,0);
    progress_line=lv_obj_create(screen);
    flat(progress_line);
    lv_obj_set_style_bg_color(progress_line,lv_color_white(),0);
    lv_obj_set_pos(progress_line,0,PROGRESS_Y);
    lv_obj_set_size(progress_line,0,1);
}
static void update_photo_label(void)
{
    char text[24];
    lv_snprintf(text,sizeof(text),"%02u / %02u",(unsigned)photo_number,
                (unsigned)photo_count);
    if(save_status[0]) lv_snprintf(text,sizeof(text),"%s",save_status);
    lv_obj_set_style_text_font(photo_label,save_status[0] ?
                              &ui_font_chinese_16 : &lv_font_montserrat_14,0);
    if(lv_strcmp(lv_label_get_text(photo_label),text)!=0)
        lv_label_set_text(photo_label,text);
}
void ui_home_set_save_status(const char *text)
{
    if(lv_strcmp(save_status,text)==0) return;
    lv_snprintf(save_status,sizeof(save_status),"%s",text);
    lv_label_set_text(cue_label,text[0] ? text : "正在播放");
    update_photo_label();
}
void ui_home_set_image_count(uint32_t count)
{
    photo_count=count;
    update_photo_label();
}
void ui_home_set_progress(uint32_t frames, uint32_t total_frames)
{
    char text[16];
    uint32_t seconds=total_frames/SAMPLE_RATE;
    lv_snprintf(text,sizeof(text),"%02u:%02u",(unsigned)(seconds/60u),
                (unsigned)(seconds%60u));
    if(lv_strcmp(lv_label_get_text(duration_label),text)!=0)
        lv_label_set_text(duration_label,text);
    uint32_t width=0;
    if(total_frames!=0)
        width=frames>=total_frames ? PROGRESS_WIDTH :
              (uint32_t)((uint64_t)frames*PROGRESS_WIDTH/total_frames);
    if(lv_obj_get_width(progress_line)!=(int32_t)width)
        lv_obj_set_width(progress_line,(int32_t)width);
}
void ui_home_set_track(const char *name)
{
    char text[32];
    lv_snprintf(text,sizeof(text),"%s",name);
    if(lv_strcmp(lv_label_get_text(track_label),text)!=0)
        lv_label_set_text(track_label,text);
}
void ui_home_set_key_diagnostics(uint8_t event,bool menu_open,bool menu_drawn)
{
    enum { DIAGNOSTIC_TEXT_BYTES=16 };
    char text[DIAGNOSTIC_TEXT_BYTES];
    lv_snprintf(text,sizeof(text),"K%02X M%u D%u",(unsigned)event,
                (unsigned)menu_open,(unsigned)menu_drawn);
    // 两页各使用已存在的文字窗口，诊断开关关闭时不会调用。
    if(lv_strcmp(lv_label_get_text(track_label),text)!=0)
        lv_label_set_text(track_label,text);
    if(lv_strcmp(lv_label_get_text(photo_label),text)!=0)
        lv_label_set_text(photo_label,text);
}
void ui_home_set_status(uint32_t seconds, uint32_t photo)
{
    char time_text[16];
    lv_snprintf(time_text,sizeof(time_text),"%02u:%02u",(unsigned)(seconds/60u),
                (unsigned)(seconds%60u));
    if(lv_strcmp(lv_label_get_text(elapsed_label),time_text)!=0)
        lv_label_set_text(elapsed_label,time_text);
    photo_number=photo;
    update_photo_label();
}
lv_obj_t *ui_home_create(void)
{
    if(screen!=NULL) return NULL;
    screen=lv_obj_create(NULL);
    flat(screen);
    create_footer();
    menu_layer=lv_obj_create(screen);
    flat(menu_layer);
    lv_obj_set_pos(menu_layer,MENU_X,0);
    lv_obj_set_size(menu_layer,MENU_WIDTH,MENU_HEIGHT);
    lv_obj_t *heading=lv_label_create(menu_layer);
    lv_label_set_text(heading,"菜单");
    lv_obj_set_style_text_font(heading,&ui_font_chinese_20,0);
    lv_obj_set_style_text_letter_space(heading,MENU_LETTER_SPACE,0);
    lv_obj_set_style_text_color(heading,lv_color_white(),0);
    lv_obj_set_pos(heading,16,12);
    for(uint8_t index=0;index<ITEM_COUNT;index++) navigation_row(index);
    lv_obj_t *hint=lv_label_create(menu_layer);
    lv_label_set_text(hint,"短按确认 长按退");
    lv_obj_set_style_text_font(hint,&ui_font_chinese_16,0);
    lv_obj_set_style_text_letter_space(hint,MENU_LETTER_SPACE,0);
    lv_obj_set_style_text_color(hint,lv_color_white(),0);
    lv_obj_set_pos(hint,16,206);
    lv_obj_set_hidden(menu_layer,true);
    lv_screen_load(screen);
    return screen;
}
bool ui_home_select(uint8_t selected)
{
    if(menu_layer==NULL || selected>=ITEM_COUNT) return false;
    if(selected==selected_item) return true;
    if(selected_item<ITEM_COUNT)
        lv_obj_set_style_bg_color(marks[selected_item],lv_color_black(),0);
    lv_obj_set_style_bg_color(marks[selected],lv_color_white(),0);
    selected_item=selected;
    return true;
}
void ui_home_enter(void)
{
    if(menu_layer!=NULL) lv_obj_set_hidden(menu_layer,false);
}
void ui_home_exit(void)
{
    if(menu_layer!=NULL) lv_obj_set_hidden(menu_layer,true);
}
