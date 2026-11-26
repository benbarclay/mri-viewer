#!/usr/bin/env bash
# Re-vendor OpenJPEG's openjp2 library into Sources/COpenJPEG.
# Usage: scripts/vendor_openjpeg.sh [version]   (default 2.5.3)
set -euo pipefail
VER="${1:-2.5.3}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Sources/COpenJPEG"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

curl -sSL -o "$WORK/ojp.tar.gz" "https://github.com/uclouvain/openjpeg/archive/refs/tags/v$VER.tar.gz"
shasum -a 256 "$WORK/ojp.tar.gz"
tar xzf "$WORK/ojp.tar.gz" -C "$WORK"
SRC="$WORK/openjpeg-$VER/src/lib/openjp2"

# Keep hand-written config headers, module map and notes; replace library sources.
find "$DEST" -maxdepth 1 -type f \( -name '*.c' -o -name '*.h' \) ! -name 'opj_config_private.h' -delete
for f in "$SRC"/*.c "$SRC"/*.h; do
  case "$(basename "$f")" in
    bench_dwt.c|test_sparse_array.c|t1_generate_luts.c|t1_ht_generate_luts.c|*_manager.[ch]) ;; # programs + JPIP-only indexers
    openjpeg.h) cp "$f" "$DEST/include/openjpeg.h" ;;
    *) cp "$f" "$DEST/" ;;
  esac
done
cp "$WORK/openjpeg-$VER/LICENSE" "$DEST/LICENSE"
echo "vendored OpenJPEG $VER — update version numbers in include/opj_config.h, opj_config_private.h and VENDORED.md"
