#!/usr/bin/env python3
"""Build a roco_os root filesystem image from a manifest.

Manifest lines:

    include <another.manifest>
    dir /path
    txt /path <host-file>
    exe /path <host-elf>

``exe`` files are packed into the flat roco executable format used by the
loader: a four-word header followed by text and data words.
"""

import argparse
import struct
import sys
from pathlib import Path

BASE = 0x00400000
PAGE = 4096
TEXT_PAGES = 4
DATA_PAGES = 2
EXEC_MAGIC = 0x4F434F52
TYPE_FILE = 1
TYPE_DIR = 2
MAX_NAME = 24
MAX_PATH = 96


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


def pack_exec(path):
    entry, sections = read_elf(path)
    if entry != BASE or sections.get(".text", (0,))[0] != BASE:
        raise ValueError("entry and .text must start at 0x00400000")
    text, data = bytearray(), bytearray()
    for name, (addr, size, payload) in sections.items():
        if name in (".text", ".rodata"):
            target, page, capacity = text, BASE, TEXT_PAGES * PAGE
        elif name in (".data", ".bss"):
            target, page, capacity = data, BASE + TEXT_PAGES * PAGE, DATA_PAGES * PAGE
        else:
            raise ValueError(f"unsupported allocated section {name}")
        offset = addr - page
        if offset < 0 or offset + size > capacity:
            raise ValueError(f"{name} does not fit its {capacity // 1024} KiB region")
        if payload:
            target.extend(b"\0" * max(0, offset + len(payload) - len(target)))
            target[offset : offset + len(payload)] = payload
    text.extend(b"\0" * (-len(text) % 4))
    data.extend(b"\0" * (-len(data) % 4))
    header = struct.pack("<4I", EXEC_MAGIC, len(text) // 4, len(data) // 4, 1)
    return header + bytes(text) + bytes(data)


def parse_manifest(path, entries, seen_manifests):
    path = path.resolve()
    if path in seen_manifests:
        raise ValueError(f"recursive manifest include: {path}")
    seen_manifests.add(path)
    base = path.parent
    for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        parts = line.split(None, 2)
        kind = parts[0]
        if kind == "include":
            if len(parts) != 2:
                raise ValueError(f"{path}:{number}: include needs one path")
            parse_manifest(base / parts[1], entries, seen_manifests)
            continue
        if len(parts) < 2:
            raise ValueError(f"{path}:{number}: missing path")
        target = parts[1]
        if not target.startswith("/"):
            raise ValueError(f"{path}:{number}: filesystem paths must be absolute")
        if target != "/" and target.endswith("/"):
            raise ValueError(f"{path}:{number}: trailing slash")
        for component in target.strip("/").split("/"):
            if not component or len(component) >= MAX_NAME:
                raise ValueError(f"{path}:{number}: bad path component {component!r}")
        if len(target) >= MAX_PATH:
            raise ValueError(f"{path}:{number}: path is too long")
        if kind == "dir":
            if len(parts) != 2:
                raise ValueError(f"{path}:{number}: dir takes one path")
            payload = b""
        elif kind in ("txt", "exe"):
            if len(parts) != 3:
                raise ValueError(f"{path}:{number}: {kind} needs a host file")
            source = base / parts[2]
            payload = pack_exec(source) if kind == "exe" else source.read_bytes()
        else:
            raise ValueError(f"{path}:{number}: unknown manifest entry {kind!r}")
        entries.append((target, TYPE_DIR if kind == "dir" else TYPE_FILE, payload))


def normalize(entries):
    seen = {}
    for path, kind, payload in entries:
        if path == "/":
            raise ValueError("the root directory is implicit")
        if path in seen:
            raise ValueError(f"duplicate path {path}")
        seen[path] = kind
    for path, kind, payload in entries:
        parent = path.rsplit("/", 1)[0] or "/"
        if parent != "/" and seen.get(parent) != TYPE_DIR:
            raise ValueError(f"{path}: parent {parent} is not a declared directory")
    return sorted(entries, key=lambda entry: (entry[0].count("/"), entry[0]))


def emit(entries, output):
    names = bytearray()
    blobs = bytearray()
    rows = []
    for path, kind, payload in entries:
        name_offset = len(names)
        names += path.encode("utf-8") + b"\0"
        data_offset = len(blobs)
        blobs += payload
        blobs += b"\0" * (-len(blobs) % 4)
        rows.append((name_offset, kind, len(payload), data_offset))

    lines = [".section .rodata", ".balign 4"]
    lines += [".globl rootfs_count", "rootfs_count:", f"    .word {len(rows)}"]
    lines += [".globl rootfs_entries", "rootfs_entries:"]
    for row in rows:
        lines.append("    .word %d, %d, %d, %d" % row)
    lines += [".globl rootfs_names", "rootfs_names:"]
    for path, _, _ in entries:
        escaped = path.replace("\\", "\\\\").replace('"', '\\"')
        lines.append(f'    .asciz "{escaped}"')
    lines += [".balign 4", ".globl rootfs_data", "rootfs_data:"]
    if blobs:
        for offset in range(0, len(blobs), 4):
            value = struct.unpack_from("<I", blobs, offset)[0]
            lines.append(f"    .word 0x{value:08x}")
    else:
        lines.append("    .word 0")
    output.write_text("\n".join(lines) + "\n", encoding="ascii")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path)
    parser.add_argument("-o", "--output", type=Path, required=True)
    args = parser.parse_args()
    entries = []
    try:
        parse_manifest(args.manifest, entries, set())
        entries = normalize(entries)
        emit(entries, args.output)
    except (ValueError, OSError) as exc:
        sys.exit(f"{args.manifest}: {exc}")


if __name__ == "__main__":
    main()
