// Multiboot2 header for QEMU direct boot
// Allows QEMU to load kernel and set up initial state

.set MULTIBOOT2_MAGIC,       0xe85250d6
.set MULTIBOOT2_ARCH_I386,   0
.set MULTIBOOT2_HEADER_LEN,  multiboot_header_end - multiboot_header_start

.section .multiboot, "a"
.align 8
multiboot_header_start:
    .long MULTIBOOT2_MAGIC
    .long MULTIBOOT2_ARCH_I386
    .long MULTIBOOT2_HEADER_LEN
    .long -(MULTIBOOT2_MAGIC + MULTIBOOT2_ARCH_I386 + MULTIBOOT2_HEADER_LEN)

    // Entry address tag
    .align 8
    .short 3                    // type: entry address
    .short 0                    // flags
    .long 12                    // size
    .long multiboot_entry       // entry_addr

    // End tag
    .align 8
    .short 0                    // type: end
    .short 0                    // flags
    .long 8                     // size
multiboot_header_end:

.section .text.multiboot_entry, "ax"
.code32
.globl multiboot_entry
multiboot_entry:
    // QEMU/GRUB enters here in 32-bit protected mode
    // We need to set up 64-bit long mode and jump to _start

    // Disable interrupts
    cli

    // Save multiboot info (ebx = multiboot info ptr)
    mov %ebx, %edi

    // Set up page tables for identity mapping first 4GB
    // PML4 at 0x1000, PDPT at 0x2000, PD at 0x3000

    // Clear page table area
    mov $0x1000, %edi
    xor %eax, %eax
    mov $0x3000, %ecx
    rep stosb

    // PML4[0] -> PDPT
    mov $0x1000, %edi
    mov $0x2003, %eax       // PDPT addr | present | writable
    mov %eax, (%edi)

    // PDPT[0] -> PD
    mov $0x2000, %edi
    mov $0x3003, %eax       // PD addr | present | writable
    mov %eax, (%edi)

    // PD entries: 512 x 2MB pages = 1GB identity map
    mov $0x3000, %edi
    mov $0x83, %eax         // 2MB page | present | writable
    mov $512, %ecx
1:  mov %eax, (%edi)
    add $0x200000, %eax     // Next 2MB page
    add $8, %edi
    dec %ecx
    jnz 1b

    // Load PML4 into CR3
    mov $0x1000, %eax
    mov %eax, %cr3

    // Enable PAE (CR4.PAE)
    mov %cr4, %eax
    or $0x20, %eax
    mov %eax, %cr4

    // Enable long mode (EFER.LME)
    mov $0xc0000080, %ecx
    rdmsr
    or $0x100, %eax
    wrmsr

    // Enable paging (CR0.PG)
    mov %cr0, %eax
    or $0x80000000, %eax
    mov %eax, %cr0

    // Load 64-bit GDT
    lgdt gdt64_ptr

    // Far jump to 64-bit code
    ljmp $0x08, $long_mode_entry

.code64
long_mode_entry:
    // Now in 64-bit long mode
    // Set up segment registers
    mov $0x10, %ax
    mov %ax, %ds
    mov %ax, %es
    mov %ax, %ss
    xor %ax, %ax
    mov %ax, %fs
    mov %ax, %gs

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

    // Set up stack (use boot_stack from pvh_boot.S)
    lea boot_stack_top(%rip), %rsp

    // Clear frame pointer
    xor %rbp, %rbp

    // Jump to kernel entry
    jmp _start

.align 16
gdt64:
    .quad 0                     // Null descriptor
    .quad 0x00af9a000000ffff    // 64-bit code segment
    .quad 0x00cf92000000ffff    // 64-bit data segment
gdt64_end:

gdt64_ptr:
    .short gdt64_end - gdt64 - 1
    .long gdt64
