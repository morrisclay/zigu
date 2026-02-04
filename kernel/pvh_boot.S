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

    // Enable SSE (required for Zig's code generation on x86_64)
    // Clear CR0.EM (bit 2) - disable x87 emulation
    // Set CR0.MP (bit 1) - monitor coprocessor
    mov %cr0, %rax
    and $0xFFFFFFFFFFFFFFFB, %rax  // Clear EM (bit 2)
    or $0x2, %rax                   // Set MP (bit 1)
    mov %rax, %cr0

    // Set CR4.OSFXSR (bit 9) - enable FXSAVE/FXRSTOR
    // Set CR4.OSXMMEXCPT (bit 10) - enable unmasked SSE exceptions
    mov %cr4, %rax
    or $0x600, %rax                 // Set OSFXSR and OSXMMEXCPT
    mov %rax, %cr4


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
