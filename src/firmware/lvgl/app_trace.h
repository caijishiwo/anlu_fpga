#ifndef APP_TRACE_H
#define APP_TRACE_H

#include <stdint.h>
#define APP_UART_DATA (*(volatile uint32_t *)0x02000008u)

// 沿用启动固件的串口配置；总线等待信号保证字符完整发送。
static void app_trace(const char *text)
{
    while (*text)
        APP_UART_DATA = (uint8_t)*text++;
}

static void app_trace_value(const char *name, uint32_t value)
{
    static const char digits[] = "0123456789ABCDEF";
    char text[11];
    for (unsigned index = 0; index < 8u; index++)
        text[index] = digits[(value >> (28u - index * 4u)) & 15u];
    text[8] = '\r'; text[9] = '\n'; text[10] = '\0';
    app_trace(name);
    app_trace(text);
}

#endif
