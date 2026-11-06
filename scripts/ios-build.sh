#!/usr/bin/env bash
# 在 GitHub 的 macOS 机器上运行（不需要你自己有 Mac）。
# 用法：bash scripts/ios-build.sh ios-arm64        （真机）
#       bash scripts/ios-build.sh ios-sim-arm64    （模拟器，Apple 芯片的 Mac 上用）
#
# iOS 的两个硬性规矩：
#   1) 不能运行外部程序，所以没有 ffmpeg 可执行文件，只有库；转码也要通过库来做。
#   2) 不能带 GPL，所以没有 x264/x265（App Store 与 GPL 不兼容）；H.264/H.265 编码走系统的 VideoToolbox 硬件。
# 产出：out/<目标>/lgpl/lib/libffmpeg.a（所有库合并成一个静态库）和 link-flags.txt（链接时要加的系统框架）。
set -u -o pipefail

TARGET="${1:?缺少参数：ios-arm64 或 ios-sim-arm64}"
FFVER="${FFMPEG_VERSION:-8.1.3}"
MINIOS=13.0

case "$TARGET" in
  ios-arm64)     SDKNAME=iphoneos;        MINFLAG="-miphoneos-version-min=$MINIOS";        VPXTARGET=arm64-darwin-gcc ;;
  ios-sim-arm64) SDKNAME=iphonesimulator; MINFLAG="-mios-simulator-version-min=$MINIOS";   VPXTARGET=generic-gnu ;;   # 模拟器用通用目标（没有汇编优化，模拟器上无所谓）
  *) echo "不认识的目标：$TARGET"; exit 1 ;;
esac

SDK="$(xcrun --sdk "$SDKNAME" --show-sdk-path)"
PLATFORM=ios; ARCH=aarch64; TRIPLE=aarch64-apple-darwin; SKIP_GPL=1
J="$(sysctl -n hw.ncpu)"
ROOT="$PWD/build/$TARGET"; SRC="$ROOT/src"; PREFIX="$ROOT/prefix"; OUT="$PWD/out/$TARGET"
mkdir -p "$SRC" "$PREFIX/lib/pkgconfig" "$OUT/lgpl/lib" "$OUT/logs"
REPORT="$OUT/dep-report.txt"; : > "$REPORT"

# autoreconf 要用到的 libtoolize（brew 里叫 glibtoolize，这里让它也能用 libtoolize 这个名字）
export PATH="$(brew --prefix libtool)/libexec/gnubin:$PATH"

PLAT_CFLAGS="-arch arm64 -isysroot $SDK $MINFLAG"
export CC="$(xcrun --sdk "$SDKNAME" -f clang)"
export CXX="$(xcrun --sdk "$SDKNAME" -f clang++)"
export AR="$(xcrun -f ar)" RANLIB="$(xcrun -f ranlib)" NM="$(xcrun -f nm)" STRIP="$(xcrun -f strip)"
export CFLAGS="-O2 -fPIC $PLAT_CFLAGS" CXXFLAGS="-O2 -fPIC $PLAT_CFLAGS"
export CPPFLAGS="-I$PREFIX/include" LDFLAGS="-L$PREFIX/lib $PLAT_CFLAGS"
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"; unset PKG_CONFIG_PATH

CMAKE_BASE=(
  -G Ninja
  -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT="$SDKNAME" -DCMAKE_OSX_ARCHITECTURES=arm64
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$MINIOS"
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_INSTALL_LIBDIR=lib
  -DCMAKE_PREFIX_PATH="$PREFIX" -DCMAKE_FIND_ROOT_PATH="$PREFIX"
  -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=BOTH -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=BOTH -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=BOTH
  -DBUILD_SHARED_LIBS=OFF -DCMAKE_POSITION_INDEPENDENT_CODE=ON
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY
  -DCMAKE_MACOSX_BUNDLE=OFF
)

ARGS="'-arch','arm64','-isysroot','$SDK','$MINFLAG','-O2','-fPIC','-I$PREFIX/include'"
cat > "$ROOT/meson-cross.txt" <<MESON
[binaries]
c = '$CC'
cpp = '$CXX'
ar = '$AR'
strip = '$STRIP'
pkg-config = 'pkg-config'
[host_machine]
system = 'darwin'
cpu_family = 'aarch64'
cpu = 'arm64'
endian = 'little'
[built-in options]
c_args = [$ARGS]
cpp_args = [$ARGS]
c_link_args = ['-arch','arm64','-isysroot','$SDK','$MINFLAG','-L$PREFIX/lib']
cpp_link_args = ['-arch','arm64','-isysroot','$SDK','$MINFLAG','-L$PREFIX/lib']
[properties]
needs_exe_wrapper = true
pkg_config_libdir = '$PREFIX/lib/pkgconfig'
MESON

X264_CFG=()
merge_static() { # 输出 输入...：把几个 .a 合成一个（苹果自带的 libtool）
  local o="$1"; shift
  /usr/bin/libtool -static -o "$o" "$@"   # 必须用苹果自带的，PATH 里前面放了 GNU 版的 libtool
}
# shellcheck source=deps.sh
source "$(dirname "$0")/deps.sh"
run_deps

# iOS 的 C++ 运行库叫 libc++（不是 stdc++）
sed -i.bak 's/-lstdc++/-lc++/g' "$PREFIX"/lib/pkgconfig/*.pc 2>/dev/null; rm -f "$PREFIX"/lib/pkgconfig/*.bak

LIBDIR="$PREFIX/lib"; USE_MBEDTLS=1
# shellcheck source=libflags.sh
source "$(dirname "$0")/libflags.sh"

rm -rf "$SRC/ffmpeg"
git clone --depth 1 --branch "n$FFVER" https://github.com/FFmpeg/FFmpeg.git "$SRC/ffmpeg" \
  || { echo "下载 FFmpeg n$FFVER 失败（版本号对不对？）"; exit 1; }
unset CFLAGS CXXFLAGS CPPFLAGS LDFLAGS

mkdir -p "$ROOT/ffb" && cd "$ROOT/ffb" || exit 1
"$SRC/ffmpeg/configure" --prefix="$ROOT/ffi" \
  --enable-cross-compile --target-os=darwin --arch=arm64 \
  --cc="$CC" --cxx="$CXX" --ld="$CXX" --ar="$AR" --nm="$NM" --ranlib="$RANLIB" --strip="$STRIP" \
  --pkg-config=pkg-config --pkg-config-flags=--static \
  --enable-pic --disable-autodetect --disable-doc --disable-debug --disable-avdevice --disable-symver \
  --disable-programs --disable-shared --enable-static --disable-gpl --disable-nonfree \
  --enable-zlib --enable-iconv --enable-videotoolbox --enable-audiotoolbox \
  --extra-cflags="-I$PREFIX/include $PLAT_CFLAGS" \
  --extra-ldflags="-L$PREFIX/lib $PLAT_CFLAGS" \
  "${LIBFLAGS[@]}" 2>&1 | tee "$OUT/logs/configure-lgpl.txt"
if [ "${PIPESTATUS[0]}" -ne 0 ]; then
  cp ffbuild/config.log "$OUT/logs/config-lgpl.log" 2>/dev/null
  echo "FAIL  ffmpeg 配置" | tee -a "$REPORT"; cat "$REPORT"; exit 0
fi
if ( make -j"$J" && make install ) > "$OUT/logs/make-lgpl.log" 2>&1; then
  FFLIB="$ROOT/ffi/lib"
  EXTRA="$(PKG_CONFIG_LIBDIR="$FFLIB/pkgconfig:$PREFIX/lib/pkgconfig" pkg-config --static --libs \
            libavformat libavcodec libavfilter libswscale libswresample libavutil)"
  LIBS=()
  for t in $EXTRA; do
    case "$t" in -l*) f="$PREFIX/lib/lib${t#-l}.a"; [ -f "$f" ] && LIBS+=("$f") ;; esac
  done
  LIST="$(printf '%s\n' "${LIBS[@]}" | awk '!s[$0]++')"
  # shellcheck disable=SC2086
  /usr/bin/libtool -static -no_warning_for_no_symbols -o "$OUT/lgpl/lib/libffmpeg.a" \
    "$FFLIB/libavformat.a" "$FFLIB/libavcodec.a" "$FFLIB/libavfilter.a" \
    "$FFLIB/libswscale.a" "$FFLIB/libswresample.a" "$FFLIB/libavutil.a" $LIST > "$OUT/logs/merge-a.log" 2>&1 \
    && echo "OK    libffmpeg.a（LGPL，静态）" | tee -a "$REPORT" \
    || { tail -n 30 "$OUT/logs/merge-a.log"
         # 合并失败也不要白跑：把各个 .a 原样放出来，应用里一个个链接也能用
         mkdir -p "$OUT/lgpl/lib-separate"; cp "$FFLIB"/*.a "$OUT/lgpl/lib-separate/"
         for f in $LIST; do cp "$f" "$OUT/lgpl/lib-separate/"; done
         echo "FAIL  libffmpeg.a 合并（日志 logs/merge-a.log；各个 .a 已放在 lib-separate/）" | tee -a "$REPORT"; }
  cat > "$OUT/lgpl/link-flags.txt" <<FLAGS
链接 libffmpeg.a 时，应用工程里还要加这些（.NET iOS 里写在 NativeReference 的 LinkerFlags）：
-framework VideoToolbox -framework AudioToolbox -framework CoreMedia -framework CoreVideo
-framework CoreFoundation -framework Security -framework Accelerate
-lc++ -lz -liconv -lbz2
FLAGS
else
  tail -n 40 "$OUT/logs/make-lgpl.log"
  echo "FAIL  ffmpeg 编译" | tee -a "$REPORT"
fi

{ echo; echo "--- 启用的外部库 ---"; sed -n '/^External libraries:/,/^$/p' "$OUT/logs/configure-lgpl.txt" 2>/dev/null; } >> "$REPORT"
cat "$REPORT"
