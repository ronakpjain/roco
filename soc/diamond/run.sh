#!/bin/bash
# One Diamond batch run on Hercules. Sources are synced by `make
# diamond-bitstream` before this is invoked over SSH; artifacts land in
# ~/roco-diamond/out/ for the Makefile to fetch back.
set -euo pipefail

WORK="$HOME/roco-diamond"
IMAGE="${DIAMOND_IMAGE:-roco-diamond}"
# Pinned container MAC: the node-locked license is issued against
# 024449414D44 (see README step 2). Every run must use this MAC.
MAC="${DIAMOND_MAC:-02:44:49:41:4D:44}"

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "missing docker image $IMAGE (run soc/diamond/build.sh first)" >&2
  exit 2
fi
if [ ! -f "$WORK/license/license.dat" ]; then
  echo "missing $WORK/license/license.dat (see soc/diamond/README.md step 2)" >&2
  exit 2
fi

mkdir -p "$WORK/out"
docker run --rm \
  --mac-address="$MAC" \
  -v "$WORK/soc:/work/soc:ro" \
  -v "$WORK/out:/work/out" \
  -v "$WORK/license:/lic:ro" \
  "$IMAGE" /work/soc/diamond/roco.tcl
chown -R "$(id -u):$(id -g)" "$WORK/out"
ls -lh "$WORK/out"
