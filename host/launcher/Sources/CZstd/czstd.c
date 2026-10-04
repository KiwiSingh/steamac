// zstd frame decoder for the launcher's squashfs reader (Squashfs.swift). Single translation
// unit built from the pinned zstd release sources (fetch-zstd.sh -> ./zstd, excluded from the
// target so they are compiled only through these includes), following zstd's own
// build/single_file_libs/zstddeclib-in.c.
#define DEBUGLEVEL 0
#define MEM_MODULE
#undef  XXH_NAMESPACE
#define XXH_NAMESPACE ZSTD_
#undef  XXH_PRIVATE_API
#define XXH_PRIVATE_API
#undef  XXH_INLINE_ALL
#define XXH_INLINE_ALL
#define ZSTD_LEGACY_SUPPORT 0
#define ZSTD_STRIP_ERROR_STRINGS
#define ZSTD_TRACE 0
#define ZSTD_DISABLE_ASM 1
#define ZSTD_DEPS_NEED_MALLOC
#include "zstd/common/zstd_deps.h"
#include "zstd/common/debug.c"
#include "zstd/common/entropy_common.c"
#include "zstd/common/error_private.c"
#include "zstd/common/fse_decompress.c"
#include "zstd/common/zstd_common.c"
#include "zstd/decompress/huf_decompress.c"
#include "zstd/decompress/zstd_ddict.c"
#include "zstd/decompress/zstd_decompress.c"
#include "zstd/decompress/zstd_decompress_block.c"

#include "czstd.h"

long czstd_decompress(void *dst, size_t dst_capacity, const void *src, size_t src_size) {
    size_t n = ZSTD_decompress(dst, dst_capacity, src, src_size);
    return ZSTD_isError(n) ? -1 : (long)n;
}
