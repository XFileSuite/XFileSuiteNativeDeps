#ifndef OXIPNG_H
#define OXIPNG_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#ifdef _WIN32
#ifdef OXIPNG_BUILD
#define OXIPNG_API __declspec(dllexport)
#else
#define OXIPNG_API __declspec(dllimport)
#endif
#else
#define OXIPNG_API __attribute__((visibility("default")))
#endif

enum {
  OXIPNG_ABI_VERSION_1 = 1,
};

/// Versioned options for path/memory optimize. New fields may only be appended;
/// callers set struct_size so older native libraries never read beyond the
/// memory supplied by the FFI client.
typedef struct OxipngOptionsV1 {
  uint32_t struct_size;
  uint32_t abi_version;
  /// Optimization preset 0..6 (values above 6 clamp to 6).
  int32_t level;
  /// Write output even when compression does not improve size.
  int32_t force;
  /// Strip safely-removable ancillary chunks (same as CLI `--strip safe`).
  int32_t strip_safe;
  /// Allow altering fully-transparent pixels to improve compression.
  int32_t optimize_alpha;
  /// Soft deadline in milliseconds; 0 disables the timeout.
  uint32_t timeout_ms;
} OxipngOptionsV1;

/// Upstream oxipng crate / CLI version string, e.g. "9.1.5".
OXIPNG_API const char *oxipng_version(void);

/// Thread-local last error message after a failed call; empty string on success.
OXIPNG_API const char *oxipng_last_error(void);

/// Optimize a PNG file to [output_path]. Returns 0 on success.
OXIPNG_API int32_t oxipng_optimize_file(
    const char *input_path,
    const char *output_path,
    const OxipngOptionsV1 *options);

/// Optimize PNG bytes in memory. Caller frees [out_bytes] with oxipng_blob_free.
OXIPNG_API int32_t oxipng_optimize_memory(
    const uint8_t *input,
    size_t input_len,
    const OxipngOptionsV1 *options,
    uint8_t **out_bytes,
    size_t *out_len);

/// Frees a buffer returned by oxipng_optimize_memory. Pass the matching out_len.
OXIPNG_API void oxipng_blob_free(uint8_t *bytes, size_t len);

#ifdef __cplusplus
}
#endif

#endif
