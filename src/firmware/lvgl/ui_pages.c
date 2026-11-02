#include "ui_pages.h"
#include "ui_menu_model.h"

extern const lv_font_t ui_font_chinese_20;
extern const lv_font_t ui_font_chinese_16;

enum {
    PAGE_COUNT = 5,
    ROW_COUNT = 4,
    CARD_X = 0,
    CARD_Y = 112,
    CARD_WIDTH = 224,
    CARD_HEIGHT = 200,
    ROW_START = 50,
    ROW_STEP = 34,
    MARK_WIDTH = 2,
    MARK_HEIGHT = 18,
    MARK_Y = 9,
    COLOR_INK = 0x000000,
    COLOR_IVORY = 0xFFFFFF,
    COLOR_CORAL = 0xFFFFFF,
};

static lv_obj_t *card;
static lv_obj_t *title_label;
static lv_obj_t *hint_label;
static lv_obj_t *row_bg[ROW_COUNT];
static lv_obj_t *row_name[ROW_COUNT];
static lv_obj_t *row_value[ROW_COUNT];
static lv_obj_t *row_mark[ROW_COUNT];
static uint8_t selected_row = ROW_COUNT;
static uint8_t current_page;

typedef struct { int32_t x,y,width,height; } box_bounds_t;
static lv_obj_t *box(lv_obj_t *parent, box_bounds_t bounds)
{
    lv_obj_t *object = lv_obj_create(parent);
    lv_obj_remove_style_all(object);
    lv_obj_set_scrollable(object, false);
    lv_obj_set_pos(object, bounds.x, bounds.y);
    lv_obj_set_size(object, bounds.width, bounds.height);
    return object;
}

static void make_header(void)
{
    lv_obj_t *accent = box(card, (box_bounds_t){16,43,CARD_WIDTH-32,1});
    lv_obj_set_style_bg_color(accent, lv_color_hex(COLOR_CORAL), 0);
    lv_obj_set_style_bg_opa(accent, LV_OPA_COVER, 0);

    title_label = lv_label_create(card);
    lv_obj_set_style_text_font(title_label, &ui_font_chinese_20, 0);
    lv_obj_set_style_text_color(title_label, lv_color_hex(COLOR_IVORY), 0);
    lv_obj_set_pos(title_label, 18, 14);
    hint_label = lv_label_create(card);
    lv_obj_set_style_text_font(hint_label, &ui_font_chinese_16, 0);
    lv_obj_set_style_text_color(hint_label, lv_color_hex(COLOR_IVORY), 0);
    lv_obj_set_pos(hint_label, 18, 180);
    lv_obj_set_width(hint_label, 188);
}

static void make_rows(void)
{
    for (uint8_t row = 0; row < ROW_COUNT; row++) {
        int32_t y = ROW_START + row * ROW_STEP;
        row_bg[row] = box(card, (box_bounds_t){12,y-5,CARD_WIDTH-24,35});
        lv_obj_set_style_radius(row_bg[row], 5, 0);
        lv_obj_set_style_bg_color(row_bg[row], lv_color_hex(COLOR_CORAL), 0);
        lv_obj_set_style_bg_opa(row_bg[row], LV_OPA_TRANSP, 0);
        row_mark[row] = box(row_bg[row], (box_bounds_t){0,MARK_Y,MARK_WIDTH,MARK_HEIGHT});
        lv_obj_set_style_bg_color(row_mark[row], lv_color_hex(COLOR_CORAL), 0);
        lv_obj_set_style_bg_opa(row_mark[row], LV_OPA_TRANSP, 0);

        row_name[row] = lv_label_create(row_bg[row]);
        lv_obj_set_style_text_font(row_name[row], &ui_font_chinese_20, 0);
        lv_obj_set_style_text_color(row_name[row], lv_color_hex(COLOR_IVORY), 0);
        lv_obj_set_pos(row_name[row], 12, 7);

        row_value[row] = lv_label_create(row_bg[row]);
        lv_obj_set_style_text_font(row_value[row], &ui_font_chinese_20, 0);
        lv_obj_set_style_text_color(row_value[row], lv_color_hex(COLOR_CORAL), 0);
        lv_obj_set_pos(row_value[row], 128, 7);
        lv_obj_set_width(row_value[row], 70);
        lv_label_set_long_mode(row_value[row], LV_LABEL_LONG_MODE_DOTS);
    }
}

void ui_pages_create(lv_obj_t *parent)
{
    selected_row = ROW_COUNT;
    card = box(parent, (box_bounds_t){CARD_X,CARD_Y,CARD_WIDTH,CARD_HEIGHT});
    lv_obj_set_style_bg_color(card, lv_color_hex(COLOR_INK), 0);
    lv_obj_set_style_bg_opa(card, LV_OPA_COVER, 0);
    make_header();
    make_rows();
    lv_obj_set_hidden(card, true);
}

void ui_pages_show(uint8_t page)
{
    if (page >= PAGE_COUNT)
        return;
    if (selected_row < ROW_COUNT) {
        lv_obj_set_style_bg_opa(row_mark[selected_row], LV_OPA_TRANSP, 0);
        lv_obj_set_style_border_width(row_bg[selected_row], 0, 0);
    }
    current_page = page;
    selected_row = ROW_COUNT;
    lv_label_set_text(title_label, ui_menu_specs[page].title);
    for (uint8_t row = 0; row < ROW_COUNT; row++) {
        lv_obj_set_hidden(row_bg[row], row >= ui_menu_specs[page].count);
        const char *label = ui_menu_specs[page].rows[row].label;
        lv_label_set_text(row_name[row], label ? label : "");
        lv_label_set_text(row_value[row], "--");
    }
    lv_obj_set_hidden(card, false);
    ui_pages_select(0u);
    ui_pages_set_editing(false);
}

void ui_pages_hide(void)
{
    lv_obj_set_hidden(card, true);
}

void ui_pages_select(uint8_t selected)
{
    if (selected >= ui_menu_specs[current_page].count || selected == selected_row ||
        ui_menu_specs[current_page].rows[selected].kind == UI_INFO)
        return;
    if (selected_row < ROW_COUNT)
        lv_obj_set_style_bg_opa(row_mark[selected_row], LV_OPA_TRANSP, 0);
    lv_obj_set_style_bg_opa(row_mark[selected], LV_OPA_COVER, 0);
    selected_row = selected;
}

void ui_pages_set_editing(bool editing)
{
    if (selected_row < ROW_COUNT) {
        lv_obj_set_style_border_color(row_bg[selected_row], lv_color_hex(COLOR_IVORY), 0);
        lv_obj_set_style_border_width(row_bg[selected_row], editing ? 1 : 0, 0);
    }
    lv_label_set_text(hint_label, editing ? "上下调节 短按确认" : "短按确认 长按退");
}

void ui_pages_set_value(uint8_t row, const char *value)
{
    if (row < ROW_COUNT && lv_strcmp(lv_label_get_text(row_value[row]), value) != 0)
        lv_label_set_text(row_value[row], value);
}
