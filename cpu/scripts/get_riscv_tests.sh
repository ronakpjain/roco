#!/usr/bin/env bash
# Fetch the official riscv-tests ISA suite at a pinned revision.
#
# The tests are not vendored: they are cloned into third_party/, which is
# gitignored. The runner only needs isa/rv32ui and isa/rv64ui.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dest="${RISCV_TESTS:-$root/third_party/riscv-tests}"
commit="3df703cd52d5f0d8224e3c50bf03c6cb70efff98"

if [ -f "$dest/isa/rv32ui/add.S" ]; then
  echo "riscv-tests already present at $dest"
  exit 0
fi

mkdir -p "$(dirname "$dest")"
git clone --depth 1 https://github.com/riscv-software-src/riscv-tests.git "$dest"
git -C "$dest" fetch --depth 1 origin "$commit"
git -C "$dest" checkout --detach "$commit"
echo "riscv-tests pinned to $commit at $dest"
