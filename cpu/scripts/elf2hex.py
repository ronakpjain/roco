#!/usr/bin/env python3
"""Convert a flat binary image into a $readmemh word listing."""

import argparse
import pathlib


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=pathlib.Path)
    parser.add_argument("output", type=pathlib.Path)
    parser.add_argument(
        "--big-endian",
        action="store_true",
        help="emit each 32-bit word MSB first (default is little-endian)",
    )
    args = parser.parse_args()

    data = args.binary.read_bytes()
    data += b"\x00" * (-len(data) % 4)
    words = [
        int.from_bytes(data[i:i + 4], "big" if args.big_endian else "little")
        for i in range(0, len(data), 4)
    ]
    args.output.write_text("\n".join(f"{word:08x}" for word in words) + "\n")
    print(f"{args.output}: {len(words)} words")


if __name__ == "__main__":
    main()
