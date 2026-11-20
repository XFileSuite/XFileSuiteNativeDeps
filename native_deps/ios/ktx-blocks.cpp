#include "ktx-preview.h"
#include <ktx.h>
#include "basisu_gpu_texture.h"
#include "astcenc.h"
#include <cstring>
#include <cstdlib>
#include <mutex>
#include <new>
#include <memory>
#include <cmath>
#define BCDEC_IMPLEMENTATION
#define BCDEC_BC4BC5_PRECISE
#include "bcdec.h"

extern "C" KTX_error_code _ktxUnpackETC(const unsigned char *, unsigned int,
    uint32_t, uint32_t, unsigned char **, unsigned int *, unsigned int *, unsigned int *, int, unsigned char);

extern "C" int32_t xfs_ktx_read_blocks(void *handle, uint32_t level, uint8_t *output) {
    static std::mutex mutex;
    std::lock_guard<std::mutex> guard(mutex);
    auto *texture = static_cast<ktxTexture *>(handle);
    const uint32_t width = xfs_ktx_width(handle, level), height = xfs_ktx_height(handle, level);
    using basisu::texture_format;
    texture_format format = texture_format::cInvalidTextureFormat;
    uint32_t gl = 0, vk = 0;
    if (texture->classId == ktxTexture1_c) gl = reinterpret_cast<ktxTexture1 *>(texture)->glInternalformat;
    else vk = reinterpret_cast<ktxTexture2 *>(texture)->vkFormat;
    bool bc2 = false;
    unsigned signedChannels = 0;
    bool bc6 = false, signedBC6 = false;
    unsigned blockBytes = 16;
    switch (vk) {
        case 131: case 132: case 133: case 134: format = texture_format::cBC1; blockBytes = 8; break;
        case 135: case 136: bc2 = true; break;
        case 137: case 138: format = texture_format::cBC3; break;
        case 140: signedChannels = 1; blockBytes = 8; break;
        case 142: signedChannels = 2; break;
        case 143: bc6 = true; break;
        case 144: bc6 = true; signedBC6 = true; break;
        case 153: gl = 0x9270; break;
        case 154: gl = 0x9271; break;
        case 155: gl = 0x9272; break;
        case 156: gl = 0x9273; break;
        case 139: format = texture_format::cBC4; blockBytes = 8; break;
        case 141: format = texture_format::cBC5; break;
        case 145: case 146: format = texture_format::cBC7; break;
        case 147: gl = 0x9274; break;
        case 148: gl = 0x9275; break;
        case 149: gl = 0x9276; break;
        case 150: gl = 0x9277; break;
        case 151: gl = 0x9278; break;
        case 152: gl = 0x9279; break;
    }
    switch (gl) {
        case 0x83f0: case 0x83f1: case 0x8c4c: case 0x8c4d: format = texture_format::cBC1; blockBytes = 8; break;
        case 0x83f2: case 0x8c4e: bc2 = true; break;
        case 0x83f3: case 0x8c4f: format = texture_format::cBC3; break;
        case 0x8dbc: signedChannels = 1; blockBytes = 8; break;
        case 0x8dbe: signedChannels = 2; break;
        case 0x8e8e: bc6 = true; signedBC6 = true; break;
        case 0x8e8f: bc6 = true; break;
        case 0x8dbb: format = texture_format::cBC4; blockBytes = 8; break;
        case 0x8dbd: format = texture_format::cBC5; break;
        case 0x8e8c: case 0x8e8d: format = texture_format::cBC7; break;
        case 0x8c00: format = texture_format::cPVRTC1_4_RGB; blockBytes = 8; break;
        case 0x8c02: format = texture_format::cPVRTC1_4_RGBA; blockBytes = 8; break;
    }
    const bool astc = (gl >= 0x93b0 && gl <= 0x93bd) || (gl >= 0x93d0 && gl <= 0x93dd);
    static const unsigned astcSizes[14][2] = {
        {4,4}, {5,4}, {5,5}, {6,5}, {6,6}, {8,5}, {8,6},
        {8,8}, {10,5}, {10,6}, {10,8}, {10,10}, {12,10}, {12,12}
    };
    const unsigned astcIndex = astc ? gl - (gl >= 0x93d0 ? 0x93d0 : 0x93b0) : 0;
    const bool etc = gl == 0x8d64 || (gl >= 0x9270 && gl <= 0x9279);
    if (etc) blockBytes = (gl == 0x9272 || gl == 0x9273 || gl == 0x9278 || gl == 0x9279) ? 16 : 8;
    if (!etc && !bc2 && !bc6 && !signedChannels && !astc && format == texture_format::cInvalidTextureFormat) return KTX_UNSUPPORTED_FEATURE;
    ktx_size_t offset = 0;
    auto status = ktxTexture_GetImageOffset(texture, level, 0, 0, &offset);
    if (status != KTX_SUCCESS) return status;
    const bool pvrtc = format == texture_format::cPVRTC1_4_RGB || format == texture_format::cPVRTC1_4_RGBA;
    const uint32_t storageWidth = pvrtc && width < 8 ? 8 : width;
    const uint32_t storageHeight = pvrtc && height < 8 ? 8 : height;
    const unsigned blockWidth = astc ? astcSizes[astcIndex][0] : 4;
    const unsigned blockHeight = astc ? astcSizes[astcIndex][1] : 4;
    const uint64_t blocksX = (uint64_t(storageWidth) + blockWidth - 1) / blockWidth;
    const uint64_t blocksY = (uint64_t(storageHeight) + blockHeight - 1) / blockHeight;
    const uint64_t required = blocksX * blocksY * blockBytes;
    if (offset > texture->dataSize || required > texture->dataSize - offset) return KTX_FILE_DATA_ERROR;
    const auto *source = texture->pData + offset;
    try {
        basisu::image decoded;
        if (bc6 || signedChannels) {
            decoded.resize(width, height);
            for (unsigned by = 0; by < blocksY; by++) for (unsigned bx = 0; bx < blocksX; bx++) {
                const auto *block = source + (by * blocksX + bx) * blockBytes;
                float pixels[48] = {};
                if (bc6) bcdec_bc6h_float(block, pixels, 12, signedBC6);
                else if (signedChannels == 1) bcdec_bc4_float(block, pixels, 4, 1);
                else bcdec_bc5_float(block, pixels, 8, 1);
                for (unsigned y = 0; y < 4; y++) for (unsigned x = 0; x < 4; x++) {
                    if (bx * 4 + x >= width || by * 4 + y >= height) continue;
                    const unsigned components = bc6 ? 3 : signedChannels;
                    auto &color = decoded(bx * 4 + x, by * 4 + y);
                    color.set(0, 0, 0, 255);
                    for (unsigned c = 0; c < components; c++) {
                        float value = pixels[(y * 4 + x) * components + c];
                        if (!std::isfinite(value)) value = 0;
                        if (bc6) {
                            // A bounded Reinhard preview preserves HDR highlights in an 8-bit surface.
                            value = std::max(0.0f, value);
                            value /= 1.0f + value;
                            value = value <= 0.0031308f ? 12.92f * value : 1.055f * std::pow(value, 1.0f / 2.4f) - 0.055f;
                        } else value = value * 0.5f + 0.5f;
                        color[c] = uint8_t(std::round(std::min(1.0f, std::max(0.0f, value)) * 255));
                    }
                }
            }
        } else if (astc) {
            astcenc_config config;
            auto error = astcenc_config_init(gl >= 0x93d0 ? ASTCENC_PRF_LDR_SRGB : ASTCENC_PRF_LDR,
                blockWidth, blockHeight, 1, ASTCENC_PRE_FASTEST, ASTCENC_FLG_DECOMPRESS_ONLY, &config);
            if (error != ASTCENC_SUCCESS) return KTX_UNSUPPORTED_FEATURE;
            astcenc_context *context = nullptr;
            error = astcenc_context_alloc(&config, 1, &context);
            if (error != ASTCENC_SUCCESS) return KTX_OUT_OF_MEMORY;
            std::unique_ptr<astcenc_context, decltype(&astcenc_context_free)> ownedContext(context, &astcenc_context_free);
            decoded.resize(width, height);
            void *plane = decoded.get_ptr();
            astcenc_image image = {width, height, 1, ASTCENC_TYPE_U8, &plane};
            const astcenc_swizzle swizzle = {ASTCENC_SWZ_R, ASTCENC_SWZ_G, ASTCENC_SWZ_B, ASTCENC_SWZ_A};
            error = astcenc_decompress_image(context, source, required, &image, &swizzle, 0);
            if (error != ASTCENC_SUCCESS) return KTX_FILE_DATA_ERROR;
        } else if (etc) {
            unsigned char *pixels = nullptr;
            unsigned outFormat = 0, internal = 0, type = 0;
            status = _ktxUnpackETC(source, gl, width, height, &pixels, &outFormat, &internal, &type, 3, true);
            if (status != KTX_SUCCESS) return status;
            std::unique_ptr<unsigned char, decltype(&std::free)> ownedPixels(pixels, &std::free);
            const unsigned channels = outFormat == 0x1903 ? 1 : outFormat == 0x8227 ? 2 : outFormat == 0x1908 ? 4 : 3;
            decoded.resize(width, height);
            for (uint64_t i = 0; i < uint64_t(width) * height; i++) {
                auto &color = decoded(i % width, i / width);
                color.set(0, 0, 0, 255);
                for (unsigned c = 0; c < channels; c++) {
                    if (type == 0x1403) {
                        uint16_t value;
                        std::memcpy(&value, pixels + (i * channels + c) * 2, 2);
                        color[c] = uint8_t((uint32_t(value) * 255 + 32767) / 65535);
                    } else if (type == 0x1402) {
                        int16_t value;
                        std::memcpy(&value, pixels + (i * channels + c) * 2, 2);
                        color[c] = uint8_t((int32_t(value) + 32768) * 255 / 65535);
                    } else color[c] = pixels[i * channels + c];
                }
            }
        } else if (bc2) {
            decoded.resize(width, height);
            for (unsigned by = 0; by < blocksY; by++) for (unsigned bx = 0; bx < blocksX; bx++) {
                const auto *block = source + (by * blocksX + bx) * 16;
                basisu::color_rgba pixels[16];
                uint8_t colors[8];
                std::memcpy(colors, block + 8, sizeof(colors));
                const unsigned first = colors[0] | (unsigned(colors[1]) << 8);
                const unsigned second = colors[2] | (unsigned(colors[3]) << 8);
                if (first < second) {
                    std::swap(colors[0], colors[2]);
                    std::swap(colors[1], colors[3]);
                    for (unsigned i = 4; i < 8; i++) colors[i] ^= 0x55;
                }
                basisu::unpack_bc1(colors, pixels, false);
                if (first == second) {
                    const auto color = pixels[0];
                    const unsigned red = ((first >> 11) & 31) * 255 / 31;
                    const unsigned green = ((first >> 5) & 63) * 255 / 63;
                    const unsigned blue = (first & 31) * 255 / 31;
                    for (auto &pixel : pixels) pixel.set(red, green, blue, color.a);
                }
                for (unsigned y = 0; y < 4; y++) for (unsigned x = 0; x < 4; x++) {
                    unsigned index = y * 4 + x;
                    pixels[index].a = ((block[index / 2] >> ((index % 2) * 4)) & 15) * 17;
                    if (bx * 4 + x < width && by * 4 + y < height) decoded(bx * 4 + x, by * 4 + y) = pixels[index];
                }
            }
        } else {
            basisu::gpu_image image(format, storageWidth, storageHeight);
            if (image.get_size_in_bytes() != required) return KTX_UNSUPPORTED_FEATURE;
            std::memcpy(image.get_ptr(), source, required);
            if (!image.unpack(decoded)) return KTX_FILE_DATA_ERROR;
        }
        for (uint32_t y = 0; y < height; y++) for (uint32_t x = 0; x < width; x++) {
            uint32_t sx = texture->orientation.x == KTX_ORIENT_X_LEFT ? width - 1 - x : x;
            uint32_t sy = texture->orientation.y == KTX_ORIENT_Y_UP ? height - 1 - y : y;
            const auto &pixel = decoded(sx, sy);
            auto *destination = output + (uint64_t(y) * width + x) * 4;
            std::memcpy(destination, &pixel, 4);
            if (vk == 131 || vk == 132 || gl == 0x83f0 || gl == 0x8c4c) destination[3] = 255;
        }
        return KTX_SUCCESS;
    } catch (const std::bad_alloc &) { return KTX_OUT_OF_MEMORY; }
}
