Vendored from OpenJPEG v2.5.3 (https://github.com/uclouvain/openjpeg, tag v2.5.3,
tarball sha256 368fe0468228e767433c9ebdea82ad9d801a3ad1e4234421f352c8b06e7aa707),
directory src/lib/openjp2. License: BSD-2-Clause (see LICENSE).

Changes: removed programs with main() (bench_dwt.c, test_sparse_array.c,
t1_generate_luts.c, t1_ht_generate_luts.c) and the JPIP-only *_manager.[ch] indexers; opj_config.h / opj_config_private.h
hand-written for macOS instead of CMake-generated; openjpeg.h moved to include/.
Re-vendor with scripts/vendor_openjpeg.sh.
