ENTRY(_start)
SECTIONS {
    . = 0x20000;
    .text : { *(.text.start) *(.text*) *(.rodata*) }
    .data : { *(.data*) }
    PROVIDE(__global_pointer$ = . + 0x800);
    . = 0x00000100;
    .bss (NOLOAD) : { __bss_start = .; *(.bss*) *(COMMON) __bss_end = .; }
}
