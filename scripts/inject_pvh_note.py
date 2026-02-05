#!/usr/bin/env python3
"""Inject a PVH PT_NOTE program header into an ELF binary.

LLD (used by Zig) strips the .note.PVH section during --gc-sections.
This script patches the final ELF to add a PT_NOTE program header
pointing to a PVH note appended at the end of the file.

The note contains XEN_ELFNOTE_PHYS32_ENTRY (type 18) with the physical
address of pvh_start, which Firecracker's linux-loader uses to discover
the PVH entry point.

Usage: inject_pvh_note.py <elf-file> <pvh_start-address-hex>
"""

import struct
import sys

# ELF constants
PT_NOTE = 4
PF_R = 4

# PVH note constants
XEN_ELFNOTE_PHYS32_ENTRY = 18


def read_elf_header(data):
    """Parse the ELF64 header."""
    magic = data[:4]
    if magic != b'\x7fELF':
        raise ValueError("Not an ELF file")
    ei_class = data[4]
    if ei_class != 2:
        raise ValueError("Not a 64-bit ELF")

    # ELF64 header fields
    (e_type, e_machine, e_version, e_entry, e_phoff, e_shoff,
     e_flags, e_ehsize, e_phentsize, e_phnum, e_shentsize, e_shnum,
     e_shstrndx) = struct.unpack_from('<HHIQQQIHHHHHH', data, 16)

    return {
        'e_phoff': e_phoff,
        'e_shoff': e_shoff,
        'e_phentsize': e_phentsize,
        'e_phnum': e_phnum,
        'e_shentsize': e_shentsize,
        'e_shnum': e_shnum,
    }


def build_pvh_note(pvh_start_addr):
    """Build the PVH ELF note (name="PVH", type=18, desc=pvh_start addr)."""
    name = b'PVH\x00'
    desc = struct.pack('<I', pvh_start_addr)
    # Note header: namesz, descsz, type
    header = struct.pack('<III', len(name), len(desc), XEN_ELFNOTE_PHYS32_ENTRY)
    return header + name + desc


def inject_note(elf_path, pvh_start_addr):
    with open(elf_path, 'rb') as f:
        data = bytearray(f.read())

    hdr = read_elf_header(data)
    phoff = hdr['e_phoff']
    phentsize = hdr['e_phentsize']
    phnum = hdr['e_phnum']

    # Build the note data
    note_data = build_pvh_note(pvh_start_addr)

    # Append note data at end of file (aligned to 4 bytes)
    file_size = len(data)
    note_offset = (file_size + 3) & ~3  # 4-byte align
    data.extend(b'\x00' * (note_offset - file_size))  # padding
    data.extend(note_data)

    # Build PT_NOTE program header (Elf64_Phdr = 56 bytes)
    # p_type, p_flags, p_offset, p_vaddr, p_paddr, p_filesz, p_memsz, p_align
    ph_note = struct.pack('<IIQQQQQQ',
        PT_NOTE,          # p_type
        PF_R,             # p_flags
        note_offset,      # p_offset
        0,                # p_vaddr (not loaded)
        0,                # p_paddr
        len(note_data),   # p_filesz
        len(note_data),   # p_memsz
        4,                # p_align
    )

    # We need to add a new program header. Strategy: append it after existing ones.
    # But program headers must be contiguous. Check if there's space after the last phdr.
    phtable_end = phoff + phnum * phentsize

    # Check if there's padding after the program header table
    # (before the first section/segment data)
    # Find the earliest data offset after phtable_end
    min_data_offset = len(data)
    for i in range(phnum):
        off = phoff + i * phentsize
        p_offset = struct.unpack_from('<Q', data, off + 8)[0]
        if p_offset > phtable_end and p_offset < min_data_offset:
            min_data_offset = p_offset

    space_available = min_data_offset - phtable_end
    if space_available >= phentsize:
        # There's room to append the phdr after existing ones
        new_ph_offset = phtable_end
        data[new_ph_offset:new_ph_offset + phentsize] = ph_note[:phentsize]
    else:
        # No room - need to relocate program headers (complex)
        # For now, try inserting at phtable_end by shifting data
        print(f"Warning: no space for extra phdr (need {phentsize}, have {space_available})")
        print("Trying to overwrite padding...")
        # Check if the space is all zeros (padding)
        if all(b == 0 for b in data[phtable_end:phtable_end + phentsize]):
            new_ph_offset = phtable_end
            data[new_ph_offset:new_ph_offset + phentsize] = ph_note[:phentsize]
        else:
            print("ERROR: Cannot inject PT_NOTE - no space in program header table")
            sys.exit(1)

    # Update e_phnum in ELF header (offset 56 for ELF64)
    new_phnum = phnum + 1
    struct.pack_into('<H', data, 56, new_phnum)

    with open(elf_path, 'wb') as f:
        f.write(data)

    print(f"Injected PT_NOTE: pvh_start=0x{pvh_start_addr:x}, "
          f"note at file offset 0x{note_offset:x}")


def find_symbol(elf_path, symbol_name):
    """Find a symbol's address using objdump."""
    import subprocess
    result = subprocess.run(
        ['objdump', '-t', elf_path],
        capture_output=True, text=True
    )
    for line in result.stdout.splitlines():
        parts = line.split()
        if len(parts) >= 2 and symbol_name in parts:
            try:
                return int(parts[0], 16)
            except ValueError:
                continue
    return None


if __name__ == '__main__':
    if len(sys.argv) == 3:
        elf_file = sys.argv[1]
        pvh_addr = int(sys.argv[2], 16)
    elif len(sys.argv) == 2:
        elf_file = sys.argv[1]
        pvh_addr = find_symbol(elf_file, 'pvh_start')
        if pvh_addr is None:
            print("ERROR: Could not find pvh_start symbol")
            sys.exit(1)
        print(f"Found pvh_start at 0x{pvh_addr:x}")
    else:
        print(f"Usage: {sys.argv[0]} <elf-file> [pvh_start-hex-addr]")
        sys.exit(1)

    inject_note(elf_file, pvh_addr)
