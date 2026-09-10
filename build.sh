#!/bin/sh
# Builds and runs the unit tests without dub, for a quick loop while editing.
#   sh build.sh                 -- compile every module and run its unittests
DMD="${DMD:-dmd}"
OUT="${OUT:-.build}"
mkdir -p "$OUT"
"$DMD" -unittest -main -I=source -od="$OUT" -of="$OUT/unittests.exe" \
    source/frostlake/*.d "$@" || exit 1
exec "$OUT/unittests.exe"
