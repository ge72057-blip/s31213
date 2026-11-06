# 安卓和 iOS 共用的外部库编译。由 android-build.sh / ios-build.sh 载入后调用 run_deps。
# 调用方需要先准备好：SRC PREFIX OUT ROOT J REPORT TRIPLE ARCH VPXTARGET CMAKE_BASE X264_CFG PLAT_CFLAGS
#                    merge_static（合并静态库的函数）、$ROOT/meson-cross.txt、CC/CXX/AR/RANLIB 等环境变量
# ---------------- 小工具 ----------------
fetch() { # 网址 目录名：下载并解压到 $SRC/目录名
  local url="$1" name="$2" f="$SRC/$2.dl"
  curl -fL --retry 5 --retry-all-errors -o "$f" "$url" && rm -rf "$SRC/$name" && mkdir -p "$SRC/$name" \
    && tar -xf "$f" --strip-components=1 -C "$SRC/$name"
}
fixcfg() { # 老的 config.sub 不认识 android：下载 GNU 官方最新的，覆盖源码树里所有的
  local s="$ROOT/cfg/config.sub" g="$ROOT/cfg/config.guess" base
  if [ ! -s "$s" ] || [ ! -s "$g" ]; then
    mkdir -p "$ROOT/cfg"
    for base in "https://git.savannah.gnu.org/cgit/config.git/plain" "https://raw.githubusercontent.com/gcc-mirror/gcc/master"; do
      if curl -fsSL --retry 3 --retry-all-errors -o "$s" "$base/config.sub" \
         && curl -fsSL --retry 3 --retry-all-errors -o "$g" "$base/config.guess"; then break; fi
      rm -f "$s" "$g"
    done
    if [ ! -s "$s" ]; then # 两个源都连不上，才退回系统里找
      s="$(find /usr/share /opt/homebrew/share /usr/local/share -name config.sub 2>/dev/null | head -1)" || true
      g="$(find /usr/share /opt/homebrew/share /usr/local/share -name config.guess 2>/dev/null | head -1)" || true
    fi
  fi
  if [ -n "$s" ] && [ -s "$s" ]; then chmod +x "$s"; find . -name config.sub -exec cp "$s" {} \; ; fi
  if [ -n "$g" ] && [ -s "$g" ]; then chmod +x "$g"; find . -name config.guess -exec cp "$g" {} \; ; fi
  return 0
}
ac() { # autotools 通用
  fixcfg
  ./configure --host="$TRIPLE" --prefix="$PREFIX" --disable-shared --enable-static --with-pic "$@" \
    && make -j"$J" && make install
}
cm() { # cmake 通用：源码目录 [额外参数]
  local s="$1"; shift
  cmake -S "$s" -B "$s/_b" "${CMAKE_BASE[@]}" "$@" && cmake --build "$s/_b" -j"$J" && cmake --install "$s/_b"
}
ms() { # meson 通用：源码目录 [额外参数]
  local s="$1"; shift
  meson setup "$s/_b" "$s" --cross-file "$ROOT/meson-cross.txt" --prefix "$PREFIX" --libdir lib \
    --buildtype release --default-library static "$@" && ninja -C "$s/_b" install
}
try() { # 名字 函数：失败只记录，不中断；之前编成功过（缓存里有标记）就直接跳过
  local n="$1"; shift
  if [ -f "$PREFIX/.done-$n" ]; then echo "CACHE ${n}（上次已编好）" | tee -a "$REPORT"; return 0; fi
  echo "=== 编译 $n"
  ( set -e; "$@" ) > "$OUT/logs/dep-$n.log" 2>&1
  local rc=$?
  if [ $rc -eq 0 ]; then touch "$PREFIX/.done-$n"; echo "OK    $n" | tee -a "$REPORT"
  else echo "FAIL  ${n}（日志 logs/dep-${n}.log）" | tee -a "$REPORT"; tail -n 20 "$OUT/logs/dep-$n.log"; fi
}

# ---------------- 各个外部库 ----------------
dep_x264() {
  fetch "https://code.videolan.org/videolan/x264/-/archive/master/x264-master.tar.gz" x264
  cd "$SRC/x264"; fixcfg
  ./configure --host="$TRIPLE" --prefix="$PREFIX" "${X264_CFG[@]}" \
    --enable-static --enable-pic --disable-cli --disable-opencl
  make -j"$J" && make install
}
x265_build() { # 额外 cmake 参数...；用 && 串起来，保证失败能被外面发现
  local common=("${CMAKE_BASE[@]}" -DENABLE_SHARED=OFF -DENABLE_CLI=OFF "$@")
  mkdir -p b12 b10 b8 \
  && ( cd b12 && cmake ../source "${common[@]}" -DHIGH_BIT_DEPTH=ON -DEXPORT_C_API=OFF -DMAIN12=ON && cmake --build . -j"$J" ) \
  && ( cd b10 && cmake ../source "${common[@]}" -DHIGH_BIT_DEPTH=ON -DEXPORT_C_API=OFF && cmake --build . -j"$J" ) \
  && ( cd b8 && ln -sf ../b10/libx265.a libx265_main10.a && ln -sf ../b12/libx265.a libx265_main12.a \
       && cmake ../source "${common[@]}" -DEXTRA_LIB="x265_main10.a;x265_main12.a" -DEXTRA_LINK_FLAGS=-L. \
            -DLINKED_10BIT=ON -DLINKED_12BIT=ON \
       && cmake --build . -j"$J" && mv libx265.a libx265_main.a \
       && merge_static libx265.a libx265_main.a libx265_main10.a libx265_main12.a && cmake --install . )
}
dep_x265() { # 8/10/12 位合并成一个库
  fetch "https://bitbucket.org/multicoreware/x265_git/downloads/x265_4.1.tar.gz" x265
  cd "$SRC/x265"
  if [ "$PLATFORM" = android ] && [ "$ARCH" = aarch64 ]; then
    x265_build -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
      || { rm -rf b12 b10 b8; x265_build -DENABLE_ASSEMBLY=OFF; }
  else
    x265_build
  fi
}
dep_vpx() {
  fetch "https://github.com/webmproject/libvpx/archive/refs/tags/v1.15.0.tar.gz" libvpx
  cd "$SRC/libvpx"
  if [ "$ARCH" = aarch64 ]; then export AS="$CC"; fi
  export LD="$CC"
  local rtcd=--enable-runtime-cpu-detect
  if [ "$VPXTARGET" = generic-gnu ]; then rtcd=--disable-runtime-cpu-detect; fi
  local vx=()
  if [ -n "${PLAT_CFLAGS:-}" ]; then vx+=(--extra-cflags="$PLAT_CFLAGS"); fi
  ./configure --target="$VPXTARGET" --prefix="$PREFIX" "${vx[@]}" --enable-static --disable-shared --enable-pic \
    --disable-examples --disable-tools --disable-docs --disable-unit-tests \
    --enable-vp9-highbitdepth "$rtcd"
  make -j"$J" && make install
}
dep_dav1d() {
  fetch "https://code.videolan.org/videolan/dav1d/-/archive/1.5.1/dav1d-1.5.1.tar.gz" dav1d
  ms "$SRC/dav1d" -Denable_tools=false -Denable_tests=false
}
dep_opus() {
  fetch "https://downloads.xiph.org/releases/opus/opus-1.5.2.tar.gz" opus
  cd "$SRC/opus"; ac --disable-doc --disable-extra-programs
}
dep_ogg() {
  fetch "https://downloads.xiph.org/releases/ogg/libogg-1.3.5.tar.xz" ogg
  cd "$SRC/ogg"; ac
}
dep_vorbis() {
  fetch "https://downloads.xiph.org/releases/vorbis/libvorbis-1.3.7.tar.xz" vorbis
  cd "$SRC/vorbis"; sed -i.bak "s/-force_cpusubtype_ALL//g" configure; ac --disable-docs --disable-examples --disable-oggtest
}
dep_lame() {
  fetch "https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz" lame
  cd "$SRC/lame"; CFLAGS="-O2 -fPIC ${PLAT_CFLAGS:-} -Wno-error=implicit-function-declaration" ac --disable-frontend --disable-decoder --disable-gtktest
}
dep_freetype() {
  fetch "https://download.savannah.gnu.org/releases/freetype/freetype-2.13.3.tar.xz" freetype
  cd "$SRC/freetype"; ac --with-zlib=no --with-bzip2=no --with-png=no --with-brotli=no --with-harfbuzz=no
}
dep_fribidi() {
  fetch "https://github.com/fribidi/fribidi/releases/download/v1.0.16/fribidi-1.0.16.tar.xz" fribidi
  ms "$SRC/fribidi" -Ddocs=false -Dtests=false -Dbin=false
}
dep_harfbuzz() {
  fetch "https://github.com/harfbuzz/harfbuzz/releases/download/10.2.0/harfbuzz-10.2.0.tar.xz" harfbuzz
  ms "$SRC/harfbuzz" -Dfreetype=enabled -Dglib=disabled -Dgobject=disabled -Dcairo=disabled \
     -Dicu=disabled -Dtests=disabled -Ddocs=disabled -Dbenchmark=disabled -Dutilities=disabled
}
dep_libass() {
  fetch "https://github.com/libass/libass/releases/download/0.17.3/libass-0.17.3.tar.xz" libass
  cd "$SRC/libass"; ac --disable-fontconfig --disable-require-system-font-provider --disable-test --disable-profile
}
dep_webp() {
  fetch "https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-1.5.0.tar.gz" webp
  cm "$SRC/webp" -DWEBP_BUILD_ANIM_UTILS=OFF -DWEBP_BUILD_CWEBP=OFF -DWEBP_BUILD_DWEBP=OFF \
     -DWEBP_BUILD_GIF2WEBP=OFF -DWEBP_BUILD_IMG2WEBP=OFF -DWEBP_BUILD_VWEBP=OFF \
     -DWEBP_BUILD_WEBPINFO=OFF -DWEBP_BUILD_WEBPMUX=OFF -DWEBP_BUILD_EXTRAS=OFF -DWEBP_BUILD_LIBWEBPMUX=ON
}
dep_svtav1() {
  fetch "https://gitlab.com/AOMediaCodec/SVT-AV1/-/archive/v3.0.2/SVT-AV1-v3.0.2.tar.gz" svtav1
  cm "$SRC/svtav1" -DBUILD_APPS=OFF -DBUILD_DEC=OFF -DBUILD_TESTING=OFF
}
dep_aom() {
  fetch "https://storage.googleapis.com/aom-releases/libaom-3.12.1.tar.gz" aom
  local extra=()
  [ "$ARCH" = aarch64 ] && extra+=(-DCONFIG_RUNTIME_CPU_DETECT=0)
  cm "$SRC/aom" -DENABLE_DOCS=0 -DENABLE_EXAMPLES=0 -DENABLE_TESTS=0 -DENABLE_TOOLS=0 "${extra[@]}"
}
dep_zimg() {
  rm -rf "$SRC/zimg"
  git clone --depth 1 --recursive --branch release-3.0.5 https://github.com/sekrit-twc/zimg.git "$SRC/zimg"
  cd "$SRC/zimg"; autoreconf -fi; ac
}
dep_soxr() {
  fetch "https://downloads.sourceforge.net/project/soxr/soxr-0.1.3-Source.tar.xz" soxr
  cm "$SRC/soxr" -DBUILD_TESTS=OFF -DBUILD_EXAMPLES=OFF -DWITH_OPENMP=OFF -DWITH_LSR_BINDINGS=OFF
}

dep_mbedtls() {
  fetch "https://github.com/Mbed-TLS/mbedtls/releases/download/mbedtls-3.6.2/mbedtls-3.6.2.tar.bz2" mbedtls
  cm "$SRC/mbedtls" -DENABLE_TESTING=OFF -DENABLE_PROGRAMS=OFF -DMBEDTLS_FATAL_WARNINGS=OFF
}
dep_vmaf() {
  fetch "https://github.com/Netflix/vmaf/archive/refs/tags/v3.0.0.tar.gz" vmaf
  ms "$SRC/vmaf/libvmaf" -Denable_tests=false -Denable_docs=false -Dbuilt_in_models=true -Denable_float=true
}
dep_srt() {
  fetch "https://github.com/Haivision/srt/archive/refs/tags/v1.5.4.tar.gz" srt
  cm "$SRC/srt" -DENABLE_APPS=OFF -DENABLE_SHARED=OFF -DENABLE_STATIC=ON -DENABLE_ENCRYPTION=ON \
     -DUSE_ENCLIB=mbedtls -DMBEDTLS_PREFIX="$PREFIX" -DENABLE_UNITTESTS=OFF -DENABLE_CXX11=ON
}
dep_librist() {
  fetch "https://code.videolan.org/rist/librist/-/archive/v0.2.10/librist-v0.2.10.tar.gz" librist
  ms "$SRC/librist" -Dbuilt_tools=false -Dtest=false
}
dep_jxl() {
  rm -rf "$SRC/libjxl"
  git clone --depth 1 --recursive --shallow-submodules --branch v0.11.1 https://github.com/libjxl/libjxl.git "$SRC/libjxl"
  # JPEGXL_STATIC 会给可执行文件加 -static，iOS 上链接不了（找不到 crt0.o），iOS 不要这个选项
  local jxl_static=()
  if [ "$PLATFORM" != ios ]; then jxl_static+=(-DJPEGXL_STATIC=ON); fi
  cm "$SRC/libjxl" -DBUILD_TESTING=OFF -DJPEGXL_ENABLE_TOOLS=OFF -DJPEGXL_ENABLE_DOXYGEN=OFF \
     -DJPEGXL_ENABLE_MANPAGES=OFF -DJPEGXL_ENABLE_BENCHMARK=OFF -DJPEGXL_ENABLE_EXAMPLES=OFF \
     -DJPEGXL_ENABLE_JNI=OFF -DJPEGXL_ENABLE_SJPEG=OFF -DJPEGXL_ENABLE_OPENEXR=OFF \
     -DJPEGXL_ENABLE_PLUGINS=OFF -DJPEGXL_ENABLE_VIEWERS=OFF -DJPEGXL_ENABLE_DEVTOOLS=OFF \
     -DHWY_ENABLE_EXAMPLES=OFF -DHWY_ENABLE_TESTS=OFF -DJPEGXL_ENABLE_FUZZERS=OFF \
     "${jxl_static[@]}" -DJPEGXL_ENABLE_SKCMS=ON -DJPEGXL_ENABLE_JPEGLI=OFF -DJPEGXL_ENABLE_JPEGLI_LIBJPEG=OFF
}
dep_chromaprint() {
  fetch "https://github.com/acoustid/chromaprint/releases/download/v1.5.1/chromaprint-1.5.1.tar.gz" chromaprint
  fetch "https://github.com/mborgerding/kissfft/archive/refs/heads/master.tar.gz" kissfft
  mkdir -p "$SRC/kissfft/tools"; cp "$SRC/kissfft/kiss_fftr.c" "$SRC/kissfft/kiss_fftr.h" "$SRC/kissfft/tools/"
  cm "$SRC/chromaprint" -DBUILD_TOOLS=OFF -DBUILD_TESTS=OFF -DFFT_LIB=kissfft -DKISSFFT_SOURCE_DIR="$SRC/kissfft"
}
dep_whisper() { # 用最新主干（FFmpeg 8 的 whisper 滤镜需要较新的 whisper.cpp）
  fetch "https://github.com/ggml-org/whisper.cpp/archive/refs/heads/master.tar.gz" whisper
  cm "$SRC/whisper" -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_EXAMPLES=OFF -DWHISPER_BUILD_SERVER=OFF \
     -DGGML_METAL=OFF -DGGML_OPENMP=OFF -DGGML_NATIVE=OFF -DGGML_CCACHE=OFF -DWHISPER_CURL=OFF
}
fix_whisper_pc() { # 每次运行都重写（即使 whisper 是从缓存里恢复的），保证版本号和库列表正确
  [ -f "$PREFIX/lib/libwhisper.a" ] || return 0
  local libs="-L\${libdir}" n
  for n in whisper ggml ggml-cpu ggml-blas ggml-base; do
    if [ -f "$PREFIX/lib/lib$n.a" ]; then libs+=" -l$n"; fi
  done
  if [ "$PLATFORM" = ios ]; then libs+=" -framework Accelerate"; fi
  cat > "$PREFIX/lib/pkgconfig/whisper.pc" <<PC
prefix=$PREFIX
libdir=\${prefix}/lib
includedir=\${prefix}/include
Name: whisper
Description: whisper.cpp
Version: 1.8.0
Libs: $libs
Cflags: -I\${includedir}
PC
}
dep_lcms2() {
  fetch "https://github.com/mm2/Little-CMS/releases/download/lcms2.16/lcms2-2.16.tar.gz" lcms2
  cd "$SRC/lcms2"; ac --without-jpeg --without-tiff
}
dep_libxml2() { # 安卓 28 以下没有 iconv，所以关掉
  fetch "https://download.gnome.org/sources/libxml2/2.13/libxml2-2.13.5.tar.xz" libxml2
  cm "$SRC/libxml2" "-DCMAKE_C_FLAGS=-O2 -fPIC ${PLAT_CFLAGS:-} -Wno-implicit-function-declaration" -DLIBXML2_WITH_PYTHON=OFF -DLIBXML2_WITH_ICONV=OFF -DLIBXML2_WITH_LZMA=OFF \
     -DLIBXML2_WITH_TESTS=OFF -DLIBXML2_WITH_PROGRAMS=OFF -DLIBXML2_WITH_MODULES=OFF
}
dep_openjpeg() {
  fetch "https://github.com/uclouvain/openjpeg/archive/refs/tags/v2.5.3.tar.gz" openjpeg
  cm "$SRC/openjpeg" -DBUILD_CODEC=OFF -DBUILD_TESTING=OFF -DBUILD_DOC=OFF -DBUILD_JPIP=OFF -DBUILD_PKGCONFIG_FILES=ON
}
dep_kvazaar() {
  fetch "https://github.com/ultravideo/kvazaar/releases/download/v2.3.1/kvazaar-2.3.1.tar.xz" kvazaar
  cd "$SRC/kvazaar"; ac
}
dep_openh264() {
  fetch "https://github.com/cisco/openh264/archive/refs/tags/v2.5.0.tar.gz" openh264
  ms "$SRC/openh264" -Dtests=disabled
}
dep_speex() {
  fetch "https://downloads.xiph.org/releases/speex/speex-1.2.1.tar.gz" speex
  cd "$SRC/speex"; ac --disable-binaries
}
dep_gsm() {
  fetch "https://www.quut.com/gsm/gsm-1.0.22.tar.gz" gsm
  cd "$SRC/gsm"
  make -j"$J" lib/libgsm.a CC="$CC" CCFLAGS="-c -O2 -fPIC -DNeedFunctionPrototypes=1 -DWAV49 ${PLAT_CFLAGS:-}" AR="$AR" RANLIB="$RANLIB"
  mkdir -p "$PREFIX/include/gsm"
  cp inc/gsm.h "$PREFIX/include/gsm/"
  cp lib/libgsm.a "$PREFIX/lib/"
}
mk_zlib_pc() {
  cat > "$PREFIX/lib/pkgconfig/zlib.pc" <<PC
Name: zlib
Description: zlib (system)
Version: 1.3.1
Libs: -lz
PC
}

run_deps() {
  mk_zlib_pc
  try libvpx dep_vpx
  try dav1d dep_dav1d
  try opus dep_opus
  try ogg dep_ogg
  try vorbis dep_vorbis
  try lame dep_lame
  try freetype dep_freetype
  try fribidi dep_fribidi
  try harfbuzz dep_harfbuzz
  try libass dep_libass
  try webp dep_webp
  try svtav1 dep_svtav1
  try aom dep_aom
  try zimg dep_zimg
  try soxr dep_soxr
  try mbedtls dep_mbedtls
  try vmaf dep_vmaf
  try srt dep_srt
  try librist dep_librist
  try libjxl dep_jxl
  try chromaprint dep_chromaprint
  try whisper dep_whisper
  try lcms2 dep_lcms2
  try libxml2 dep_libxml2
  try openjpeg dep_openjpeg
  try kvazaar dep_kvazaar
  try openh264 dep_openh264
  try speex dep_speex
  try gsm dep_gsm
  # x264/x265 是 GPL，只给"完整版可执行文件"用；iOS 不能带 GPL，所以跳过
  if [ "${SKIP_GPL:-0}" != 1 ]; then
    try x264 dep_x264
    try x265 dep_x265
  fi
  fix_whisper_pc
}
