#!/bin/sh
# Compile C, assemble, link, and run the roco-cc smoke test on the core testbench.
set -eu

build_dir=$1
source_dir=$2
roco_cc=$3
roco_as=$4
roco_ld=$5
vvp=$6
testbench=$7

out="$build_dir/e2e-c"
mkdir -p "$out"

"$roco_as" -o "$out/start.o" "$source_dir/tests/e2e/start-c.S"

for source in main features; do
  "$roco_cc" -S -o "$out/$source.s" "$source_dir/tests/e2e/$source.c"
  "$roco_as" -o "$out/$source.o" "$out/$source.s"
  "$roco_ld" -o "$out/$source.elf" --binary "$out/$source.bin" \
    --hex "$out/$source.hex" -Map "$out/$source.map" \
    "$out/start.o" "$out/$source.o"
  "$vvp" "$testbench" +hex="$out/$source.hex" +max_cycles=1000000 \
    | tee "$out/$source.log"
  grep -q "tb_core: PASS" "$out/$source.log"
done
