#include "ktx-preview.h"
#include <ktx.h>
#include <stddef.h>

void *xfs_ktx_open(const char *path, int32_t *status) {
    ktxTexture *texture = NULL;
    *status = ktxTexture_CreateFromNamedFile(path, KTX_TEXTURE_CREATE_NO_FLAGS, &texture);
    if (*status != KTX_SUCCESS) return NULL;
    if (texture->numDimensions != 2 || texture->isArray || texture->isCubemap ||
        !texture->numLevels || texture->numLevels > 32 ||
        (uint64_t)texture->baseWidth * texture->baseHeight > 64 * 1024 * 1024) {
        *status = KTX_UNSUPPORTED_TEXTURE_TYPE;
    } else {
        // Reject oversized textures before allocating/decompressing their payload.
        *status = ktxTexture_LoadImageData(texture, NULL, 0);
    }
    if (*status == KTX_SUCCESS && ktxTexture_NeedsTranscoding(texture)) {
        *status = ktxTexture2_TranscodeBasis((ktxTexture2 *)texture, KTX_TTF_RGBA32, 0);
    }
    if (*status == KTX_SUCCESS && texture->classId == ktxTexture2_c) {
        uint32_t format = ((ktxTexture2 *)texture)->vkFormat;
        if (format >= 157 && format <= 184) *status = ktxTexture2_DecodeAstc((ktxTexture2 *)texture);
    }
    if (*status != KTX_SUCCESS) {
        ktxTexture_Destroy(texture);
        return NULL;
    }
    return texture;
}
void xfs_ktx_close(void *texture) { if (texture) ktxTexture_Destroy((ktxTexture *)texture); }
uint32_t xfs_ktx_levels(void *texture) { return ((ktxTexture *)texture)->numLevels; }
uint32_t xfs_ktx_width(void *texture, uint32_t level) {
    uint32_t value = ((ktxTexture *)texture)->baseWidth >> level;
    return value ? value : 1;
}
uint32_t xfs_ktx_height(void *texture, uint32_t level) {
    uint32_t value = ((ktxTexture *)texture)->baseHeight >> level;
    return value ? value : 1;
}
extern int32_t xfs_ktx_read_blocks(void *, uint32_t, uint8_t *);
int32_t xfs_ktx_read_rgba(void *handle, uint32_t level, uint8_t *output, uint64_t size) {
    ktxTexture *texture = handle;
    if (level >= texture->numLevels) return KTX_INVALID_VALUE;
    uint32_t width = xfs_ktx_width(handle, level), height = xfs_ktx_height(handle, level);
    if (size != (uint64_t)width * height * 4) return KTX_INVALID_VALUE;
    if (texture->isCompressed) return xfs_ktx_read_blocks(handle, level, output);
    uint32_t channels = 0;
    int bgra = 0;
    if (texture->classId == ktxTexture1_c) {
        ktxTexture1 *t = (ktxTexture1 *)texture;
        if (t->glType != 0x1401) return KTX_UNSUPPORTED_FEATURE;
        switch (t->glFormat) {
            case 0x1903: channels = 1; break;
            case 0x8227: channels = 2; break;
            case 0x1907: channels = 3; break;
            case 0x1908: channels = 4; break;
            case 0x80e1: channels = 4; bgra = 1; break;
            default: return KTX_UNSUPPORTED_FEATURE;
        }
    } else {
        switch (((ktxTexture2 *)texture)->vkFormat) {
            case 9: channels = 1; break;
            case 16: channels = 2; break;
            case 23: case 29: channels = 3; break;
            case 37: case 43: channels = 4; break;
            case 44: case 50: channels = 4; bgra = 1; break;
            default: return KTX_UNSUPPORTED_FEATURE;
        }
    }
    ktx_size_t offset;
    KTX_error_code status = ktxTexture_GetImageOffset(texture, level, 0, 0, &offset);
    if (status != KTX_SUCCESS) return status;
    uint64_t stride = (uint64_t)width * channels;
    if (texture->classId == ktxTexture1_c) stride = (stride + 3) & ~(uint64_t)3;
    if (offset > texture->dataSize || stride * height > texture->dataSize - offset) return KTX_FILE_DATA_ERROR;
    for (uint32_t y = 0; y < height; ++y) {
        uint32_t sourceY = texture->orientation.y == KTX_ORIENT_Y_UP ? height - 1 - y : y;
        const uint8_t *row = texture->pData + offset + sourceY * stride;
        for (uint32_t x = 0; x < width; ++x) {
            uint32_t sourceX = texture->orientation.x == KTX_ORIENT_X_LEFT ? width - 1 - x : x;
            const uint8_t *pixel = row + sourceX * channels;
            uint8_t *dest = output + ((uint64_t)y * width + x) * 4;
            dest[0] = pixel[bgra ? 2 : 0];
            dest[1] = channels >= 3 ? pixel[1] : pixel[0];
            dest[2] = channels >= 3 ? pixel[bgra ? 0 : 2] : pixel[0];
            dest[3] = channels == 4 ? pixel[3] : channels == 2 ? pixel[1] : 255;
        }
    }
    return KTX_SUCCESS;
}
