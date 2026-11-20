/* Independent consumer: compile/link now, execute in an iOS host later. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <string.h>
#include <MagickWand/MagickWand.h>
#include <libraw/libraw.h>
#include <libavcodec/avcodec.h>
#include <ffmpeg-cli.h>
#include <libavformat/avformat.h>
#include <libavfilter/avfilter.h>
#include <mpv/client.h>
#include "oxipng.h"
#include "resvg.h"

#define CHECK(value) do { if (!(value)) { fprintf(stderr, "Failed: %s\n", #value); return 1; } } while (0)

int main(void) {
    MagickWandGenesis();
    MagickWand *wand = NewMagickWand();
    PixelWand *pixel = NewPixelWand();
    CHECK(PixelSetColor(pixel, "red"));
    CHECK(MagickNewImage(wand, 2, 2, pixel));
    CHECK(MagickSetImageFormat(wand, "PNG"));
    size_t png_len = 0;
    unsigned char *png = MagickGetImageBlob(wand, &png_len);
    CHECK(png && png_len > 8);
    OxipngOptionsV1 options = {sizeof(options), OXIPNG_ABI_VERSION_1, 1, 1, 1, 0, 1000};
    uint8_t *optimized = NULL;
    size_t optimized_len = 0;
    CHECK(oxipng_optimize_memory(png, png_len, &options, &optimized, &optimized_len) == 0);
    CHECK(optimized && optimized_len > 8);
    char input[] = "/tmp/xfs-cli-smoke.XXXXXX";
    int descriptor = mkstemp(input);
    CHECK(descriptor >= 0);
    ssize_t written = write(descriptor, png, png_len);
    close(descriptor);
    char *invalid[] = {"ffmpeg", "-xfs_invalid_option", NULL};
    char *convert[] = {"ffmpeg", "-f", "png_pipe", "-i", input, "-f", "null", "-", NULL};
    int failed = xfs_ffmpeg_run(2, invalid, NULL, NULL, NULL);
    int first = xfs_ffmpeg_run(8, convert, NULL, NULL, NULL);
    int second = xfs_ffmpeg_run(8, convert, NULL, NULL, NULL);
    unlink(input);
    CHECK(written == (ssize_t)png_len && failed < 0 && first == 0 && second == 0);
    oxipng_blob_free(optimized, optimized_len);
    MagickRelinquishMemory(png);
    DestroyPixelWand(pixel);
    DestroyMagickWand(wand);
    MagickWandTerminus();

    libraw_data_t *raw = libraw_init(0);
    CHECK(raw && libraw_versionNumber() != 0);
    CHECK(libraw_capabilities() & LIBRAW_CAPS_X3FTOOLS);
    libraw_close(raw);

    const char *svg = "<svg xmlns='http://www.w3.org/2000/svg' width='2' height='2'><rect width='2' height='2' fill='red'/></svg>";
    resvg_options *opt = resvg_options_create();
    resvg_render_tree *tree = NULL;
    CHECK(resvg_parse_tree_from_data(svg, strlen(svg), opt, &tree) == 0);
    char rgba[16] = {0};
    resvg_render(tree, resvg_transform_identity(), 2, 2, rgba);
    CHECK((unsigned char)rgba[0] == 255 && (unsigned char)rgba[3] == 255);
    resvg_tree_destroy(tree);
    resvg_options_destroy(opt);

    CHECK(avcodec_version() != 0 && avformat_version() != 0 && avfilter_version() != 0);
    CHECK(avcodec_find_encoder_by_name("libmp3lame"));
    CHECK(avcodec_find_encoder_by_name("libvpx-vp9"));
    CHECK(avcodec_find_decoder_by_name("libdav1d"));
    mpv_handle *mpv = mpv_create();
    CHECK(mpv);
    mpv_terminate_destroy(mpv);
    puts("iOS native dependency smoke passed");
    return 0;
}
