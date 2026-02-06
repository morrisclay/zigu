// PVH boot protocol support for Firecracker
// Provides the ELF note and entry point for PVH direct boot
//
// PVH entry state (XEN_ELFNOTE_PHYS32_ENTRY):
//   - 32-bit protected mode, paging disabled
//   - CR0: PE set, PG clear
//   - EFER: 0 (no long mode)
//   - EBX: physical address of hvm_start_info structure
//   - Flat 32-bit segments (base=0, limit=4GB)

.section .note.PVH, "a", @note
.align 4
pvh_note:
    .long 4                     // namesz: length of "PVH\0"
    .long 4                     // descsz: size of entry address
    .long 18                    // type: XEN_ELFNOTE_PHYS32_ENTRY
    .asciz "PVH"                // name
    .long pvh_start             // entry: 32-bit physical address

.section .text.pvh_start, "ax", @progbits
.globl pvh_start
.type pvh_start, @function
.code32
pvh_start:
    // Entered in 32-bit protected mode, paging off
    cli

    // Save hvm_start_info pointer (in ebx) for future use
    mov %ebx, %esi

    // Set up identity-mapped page tables (first 4GB with 2MB pages)
    // PML4 at 0x1000, PDPT at 0x2000, PD0-PD3 at 0x3000-0x6000
    // 4GB needed: virtio-MMIO devices are at 0xd0000000 (~3.25GB)

    // Clear page table area (0x1000..0x6FFF = 24KB)
    mov $0x1000, %edi
    xor %eax, %eax
    mov $0x6000, %ecx
    rep stosb

    // PML4[0] -> PDPT at 0x2000
    mov $0x1000, %edi
    mov $0x2003, %eax           // PDPT addr | present | writable
    mov %eax, (%edi)

    // PDPT[0] -> PD0 at 0x3000 (0-1GB)
    mov $0x2000, %edi
    mov $0x3003, %eax           // PD addr | present | writable
    mov %eax, (%edi)

    // PDPT[1] -> PD1 at 0x4000 (1-2GB)
    mov $0x4003, %eax
    mov %eax, 8(%edi)

    // PDPT[2] -> PD2 at 0x5000 (2-3GB)
    mov $0x5003, %eax
    mov %eax, 16(%edi)

    // PDPT[3] -> PD3 at 0x6000 (3-4GB)
    mov $0x6003, %eax
    mov %eax, 24(%edi)

    // Fill all 4 PDs: 4 x 512 x 2MB pages = 4GB identity map
    mov $0x3000, %edi
    mov $0x83, %eax             // 2MB page | present | writable
    mov $(512 * 4), %ecx
1:  mov %eax, (%edi)
    add $0x200000, %eax
    add $8, %edi
    dec %ecx
    jnz 1b

    // Load PML4 into CR3
    mov $0x1000, %eax
    mov %eax, %cr3

    // Enable PAE (CR4.PAE = bit 5)
    mov %cr4, %eax
    or $0x20, %eax
    mov %eax, %cr4

    // Enable long mode (EFER.LME = bit 8)
    mov $0xc0000080, %ecx
    rdmsr
    or $0x100, %eax
    wrmsr

    // Enable paging (CR0.PG = bit 31)
    mov %cr0, %eax
    or $0x80000000, %eax
    mov %eax, %cr0

    // Load 64-bit GDT
    lgdt pvh_gdt64_ptr

    // Far jump to 64-bit code segment, landing at _start
    ljmp $0x08, $_start

// Common 64-bit entry point for all boot paths.
// - PVH: pvh_start transitions from 32-bit and jumps here
// - Multiboot: multiboot_entry transitions from 32-bit and jumps here
// - Firecracker ELF: directly enters here in 64-bit long mode
//
// This function is self-contained: sets up segments, SSE, stack,
// then calls kernelMain. Safe to enter from any 64-bit context.
.code64
.globl _start
.type _start, @function
_start:
    // Set up data segment registers (safe even if already set)
    mov $0x10, %ax
    mov %ax, %ds
    mov %ax, %es
    mov %ax, %ss
    xor %ax, %ax
    mov %ax, %fs
    mov %ax, %gs

    // Enable SSE (required for Zig code generation on x86_64)
    // Clear CR0.EM (bit 2), Set CR0.MP (bit 1)
    mov %cr0, %rax
    and $0xFFFFFFFFFFFFFFFB, %rax  // Clear EM (bit 2)
    or $0x2, %rax                   // Set MP (bit 1)
    mov %rax, %cr0

    // Set CR4.OSFXSR (bit 9) and CR4.OSXMMEXCPT (bit 10)
    mov %cr4, %rax
    or $0x600, %rax                 // Set OSFXSR and OSXMMEXCPT
    mov %rax, %cr4

    // Set up stack
    lea boot_stack_top(%rip), %rsp

    // Clear direction flag
    cld

    // Clear frame pointer for stack traces
    xor %rbp, %rbp

    // Call Zig kernel entry
    call kernelMain
    // kernelMain is noreturn, but halt if it somehow does
2:  hlt
    jmp 2b

.align 16
pvh_gdt64:
    .quad 0                     // Null descriptor
    .quad 0x00af9a000000ffff    // 64-bit code segment
    .quad 0x00cf92000000ffff    // 64-bit data segment
pvh_gdt64_end:

pvh_gdt64_ptr:
    .short pvh_gdt64_end - pvh_gdt64 - 1
    .long pvh_gdt64

.section .bss
.align 16
.globl boot_stack
boot_stack:
    .space 16384                // 16KB stack
.globl boot_stack_top
boot_stack_top:
