#ifndef APP_RUNTIME_H
#define APP_RUNTIME_H

#include <stdint.h>
#include "lvgl.h"

// 无符号差值处理周期计数回绕；余数保留，长绘图后只补时一次。
static uint32_t app_advance_tick(uint32_t now, uint32_t previous, uint32_t cycles_per_ms)
{
    uint32_t elapsed = (uint32_t)(now - previous) / cycles_per_ms;
    if (elapsed != 0u)
        lv_tick_inc(elapsed);
    return previous + elapsed * cycles_per_ms;
}

#endif
