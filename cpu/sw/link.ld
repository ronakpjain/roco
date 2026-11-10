ENTRY(_start)

SECTIONS
{
  . = 0x10000000;
  .text : {
    *(.text.init)
    *(.text*)
  }
  . = ALIGN(4);
  .rodata : {
    *(.rodata*)
  }
  .data : {
    *(.data*)
  }
  .bss : {
    *(.bss*)
    *(COMMON)
  }
  /DISCARD/ : {
    *(.comment)
    *(.riscv.attributes)
  }
}
