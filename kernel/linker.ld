ENTRY(_start)

SECTIONS
{
  . = 1M;

  /* PVH note for Firecracker direct boot */
  .note.PVH ALIGN(4) : {
    KEEP(*(.note.PVH))
  }

  /* Multiboot2 header must be in first 32KB */
  .multiboot ALIGN(8) : {
    KEEP(*(.multiboot))
  }

  .text ALIGN(4K) : {
    KEEP(*(.text.multiboot_entry))
    KEEP(*(.text.pvh_start))
    *(.text*)
  }

  .rodata ALIGN(4K) : {
    *(.rodata*)
  }

  .data ALIGN(4K) : {
    *(.data*)
  }

  .bss ALIGN(4K) : {
    *(COMMON)
    *(.bss*)
  }
}
