#!/usr/bin/env bash
# Segment a DICOM T1 with FastSurfer (brain regions for `mritool kit` / the app's Print Kit).
#
# Usage: scripts/fastsurfer-segment.sh <dicom-dir> <out-dir> [--series N]
# Output: <out-dir>/labels.mgz  (aparc.DKTatlas+aseg, FreeSurfer numbering)
#
# Needs FastSurfer for macOS (https://deep-mi.org/FastSurfer/dev/overview/install/MACOS.html).
# Found via $FASTSURFER_HOME, else ~/Applications/FastSurfer*, else /Applications/FastSurfer*.
# Everything runs locally; segmentation only (no FreeSurfer license needed).
set -euo pipefail
[ $# -ge 2 ] || { sed -n '2,10p' "$0"; exit 2; }
DICOM="$1"; OUT="$2"; shift 2
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [ -z "${FASTSURFER_HOME:-}" ]; then
  for d in "$HOME"/Applications/FastSurfer* /Applications/FastSurfer*; do
    [ -f "$d/run_fastsurfer.sh" ] && FASTSURFER_HOME="$d"
  done
fi
[ -n "${FASTSURFER_HOME:-}" ] && [ -f "$FASTSURFER_HOME/run_fastsurfer.sh" ] || { echo "FastSurfer not found (set FASTSURFER_HOME)"; exit 1; }

BIN="$(cd "$ROOT" && swift build -c release --product mritool >/dev/null && swift build -c release --show-bin-path)"
mkdir -p "$OUT"
"$BIN/mritool" nifti "$DICOM" "$OUT/t1.nii" "$@"

# shellcheck disable=SC1091
source "$FASTSURFER_HOME/macos_setup_fastsurfer.sh" >/dev/null
run_fastsurfer.sh --seg_only --no_cereb --no_hypothal --no_cc \
  --t1 "$OUT/t1.nii" --sd "$OUT" --sid fastsurfer > "$OUT/fastsurfer.log" 2>&1 \
  || { echo "FastSurfer failed — see $OUT/fastsurfer.log"; exit 1; }
cp "$OUT/fastsurfer/mri/aparc.DKTatlas+aseg.deep.mgz" "$OUT/labels.mgz"
echo "labels: $OUT/labels.mgz"
