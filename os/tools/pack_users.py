#!/usr/bin/env python3
"""Pack fixed-layout roco_ld ELF files into a compact assembly object."""

import argparse
import struct
import sys
from pathlib import Path

BASE = 0x00400000
PAGE = 4096


def read_elf(path):
    data = path.read_bytes()
    if data[:7] != b"\x7fELF\x01\x01\x01":
        raise ValueError("expected ELF32 little-endian image")
    header = struct.unpack_from("<16sHHIIIIIHHHHHH", data)
    _, kind, machine, _, entry, _, shoff, _, _, _, _, shsize, shnum, names = header
    if kind != 2 or machine != 243 or shsize != 40:
        raise ValueError("expected a linked RV32 executable")
    sections = [struct.unpack_from("<10I", data, shoff + i * shsize) for i in range(shnum)]
    names_offset, names_size = sections[names][4:6]
    strings = data[names_offset : names_offset + names_size]
    alloc = {}
    for name_offset, typ, flags, addr, off, size, *_ in sections:
        if not flags & 2 or not size:
            continue
        name = strings[name_offset : strings.index(0, name_offset)].decode("ascii")
        payload = b"" if typ == 8 else data[off : off + size]
        if typ != 8 and len(payload) != size:
            raise ValueError(f"truncated {name}")
        alloc[name] = (addr, size, payload)
    return entry, alloc


def emit_app(label, path):
    entry, sections = read_elf(path)
    if entry != BASE or sections.get(".text", (0,))[0] != BASE:
        raise ValueError("entry and .text must start at 0x00400000")
    text, data = bytearray(), bytearray()
    for name, (addr, size, payload) in sections.items():
        if name in (".text", ".rodata"):
            target, page, capacity = text, BASE, 2 * PAGE
        elif name in (".data", ".bss"):
            target, page, capacity = data, BASE + 2 * PAGE, PAGE
        else:
            raise ValueError(f"unsupported allocated section {name}")
        offset = addr - page
        if offset < 0 or offset + size > capacity:
            raise ValueError(f"{name} does not fit its {capacity // 1024} KiB region")
        if payload:
            target.extend(b"\0" * max(0, offset + len(payload) - len(target)))
            target[offset : offset + len(payload)] = payload

    words = []
    for payload in (text, data):
        payload.extend(b"\0" * (-len(payload) % 4))
        words.append([value for (value,) in struct.iter_unpack("<I", payload)])
    lines = [f".globl {label}", f"{label}:", f"    .word {len(words[0])}, {len(words[1])}"]
    for value in words[0] + words[1]:
        lines.append(f"    .word 0x{value:08x}")
    return lines


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("primary", type=Path)
    parser.add_argument("worker", type=Path)
    parser.add_argument("countdown", type=Path, nargs="?")
    args = parser.parse_args()
    lines = [".section .rodata", ".balign 4"]
    for label, path in (("user_hello", args.primary), ("user_worker", args.worker),
                        ("user_countdown", args.countdown)):
        if path is None:
            lines += [f".globl {label}", f"{label}:", "    .word 0, 0"]
            continue
        try:
            lines += emit_app(label, path)
        except (ValueError, IndexError, struct.error) as exc:
            sys.exit(f"{path}: {exc}")
    args.output.write_text("\n".join(lines) + "\n", encoding="ascii")


if __name__ == "__main__":
    main()
