/* STM32F401RE Linker Script
 *
 * Memory Layout:
 *   Flash: 512KB at 0x08000000
 *   SRAM:  96KB at 0x20000000
 *
 * The vector table is placed at the start of flash (0x08000000).
 * When the CPU boots, it reads the initial SP from 0x08000000
 * and the reset vector from 0x08000004.
 */

MEMORY
{
    FLASH (rx)  : ORIGIN = 0x08000000, LENGTH = 512K
    SRAM  (rwx) : ORIGIN = 0x20000000, LENGTH = 96K
}

/* Entry point */
ENTRY(_reset)

/* Stack size */
__stack_size = 8K;

SECTIONS
{
    /* Vector table must be first - CPU reads this at boot */
    .vector_table :
    {
        . = ALIGN(4);
        KEEP(*(.vector_table))
        . = ALIGN(4);
    } > FLASH

    /* Code and read-only data */
    .text :
    {
        . = ALIGN(4);
        *(.text)
        *(.text*)
        *(.rodata)
        *(.rodata*)
        . = ALIGN(4);
        __etext = .;
    } > FLASH

    /* Initialized data - stored in flash, copied to RAM at startup */
    .data :
    {
        . = ALIGN(4);
        __data_start = .;
        *(.data)
        *(.data*)
        . = ALIGN(4);
        __data_end = .;
    } > SRAM AT > FLASH

    __data_load = LOADADDR(.data);

    /* Uninitialized data - zeroed at startup */
    .bss :
    {
        . = ALIGN(4);
        __bss_start = .;
        *(.bss)
        *(.bss*)
        *(COMMON)
        . = ALIGN(4);
        __bss_end = .;
    } > SRAM

    /* Stack - grows downward from top of RAM */
    .stack (NOLOAD) :
    {
        . = ALIGN(8);
        . = . + __stack_size;
        . = ALIGN(8);
        __stack_top = .;
    } > SRAM

    /* Heap - everything between BSS and stack */
    .heap (NOLOAD) :
    {
        . = ALIGN(4);
        __heap_start = .;
        . = ORIGIN(SRAM) + LENGTH(SRAM) - __stack_size;
        __heap_end = .;
    } > SRAM
}

/* Provide symbols for startup code */
PROVIDE(__stack_top = ORIGIN(SRAM) + LENGTH(SRAM));
