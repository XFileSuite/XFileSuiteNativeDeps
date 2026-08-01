# XFileSuite media runtime

This component owns the native playback and FFmpeg command-line runtime used by
XFileSuite. It is published as one versioned bundle because `libmpv`, FFmpeg's
shared libraries and the FFmpeg CLI are ABI-coupled and must never be upgraded
independently.

## macOS runtime contract

The published archive has this layout:

```text
Frameworks/
  Mpv.xcframework/
  Avcodec.xcframework/
  Avformat.xcframework/
  Avutil.xcframework/
  Avfilter.xcframework/
  Swresample.xcframework/
  Swscale.xcframework/
  ...
Tools/
  ffmpeg
metadata/
  BUILDINFO.md
  SHA256SUMS
licenses/
  NOTICE.md
  ... exact license texts for bundled native components
```

`Mpv` and `Tools/ffmpeg` must both resolve FFmpeg through the same
`@rpath/Av*.framework` binaries. The verification script rejects a runtime
where the CLI is self-contained or points at Homebrew/MacPorts paths.

The build remains LGPL-compatible:

- mpv is configured with `-Dgpl=false`;
- FFmpeg is built without `--enable-gpl` or `--enable-nonfree`;
- Mbed TLS and HTTPS/TLS/RTMPS playback protocols are excluded, so the runtime
  remains compatible with LGPL-2.1 rather than requiring LGPL-3;
- GPL codec libraries such as x264 and x265 are not included;
- the corresponding-source archive records exact upstream sources, patches,
  configuration and build scripts.

## Migration safety

The macOS manifest publishes only this shared runtime. It does not publish or
download a second standalone FFmpeg bundle. `native_deps/ffmpeg/build.sh` is
retained as the common FFmpeg 8.1.2 builder used by this runtime and by the
separate Windows dependency workflow.
