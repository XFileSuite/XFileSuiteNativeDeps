#ifndef XFS_FFMPEG_CLI_H
#define XFS_FFMPEG_CLI_H
#include <stdint.h>

typedef int (*XFSFFmpegCancelled)(void *context);
typedef void (*XFSFFmpegProgress)(void *context, int64_t microseconds);

/* Synchronous. Invoke on a background queue. argv includes argv[0] and ends
 * with NULL. Callbacks and context must remain valid until this returns.
 * A concurrent submission returns AVERROR(EBUSY). */
int xfs_ffmpeg_run(int argc, char **argv, XFSFFmpegCancelled cancel,
                   XFSFFmpegProgress progress, void *context);
#endif
