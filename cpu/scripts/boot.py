#!/usr/bin/env python3
"""Send a flat image to the roco UART bootloader.

Packet format:
  "ROCO" | base (LE32) | length (LE32) | crc32(payload) (LE32) | payload

The bootloader replies 'K' on success and 'E' on a framing/range/CRC
error. --emit-hex writes a byte-per-line hex file for the simulation
testbench instead of touching a serial port.
"""

import argparse
import pathlib
import struct
import subprocess
import sys
import tempfile
import time
import zlib

MAGIC = b"ROCO"
DEFAULT_BASE = 0x10000000


def load_payload(args: argparse.Namespace) -> bytes:
    if args.bin is not None:
        return args.bin.read_bytes()
    if args.elf is None:
        raise SystemExit("one of --elf or --bin is required")
    with tempfile.TemporaryDirectory() as tmp:
        flat = pathlib.Path(tmp) / "image.bin"
        subprocess.run(
            [f"{args.riscv_prefix}objcopy", "-O", "binary", str(args.elf), str(flat)],
            check=True,
        )
        return flat.read_bytes()


def build_packet(payload: bytes, base: int) -> bytes:
    if len(payload) == 0:
        raise SystemExit("refusing to boot an empty image")
    if len(payload) > 8 * 1024 * 1024:
        raise SystemExit("image is larger than the 8 MiB boot limit")
    return MAGIC + struct.pack("<III", base, len(payload), zlib.crc32(payload)) + payload


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--elf", type=pathlib.Path)
    parser.add_argument("--bin", type=pathlib.Path)
    parser.add_argument("--base", type=lambda value: int(value, 0), default=DEFAULT_BASE)
    parser.add_argument("--port", help="serial device, for example /dev/tty.usbserial-XXX")
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument("--emit-hex", type=pathlib.Path, help="byte-per-line hex for simulation")
    parser.add_argument("--riscv-prefix", default="riscv64-elf-")
    parser.add_argument("--timeout", type=float, default=10.0)
    args = parser.parse_args()

    packet = build_packet(load_payload(args), args.base)
    print(f"packet: {len(packet)} bytes, payload {len(packet) - 16}, base 0x{args.base:08x}")

    if args.emit_hex is not None:
        args.emit_hex.write_text("\n".join(f"{byte:02x}" for byte in packet) + "\n")
        print(f"wrote {args.emit_hex}")

    if args.port is None:
        return 0

    try:
        import serial  # imported lazily so --emit-hex works without pyserial
    except ImportError:
        print("pyserial is required for --port (python3 -m pip install pyserial)", file=sys.stderr)
        return 2

    with serial.Serial(args.port, args.baud, timeout=0.2) as link:
        # The SDRAM controller needs about 200 us after reset; the board
        # reset supervisor and loader need a little more. Give the loader
        # time to reach its magic search before sending the packet.
        time.sleep(0.35)
        link.write(packet)
        deadline = time.monotonic() + args.timeout
        while time.monotonic() < deadline:
            reply = link.read(1)
            if reply == b"K":
                print("bootloader: image accepted (K)")
                return 0
            if reply == b"E":
                print("bootloader: image rejected (E)", file=sys.stderr)
                return 1
        print("bootloader: no reply before timeout", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
