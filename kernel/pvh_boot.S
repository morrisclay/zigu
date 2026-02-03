// PVH boot protocol support for QEMU and Firecracker
// Provides the ELF note and entry point for PVH direct boot

.section .note.PVH, "a", @note
.align 4
pvh_note:
    .long 4                     // namesz: length of "PVH\0"
    .long 4                     // descsz: size of entry address
    .long 18                    // type: XEN_ELFNOTE_PHYS32_ENTRY
    .asciz "PVH"                // name
    .long pvh_start             // entry: 32-bit address of pvh_start

.section .text.pvh_start, "ax", @progbits
.globl pvh_start
.type pvh_start, @function
.code64
pvh_start:
    // QEMU/Firecracker enter here in 64-bit long mode
    // Set up stack pointer (use end of BSS + 16KB)
    lea boot_stack_top(%rip), %rsp
    // Clear direction flag
    cld
    // Clear frame pointer for stack traces
    xor %rbp, %rbp
    // Jump to Zig _start
    jmp _start

.section .bss
.align 16
.globl boot_stack
boot_stack:
    .space 16384                // 16KB stack
.globl boot_stack_top
boot_stack_top:
