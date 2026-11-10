ENTRY(_start)

SECTIONS
{
  . = 0x10000000;
  .text : {
    *(.text.init)
    *(.text)
  }
  . = ALIGN(4);
  .rodata : {
    *(.rodata*)
  }
  .data : {
    *(.data*)
    *(.sdata*)
  }
  .bss : {
    *(.bss*)
    *(COMMON)
  }
  . = 0x80001000;
  .tohost : {
    *(.tohost)
    *(.htif)
  }
  /DISCARD/ : {
    *(.comment)
    *(.riscv.attributes)
  }
}
