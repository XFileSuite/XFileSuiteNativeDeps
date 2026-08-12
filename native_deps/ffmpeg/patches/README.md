# Source-package patches

`package-source.sh` generates `libvorbis-configure-macos-xcode.patch` in every
public source archive. It records one historical source-tree adjustment:
removing the obsolete `-force_cpusubtype_ALL` compiler flag from libvorbis
1.3.7's `configure` script.

`ffmpeg-tls-securetransport-no-private-api.patch` is applied to FFmpeg 8.1.2
before it is configured on macOS. It removes the reference to the private
`SecIdentityCreate` API from `libavformat/tls_securetransport.c` so that the
resulting binary can be submitted to the Mac App Store while still using the
system SecureTransport TLS backend. Client-certificate authentication is
returned as `ENOSYS`; ordinary server-certificate TLS connections are
unaffected.
