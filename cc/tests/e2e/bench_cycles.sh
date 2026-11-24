#!/bin/sh
# Report cycle counts for the C end-to-end programs at every optimization level.
# Cycle count, not retired instruction count, is the compiler's primary metric.
set -eu

build_dir=$1
source_dir=$2
roco_cc=$3
roco_as=$4
roco_ld=$5
vvp=$6
testbench=$7

out="$build_dir/bench-cycles"
mkdir -p "$out"
"$roco_as" -o "$out/start.o" "$source_dir/tests/e2e/start_c.S"

printf '%-10s %-4s %10s\n' workload level cycles
for optimization in -O0 -O1 -O2; do
  tag=$(printf '%s' "$optimization" | tr -cd 'A-Za-z0-9')
  for source in main features optimized; do
    "$roco_cc" "$optimization" -S -o "$out/$source.$tag.s" \
      "$source_dir/tests/e2e/$source.c"
    "$roco_as" -o "$out/$source.$tag.o" "$out/$source.$tag.s"
    "$roco_ld" -o "$out/$source.$tag.elf" --hex "$out/$source.$tag.hex" \
      "$out/start.o" "$out/$source.$tag.o"
    "$vvp" "$testbench" +hex="$out/$source.$tag.hex" \
      +max_cycles=1000000 +measure_execution > "$out/$source.$tag.log"
    if ! grep -q "tb_core: PASS" "$out/$source.$tag.log"; then
      cat "$out/$source.$tag.log"
      exit 1
    fi
    cycles=$(sed -n 's/.*EXECUTION cycles=\([0-9][0-9]*\).*/\1/p' \
      "$out/$source.$tag.log")
    printf '%-10s %-4s %10s\n' "$source" "$optimization" "$cycles"
  done
done
