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
- network playback supports HTTP/HTTPS, HLS, DASH, RTMP/RTMPS and RTSP/RTP
  while remaining LGPL-2.1-compatible: macOS uses the system
  SecureTransport backend and Windows uses the system SChannel backend;
- Mbed TLS, OpenSSL, GnuTLS and other third-party TLS libraries are excluded,
  so `--enable-version3` is not required;
- GPL codec libraries such as x264 and x265 are not included;
- the corresponding-source archive records exact upstream sources, patches,
  configuration and build scripts.

## Migration safety

The macOS manifest publishes only this shared runtime. It does not publish or
download a second standalone FFmpeg bundle. `native_deps/ffmpeg/build.sh` is
retained as the common FFmpeg 8.1.2 builder used by this runtime and by the
separate Windows dependency workflow.

## CoreAudio on macOS 27

The macOS mpv 0.41.0 build backports upstream commit
`3dae21b1ed4793912a8f9de1c5eb3cf32d227bce` through
`patches/libmpv-coreaudio-macos27.patch`. It removes an invalid
`kAudioOutputUnitProperty_ChannelMap` payload that macOS 27 rejects with
`-50`, preventing shared audio output from initializing. Channel negotiation
and shared playback remain enabled; no exclusive-output workaround is used.

After rebuilding, verify ordinary CoreAudio output on macOS 27 with mono and
stereo files, simultaneous playback in another app, and output-device switching.
Static framework verification alone does not cover this runtime failure.

## Stable 0.41 backports (macOS revision 5 / Windows revision 4)

The runtime remains FFmpeg 8.1.2 + mpv 0.41.0 + libplacebo 6.338.2.
`patches/mpv-041-backports.json` records the exact upstream commits and affected
files; the same record is packaged as `metadata/MPV_BACKPORTS.json`.

- Common fixes cover EDL/subtitle bounds, invalid bitmap sizes, hardware-frame
  screenshots, subtitle packet timing/deduplication, cancellable demux reads,
  and gradual packet-pool reclamation. The 0.41 packet cleanup semantics and
  the existing HEVC Alpha patch are preserved.
- macOS additionally fixes failed-AO cleanup, hotplug registration/reload and
  preferred/mono/multichannel layout mapping.
- Windows explicitly enables WASAPI (required with `auto_features=disabled`),
  verifies the configured feature and packaged driver, fixes device-invalidated
  retry timing and avoids known-broken Intel HEVC/VP9 drivers.
- TLS verification defaults to **yes** in 0.41's `stream_lavf` configuration,
  using SecureTransport/SChannel system trust stores. It is not conditional on
  libcurl or a libavformat 63 upgrade. No automatic certificate bypass is added.

Both package verifiers exercise the packaged ABI via `tests/runtime_probe.py`:
local load/seek/stop cycles, a 78x64 subtitle screenshot, EDL metadata, plain
HTTP, rejection of an untrusted local HTTPS chain and normal system-trusted
HTTPS in Actions. macOS also tests an isolated explicit CA, wrong hostname and
expired leaf. Generated test roots are never installed in system trust stores.
Headless Windows Actions cannot establish physical speaker/wake-up behavior;
that acceptance requires a Windows audio device. Driver presence is mandatory
regardless of whether the runner has an endpoint.

After installing a newly built runtime, repeat the App's real video/audio,
output-device and screenshot paths. Keep the existing local hardware-screenshot
fallback until its replacement is separately accepted.
