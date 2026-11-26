#!/usr/bin/env python3
"""Cross-check mritool's pixel decoder against pydicom + OpenJPEG.

Usage:
    mritool verify-decode <dicom-dir> <tmp-dir> [--series N]
    python verify_j2k.py <tmp-dir>

Prints aggregate agreement statistics only (no pixel values, no patient data).
Requires: pydicom, pylibjpeg, pylibjpeg-openjpeg, numpy.
"""
import sys
import pathlib
import numpy as np
import pydicom

out = pathlib.Path(sys.argv[1])
rows = [l.split("\t") for l in (out / "manifest.tsv").read_text().splitlines() if l]
exact = 0
max_abs = 0
ratios = []
ref_max = 0
ours_max = 0
meta = set()
for name, path in rows:
    ds = pydicom.dcmread(path)
    ref = ds.pixel_array.astype(np.int64).ravel()
    ours = np.fromfile(out / name, dtype="<u2").astype(np.int64)
    meta.add((int(ds.BitsAllocated), int(ds.BitsStored), int(ds.PixelRepresentation), str(ds.PhotometricInterpretation)))
    ref_max = max(ref_max, int(ref.max()))
    ours_max = max(ours_max, int(ours.max()))
    d = np.abs(ref - ours)
    max_abs = max(max_abs, int(d.max()))
    exact += int(d.max() == 0)
    if ref.max() > 0:
        ratios.append(ours.max() / ref.max())

print(f"slices compared: {len(rows)}")
print(f"bitsAllocated/bitsStored/pixelRep/photometric: {sorted(meta)}")
print(f"reference max stored value: {ref_max}; mritool max: {ours_max}")
print(f"bit-exact slices: {exact}/{len(rows)}; max |diff|: {max_abs}")
if ratios:
    print(f"max-value ratio ours/ref: min {min(ratios):.4f} max {max(ratios):.4f}")
sys.exit(0 if exact == len(rows) else 1)
