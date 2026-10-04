#pragma once
#include <stddef.h>

/// Decompress one complete zstd frame. Returns the decompressed size, or -1 on any error
/// (corrupt input, or more than dst_capacity bytes of output).
long czstd_decompress(void *dst, size_t dst_capacity, const void *src, size_t src_size);
