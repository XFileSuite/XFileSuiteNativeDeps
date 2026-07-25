# Source-package patches

`package-source.sh` generates `libvorbis-configure-macos-xcode.patch` in every
public source archive. It records the only source-tree adjustment performed by
the macOS FFmpeg build: removing the obsolete `-force_cpusubtype_ALL` compiler
flag from libvorbis 1.3.7's `configure` script. No FFmpeg source file is modified.
