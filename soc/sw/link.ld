ENTRY(_start)

PHDRS
{
  text PT_LOAD FLAGS(5); /* R E */
  data PT_LOAD FLAGS(6); /* RW */
}

SECTIONS
{
  . = 0x10000000;
  .text : {
    *(.text.init)
    *(.text*)
  } :text
  . = ALIGN(4);
  .rodata : {
    *(.rodata*)
  } :text
  .data : {
    *(.data*)
  } :data
  .bss : {
    *(.bss*)
    *(COMMON)
  } :data
  /DISCARD/ : {
    *(.comment)
    *(.riscv.attributes)
  }
}
