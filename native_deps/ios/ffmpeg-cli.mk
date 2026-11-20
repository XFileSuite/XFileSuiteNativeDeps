# Included after FFmpeg's Makefile. Reuse the upstream object list so the
# command frontend and installed libav libraries share the same configuration.
xfs-ffmpeg-cli: $(OBJS-ffmpeg)
	$(CC) $(LDFLAGS) -dynamiclib -install_name @rpath/libxfs_ffmpeg_cli.dylib \
	    -Wl,-exported_symbol,_xfs_ffmpeg_run -o "$(XFS_CLI_OUTPUT)" $(OBJS-ffmpeg) \
	    $(addprefix -lav,device filter format codec util) -lswresample -lswscale -lz
