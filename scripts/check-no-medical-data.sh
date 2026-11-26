#!/usr/bin/env bash
# Fails if anything tracked (or staged) by git looks like medical image data or a generated model.
# Run before every push; install as a pre-commit hook with:
#   ln -sf ../../scripts/check-no-medical-data.sh .git/hooks/pre-commit
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
bad=0
while IFS= read -r -d '' f; do
  [ -f "$f" ] || continue
  # DICOM Part 10 files carry "DICM" at byte offset 128.
  if [ "$(dd if="$f" bs=1 skip=128 count=4 2>/dev/null)" = "DICM" ]; then
    echo "DICOM file tracked: $f"; bad=1
  fi
  case "$f" in
    *.dcm|*.DCM|*DICOMDIR*|*.nii|*.nii.gz|*.mgz|*.nrrd|*.stl|*.STL|*.obj|*.3mf|*.ply)
      echo "medical/model data file tracked: $f"; bad=1 ;;
  esac
done < <(git ls-files -z --cached)
if [ "$bad" -ne 0 ]; then
  echo "Refusing: remove these files from git before committing/pushing."
  exit 1
fi
echo "ok: no DICOM, volume or mesh files tracked"
