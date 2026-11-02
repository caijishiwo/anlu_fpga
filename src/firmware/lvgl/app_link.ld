ENTRY(_start)
PHDRS {
    text PT_LOAD FLAGS(5);
    data PT_LOAD FLAGS(6);
}
SECTIONS {
    . = 0x04258000;
    .text : {
        *(.text.start)
        *(.text*)
        *(.rodata*)
    } :text
    .data : {
        *(.data*)
        *(.sdata*)
    } :data
    PROVIDE(__global_pointer$ = . + 0x800);
    . = ALIGN(4);
    .bss (NOLOAD) : {
        __bss_start = .;
        *(.bss*)
        *(.sbss*)
        *(COMMON)
        . = ALIGN(4);
        __bss_end = .;
    } :data
    __app_end = .;
    ASSERT(__app_end <= 0x04350000, "LVGL application exceeds SDRAM region")
}
