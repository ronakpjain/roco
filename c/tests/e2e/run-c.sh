#!/bin/sh
# Compile C, assemble, link, and run the roco C smoke test on the core testbench.
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

"$roco_cc" -S -o "$out/main.s" "$source_dir/tests/e2e/main.c"
"$roco_as" -o "$out/main.o" "$out/main.s"
"$roco_as" -o "$out/start.o" "$source_dir/tests/e2e/start-c.S"
"$roco_ld" -o "$out/program.elf" --binary "$out/program.bin" \
  --hex "$out/program.hex" -Map "$out/program.map" \
  "$out/start.o" "$out/main.o"

"$vvp" "$testbench" +hex="$out/program.hex" +max_cycles=500000 \
  | tee "$out/run.log"
grep -q "tb_core: PASS" "$out/run.log"
