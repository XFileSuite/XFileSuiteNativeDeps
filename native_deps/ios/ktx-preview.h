#pragma once
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
void *xfs_ktx_open(const char *path, int32_t *status);
void xfs_ktx_close(void *texture);
uint32_t xfs_ktx_levels(void *texture);
uint32_t xfs_ktx_width(void *texture, uint32_t level);
uint32_t xfs_ktx_height(void *texture, uint32_t level);
int32_t xfs_ktx_read_rgba(void *texture, uint32_t level, uint8_t *output, uint64_t size);
#ifdef __cplusplus
}
#endif
