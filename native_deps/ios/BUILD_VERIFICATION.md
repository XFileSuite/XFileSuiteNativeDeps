# Local build verification — 2026-11-14

- Host: Apple Silicon macOS, Xcode 27.0 (27A266a), iOS SDK 27.0.
- Rust: 1.98.1; Meson: 1.11.2; deployment target: iOS 15.0.
- All four component groups built for iOS device arm64 and Simulator arm64.
- 37 dynamic-framework XCFrameworks produced, including the entire shared
  image/media closure and Oxipng/resvg C APIs.
- Package verification passed for both slices: Mach-O platforms, public
  symbols and headers, dSYM UUIDs, relocatable install names and dependency
  closure.
- An independent C consumer compiled and linked against the final package on
  both platforms. It references Wand PNG generation, in-memory Oxipng,
  resvg rasterization, LibRaw/X3F, FFmpeg codec discovery and libmpv.
- ImageMagick JPEG/PNG/TIFF/WebP/RAW delegate configuration was checked;
  subprocess, pipe and unavailable getentropy references are excluded.
- FFmpeg build flags keep GPL/nonfree/version3 off and system TLS,
  VideoToolbox/AudioToolbox, subtitle and external codec libraries enabled.
  Private SecIdentityCreate references are excluded.
- Matching source packaging includes all pinned archives, patches, the Oxipng
  bridge, the Rust dependency vendor tree and build metadata.

No iOS Simulator runtime was installed on this host. The consumer was linked,
not executed. Playback, codecs on real hardware, audio routing, memory and
lifecycle behavior still require an iOS host during future integration.
No Flutter application files were changed. CI was authored but has not been
run remotely; the artifacts are local and have not been published.

## Review follow-up

The build cache and package-only path now reject recipe, shared patch, Oxipng
source, SDK, toolchain and deployment-setting changes before reusing outputs.
Partial diagnostic builds cannot be published as complete deliverables. Six
regression tests cover stale patch/source inputs, mismatched deployment settings,
missing targets and preservation of existing verified artifacts.

The iOS workflow pins Rust 1.98.1, runs those tests and retains both build/source
packaging logs. Its definition is also included in the matching source archive.

App packaging workflows are unchanged. Windows native-dependency jobs now
support both build-only and publish, with remote writes and manifest mirroring
restricted to publish mode. The independent iOS workflow is unaffected.

The review reran both native builds from fresh device/simulator intermediate
directories while retaining checksum-verified source downloads and unchanged
Cargo outputs. Both completed successfully. Workflow definitions passed
actionlint. No remote workflow or desktop installer was executed locally.

Local iOS build outputs, intermediate trees and temporary research checkouts
were removed after verification, at the user's request. Routine future builds
use GitHub Actions. This file records historical verification, not retained
local binary artifacts.
