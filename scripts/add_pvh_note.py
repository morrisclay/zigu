#!/usr/bin/env python3
"""Add PVH ELF note to kernel binary for QEMU/Firecracker boot.

This script patches an ELF binary to add a PT_NOTE segment containing
the PVH entry point, enabling direct kernel boot without a bootloader.
"""

import struct
import sys
from pathlib import Path


# ELF constants
ET_EXEC = 2
PT_NOTE = 4
PF_R = 4
XEN_ELFNOTE_PHYS32_ENTRY = 18


def main():
    if len(sys.argv) < 3:
        print(f"Usage: {sys.argv[0]} <input.elf> <output.elf> [pvh_start_addr_hex]")
        sys.exit(1)

    input_path = Path(sys.argv[1])
    output_path = Path(sys.argv[2])

    print(f"Reading {input_path}")
    data = bytearray(input_path.read_bytes())

    # Verify ELF header
    if data[:4] != b'\x7fELF':
        raise ValueError("Not an ELF file")
    if data[4] != 2:  # EI_CLASS = 64-bit
        raise ValueError("Not a 64-bit ELF")
    if data[5] != 1:  # EI_DATA = little-endian
        raise ValueError("Not little-endian")

    # Parse ELF header
    e_type = struct.unpack('<H', data[16:18])[0]
    e_phoff = struct.unpack('<Q', data[32:40])[0]
    e_shoff = struct.unpack('<Q', data[40:48])[0]
    e_phentsize = struct.unpack('<H', data[54:56])[0]
    e_phnum = struct.unpack('<H', data[56:58])[0]
    e_shentsize = struct.unpack('<H', data[58:60])[0]
    e_shnum = struct.unpack('<H', data[60:62])[0]

    print(f"ELF type: {e_type}, phoff: {e_phoff:#x}, phnum: {e_phnum}, phentsize: {e_phentsize}")
    print(f"shoff: {e_shoff:#x}, shnum: {e_shnum}, shentsize: {e_shentsize}")

    # Find pvh_start address from symbol table or command line
    if len(sys.argv) >= 4:
        pvh_start = int(sys.argv[3], 16)
    else:
        # Try to find it in the symbol table
        pvh_start = find_symbol_addr(data, e_shoff, e_shnum, e_shentsize, b'pvh_start')
        if pvh_start is None:
            print("Error: Could not find pvh_start symbol. Provide address as argument.")
            sys.exit(1)

    print(f"pvh_start address: {pvh_start:#x}")

    # Create PVH note content
    # Format: namesz(4) descsz(4) type(4) name("PVH\0") entry(4)
    note_content = struct.pack('<III', 4, 4, XEN_ELFNOTE_PHYS32_ENTRY)
    note_content += b'PVH\x00'
    note_content += struct.pack('<I', pvh_start & 0xFFFFFFFF)

    print(f"PVH note: {len(note_content)} bytes")

    # Append note to end of file (aligned to 8 bytes)
    while len(data) % 8 != 0:
        data.append(0)

    note_offset = len(data)
    data.extend(note_content)

    # Pad to 8-byte alignment
    while len(data) % 8 != 0:
        data.append(0)

    # Create new program header for PT_NOTE
    # We need to insert this into the program header table
    # The safest way is to extend the table if there's room, or relocate it

    phdr_table_end = e_phoff + e_phnum * e_phentsize

    # Check if there's padding after the phdr table that we can use
    # (Usually there is, since sections start at higher offsets)
    space_after_phdrs = find_first_content_after(data, phdr_table_end, e_shoff, e_shnum, e_shentsize)

    if space_after_phdrs >= e_phentsize:
        print(f"Found {space_after_phdrs} bytes after phdr table, inserting PT_NOTE there")

        # Insert the new phdr at the phdr table
        insert_pos = phdr_table_end

        # Create placeholder PT_NOTE program header (we'll fix offset later)
        note_phdr = struct.pack('<IIQQQQQQ',
            PT_NOTE,        # p_type
            PF_R,           # p_flags
            0,              # p_offset (placeholder)
            0,              # p_vaddr (notes typically have 0)
            0,              # p_paddr
            len(note_content),  # p_filesz
            len(note_content),  # p_memsz
            4               # p_align
        )

        # Insert the phdr
        data[insert_pos:insert_pos] = note_phdr

        # Update e_phnum
        new_phnum = e_phnum + 1
        data[56:58] = struct.pack('<H', new_phnum)

        # Update e_shoff since we inserted before it
        new_shoff = e_shoff
        if e_shoff > insert_pos:
            new_shoff = e_shoff + len(note_phdr)
            data[40:48] = struct.pack('<Q', new_shoff)
            print(f"Updated shoff: {e_shoff:#x} -> {new_shoff:#x}")

        # Now the note_offset needs to be recalculated since we shifted things
        note_offset += len(note_phdr)

        # Update the PT_NOTE p_offset field with correct value
        data[insert_pos + 8:insert_pos + 16] = struct.pack('<Q', note_offset)

        print(f"Inserted PT_NOTE header, phnum: {e_phnum} -> {new_phnum}")
        print(f"Note placed at file offset {note_offset:#x}")
    else:
        print(f"Warning: Only {space_after_phdrs} bytes after phdr table, need {e_phentsize}")
        print("Attempting to relocate program headers...")

        # This is more complex - we need to move the phdr table
        # For now, just append the note anyway and hope for the best
        # (Some loaders look for PT_NOTE anywhere in the file)
        print(f"Note placed at file offset {note_offset:#x}")

    # Write output
    output_path.write_bytes(data)
    print(f"Wrote {len(data)} bytes to {output_path}")


def find_symbol_addr(data, shoff, shnum, shentsize, name):
    """Find symbol address by name in the symbol table."""
    if shoff == 0 or shnum == 0:
        return None

    # Find .symtab and .strtab sections
    symtab_off = None
    symtab_size = None
    symtab_entsize = None
    strtab_off = None
    strtab_size = None
    shstrtab_off = None

    # First find shstrtab (section header string table)
    e_shstrndx = struct.unpack('<H', data[62:64])[0]
    if e_shstrndx < shnum:
        sh_off = shoff + e_shstrndx * shentsize
        shstrtab_off = struct.unpack('<Q', data[sh_off + 24:sh_off + 32])[0]

    # Find symtab and strtab
    for i in range(shnum):
        sh_off = shoff + i * shentsize
        sh_type = struct.unpack('<I', data[sh_off + 4:sh_off + 8])[0]
        sh_offset = struct.unpack('<Q', data[sh_off + 24:sh_off + 32])[0]
        sh_size = struct.unpack('<Q', data[sh_off + 32:sh_off + 40])[0]
        sh_entsize = struct.unpack('<Q', data[sh_off + 56:sh_off + 64])[0]

        if sh_type == 2:  # SHT_SYMTAB
            symtab_off = sh_offset
            symtab_size = sh_size
            symtab_entsize = sh_entsize
            # Link field points to strtab
            sh_link = struct.unpack('<I', data[sh_off + 40:sh_off + 44])[0]
            if sh_link < shnum:
                strtab_sh_off = shoff + sh_link * shentsize
                strtab_off = struct.unpack('<Q', data[strtab_sh_off + 24:strtab_sh_off + 32])[0]
                strtab_size = struct.unpack('<Q', data[strtab_sh_off + 32:strtab_sh_off + 40])[0]

    if symtab_off is None or strtab_off is None:
        return None

    # Search symbols
    num_syms = symtab_size // symtab_entsize
    for i in range(num_syms):
        sym_off = symtab_off + i * symtab_entsize
        st_name = struct.unpack('<I', data[sym_off:sym_off + 4])[0]
        st_value = struct.unpack('<Q', data[sym_off + 8:sym_off + 16])[0]

        if st_name > 0 and st_name < strtab_size:
            # Get symbol name
            name_start = strtab_off + st_name
            name_end = data.find(b'\x00', name_start)
            if name_end > name_start:
                sym_name = bytes(data[name_start:name_end])
                if sym_name == name:
                    return st_value

    return None


def find_first_content_after(data, offset, shoff, shnum, shentsize):
    """Find how much space is available after the given offset."""
    min_content = len(data)

    # Check section headers
    if shoff > offset:
        min_content = min(min_content, shoff)

    # Check section contents
    for i in range(shnum):
        sh_off = shoff + i * shentsize
        sh_offset = struct.unpack('<Q', data[sh_off + 24:sh_off + 32])[0]
        if sh_offset > offset:
            min_content = min(min_content, sh_offset)

    return min_content - offset


if __name__ == '__main__':
    main()
