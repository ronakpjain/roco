#!/bin/sh
# Assemble, link, and run the roco end-to-end smoke test on the core testbench.
set -eu

build_dir=$1
source_dir=$2
roco_as=$3
roco_ld=$4
vvp=$5
testbench=$6

out="$build_dir/e2e"
mkdir -p "$out"

"$roco_as" -o "$out/start.o" "$source_dir/tests/e2e/start.S"
"$roco_as" -o "$out/main.o" "$source_dir/tests/e2e/main.S"
"$roco_ld" -o "$out/program.elf" --binary "$out/program.bin" \
  --hex "$out/program.hex" -Map "$out/program.map" \
  "$out/start.o" "$out/main.o"

"$vvp" "$testbench" +hex="$out/program.hex" | tee "$out/run.log"
grep -q "tb_core: PASS" "$out/run.log"
