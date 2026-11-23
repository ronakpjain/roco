#!/bin/bash
# One-time Diamond image build on Hercules.
# Expects: ~/roco-diamond/installer/diamond-*.tgz (manual download, see README)
#          ~/roco-diamond/license/license.dat   (manual license request, see README)
set -euo pipefail

WORK="$HOME/roco-diamond"
SRC="$WORK/soc/diamond"
CTX="$WORK/docker-build"

: "${DIAMOND_VERSION:=3.14}"

installer=( "$WORK"/installer/diamond-*.tgz )
if [ ! -e "${installer[0]}" ]; then
  echo "missing installer tarball in $WORK/installer/ (see soc/diamond/README.md step 1)" >&2
  exit 2
fi
if [ ! -f "$WORK/license/license.dat" ]; then
  echo "warning: no $WORK/license/license.dat yet (see README step 2); image builds without it, runs will fail until it exists" >&2
fi

mkdir -p "$CTX/installer" "$WORK/out"
cp "$SRC/Dockerfile" "$CTX/Dockerfile"
cp "${installer[0]}" "$CTX/installer/"
base="$(basename "${installer[0]}")"

docker build -t roco-diamond \
  --build-arg "DIAMOND_VERSION=$DIAMOND_VERSION" \
  --build-arg "INSTALLER_TGZ=$base" \
  "$CTX"
docker image ls roco-diamond
