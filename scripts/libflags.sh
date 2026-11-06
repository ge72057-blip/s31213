# 两个平台共用的"要启用哪些外部库"清单——Windows 和安卓都读这一份，保证功能一致。
# 用法：先设好 LIBDIR（静态库所在目录）和 USE_MBEDTLS（安卓=1，Windows=0），再 source 本文件。
have() { pkg-config --exists "$1"; }

LIBFLAGS=()   # 不含 x264/x265（完整版和 LGPL 版都能用的）
# 视频
have dav1d && LIBFLAGS+=(--enable-libdav1d)
have vpx && LIBFLAGS+=(--enable-libvpx)
have SvtAv1Enc && LIBFLAGS+=(--enable-libsvtav1)
have aom && LIBFLAGS+=(--enable-libaom)
have kvazaar && LIBFLAGS+=(--enable-libkvazaar)
have openh264 && LIBFLAGS+=(--enable-libopenh264)
have libvmaf && LIBFLAGS+=(--enable-libvmaf)
# 音频
have opus && LIBFLAGS+=(--enable-libopus)
have vorbis && have vorbisenc && LIBFLAGS+=(--enable-libvorbis)
[ -f "$LIBDIR/libmp3lame.a" ] && LIBFLAGS+=(--enable-libmp3lame)
have speex && LIBFLAGS+=(--enable-libspeex)
[ -f "$LIBDIR/libgsm.a" ] && LIBFLAGS+=(--enable-libgsm)
[ -f "$LIBDIR/libsoxr.a" ] && LIBFLAGS+=(--enable-libsoxr)
have libchromaprint && LIBFLAGS+=(--enable-chromaprint)
have whisper && LIBFLAGS+=(--enable-whisper)
# 字幕、文字
have libass && LIBFLAGS+=(--enable-libass)
have freetype2 && LIBFLAGS+=(--enable-libfreetype)
have fribidi && LIBFLAGS+=(--enable-libfribidi)
have harfbuzz && LIBFLAGS+=(--enable-libharfbuzz)
# 图片、色彩
have libwebp && have libwebpmux && LIBFLAGS+=(--enable-libwebp)
have libjxl && have libjxl_threads && LIBFLAGS+=(--enable-libjxl)
have libopenjp2 && LIBFLAGS+=(--enable-libopenjpeg)
have zimg && LIBFLAGS+=(--enable-libzimg)
have lcms2 && LIBFLAGS+=(--enable-lcms2)
# 网络、流媒体
have srt && LIBFLAGS+=(--enable-libsrt)
have librist && LIBFLAGS+=(--enable-librist)
have libxml-2.0 && LIBFLAGS+=(--enable-libxml2)
# https：安卓用 mbedtls（Windows 用系统自带的 schannel，不走这里）。mbedtls 要求打开 version3（LGPL v3）
if [ "${USE_MBEDTLS:-0}" = 1 ] && [ -f "$LIBDIR/libmbedtls.a" ]; then
  LIBFLAGS+=(--enable-mbedtls --enable-version3)
fi
