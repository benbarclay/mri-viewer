/* Hand-written replacement for opj_config_private.h.cmake.in (OpenJPEG 2.5.3), macOS. */
#define OPJ_PACKAGE_VERSION "2.5.3"
#define OPJ_HAVE_FSEEKO ON
#define OPJ_HAVE_POSIX_MEMALIGN 1
#if !defined(_POSIX_C_SOURCE)
#define _POSIX_C_SOURCE 200112L
#endif
#if defined(__BIG_ENDIAN__)
#define OPJ_BIG_ENDIAN
#endif
