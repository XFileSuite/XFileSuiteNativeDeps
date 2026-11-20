# XFileSuite iOS native libraries

This directory builds native libraries only. It does not modify or build the
Flutter application. The default deployment target is iOS 15.0, with separate
arm64 iPhone/iPad and arm64 iOS Simulator slices. Intel simulators, Mac Catalyst,
tvOS and visionOS are not part of this build.

## Build

For routine builds, run **Build iOS Native Dependencies** in GitHub Actions and
download its runtime/source artifacts. Local generated artifacts are not kept.
The commands below document the same CI entrypoints.

Use macOS with a full Xcode installation selected by `xcode-select`, Rust 1.88+
through rustup, Python 3.11+, CMake, Ninja, Meson 1.11.2, pkg-config, Autoconf,
Automake and GNU Libtool. libplacebo's GL generator uses the pinned Jinja and
MarkupSafe source inputs from the lock file. On Apple Silicon, ensure host
build tools run natively.

```sh
python3 native_deps/ios/build.py
python3 native_deps/ios/package-source.py
```

The first command builds both platforms, creates XCFrameworks, checks the
packaged dependency closure and writes `native_deps/ios/dist/xfilesuite-ios.tar.gz`.
The second creates the matching source archive, including checked source
archives, local patches, the Oxipng C bridge and vendored Cargo dependencies.
GitHub Actions `Build iOS Native Dependencies` runs the same commands and keeps
artifacts without publishing or changing the desktop manifests. It runs the
cache/package regression tests, builds and verifies both platform slices,
packages corresponding source and uploads runtime/source archives plus their
checksums. It can be triggered manually or by a matching pull request; there is
no automatic push release. The CI Rust version is pinned.

For publication, use **Publish Native Dependencies** with `mode=publish`,
`component=all` and `platform=ios` (or `platform=all` for all three platforms).
The iOS job uploads the runtime to a SHA-256-addressed R2 key,
publishes corresponding source/checksums to a GitHub Release, and commits
`native_deps/manifests/ios.json` and `native_deps/sbom-ios.json` here and to the
public repository. `mode=build-only` prepares these files as Actions artifacts
without publishing. iOS requires the complete bundle: desktop component-specific
runs skip iOS. Full R2 cleanup waits for all three platforms and retains each
current manifest's runtime key. No private App manifest is added at this stage.

For a targeted build, use for example:

```sh
python3 native_deps/ios/build.py --components oxipng resvg --no-package
python3 native_deps/ios/build.py --components media --targets device --no-package
python3 native_deps/ios/build.py --package-only
```

Build products and completed-component markers are under `work/`. After changing
build settings, source versions, patches, Xcode, or the deployment target, remove
`native_deps/ios/work/device`, `work/simulator` and `work/rust-target` before
rebuilding. Cache reuse and `--package-only` both check recipe, shared patches,
Oxipng source, toolchain and deployment settings; stale inputs are rejected
before replacing an existing deliverable. Downloaded source archives can be retained. Do not run two builders
for the same component and target at once. A full deliverable uses all four
component groups; partial builds are intended for diagnostics and require
`--no-package`. Source packaging requires a runtime package matching the current
recipe. Run the guard regression tests with:

```sh
python3 -m unittest discover -s native_deps/ios/tests -p 'test_*.py'
```

## Deliverable contract

```text
Frameworks/          # XCFrameworks; embed and sign dynamic frameworks only
Resources/           # ImageMagick configuration, never executable tools
licenses/            # Exact upstream notices and Cargo package license files
metadata/
  BUILDINFO.json
  sources.lock.json
  SBOM.json
  *-Cargo.lock
  SHA256SUMS
```

ImageMagick, LibRaw, MozJPEG, PNG, WebP and TIFF expose their upstream public
APIs. FFmpeg exposes libavcodec/libavformat/libavutil/libavfilter/libswresample/
libswscale (and other built FFmpeg libraries); mpv exposes its client and render
APIs. FFmpeg and mpv share the same FFmpeg library binaries. The dependency
closure is packaged once, including libass, FreeType, HarfBuzz, FriBidi, dav1d,
libplacebo, uchardet, Ogg/Vorbis/Opus, LAME and libxml2. VPX is statically linked
into FFmpeg. Oxipng and resvg expose C APIs in dynamic-framework XCFrameworks, avoiding
duplicate Rust runtime symbols when linked together.

The runtime has no standalone `ffmpeg`, `ffprobe`, `magick` or `resvg`
executables. `xfs_ffmpeg_cli.xcframework` provides an in-process
`xfs_ffmpeg_run` entry point compiled from the pinned FFmpeg command frontend.
It dynamically links the same libav frameworks as mpv. Call it from a background
queue with an argument array and per-job cancellation/progress callbacks. It
does not install terminal handlers or redirect process output. FFmpeg options
that alter host state, such as `-report` and `-cpuflags`, are unavailable.

## Integration notes

- Add the matching XCFramework slices through Xcode or a future Swift package.
  Embed/sign the dynamic frameworks and their entire bundled dependency closure.
  Oxipng/resvg are dynamic frameworks as well; do not link their independent
  Rust static archives into the same executable.
- Public headers preserve upstream include paths. MagickWand consumers need
  `Headers/ImageMagick-7` on the include path and matching
  `MAGICKCORE_QUANTUM_DEPTH=16`, `MAGICKCORE_HDRI_ENABLE=1` definitions.
- Copy `Resources/ImageMagick-7` and set the ImageMagick configure directory
  before initialization. ImageMagick has no external-command delegates or pipe
  execution on iOS. Built-in image coders remain available; Ghostscript, HEIC,
  JXL, OpenEXR and other disabled desktop delegates are not added here.
- resvg font loading is explicit: provide font bytes/files from the app bundle
  or its sandbox. Do not depend on desktop font directories.
- mpv is configured for AudioUnit and iOS OpenGL ES interop. The app owns its
  rendering context, audio session and foreground/background behavior.
- FFmpeg uses VideoToolbox/AudioToolbox and the system SecureTransport TLS
  backend, with the existing private `SecIdentityCreate` call removal patch.
  GPL, nonfree and version3 options remain disabled. There is no x264/x265.
- Keep matching LGPL source, notices and any required relinking materials with
  the distribution. Framework packaging alone does not establish license
  compliance or App Store acceptance. LibRaw retains its upstream dual license.

## Verification boundary

`verify.py` checks device/simulator declarations and Mach-O platforms, expected
public symbols, headers, debug symbol presence and relocatable dynamic-library
dependencies. `smoke-link.py` compiles and links an independent C consumer for
both platforms. Neither static inspection nor link checks establish runtime
playback, encoding, memory behavior, hardware decoding or App Store approval.
Those require an iOS host and device/simulator execution during app integration.
