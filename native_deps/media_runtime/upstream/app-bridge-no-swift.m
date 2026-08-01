#include "osdep/mac/app_bridge_objc.h"

// media-kit owns the application lifecycle and input bridge. mpv 0.41 calls
// these hooks even in libmpv-only builds where Swift support is disabled.
void cocoa_init_media_keys(void) {}
void cocoa_uninit_media_keys(void) {}
void cocoa_set_input_context(struct input_ctx *input_context) {}
void cocoa_set_mpv_handle(struct mpv_handle *ctx) { mpv_destroy(ctx); }
void cocoa_init_cocoa_cb(void) {}
int cocoa_main(int argc, char *argv[]) { return 0; }
