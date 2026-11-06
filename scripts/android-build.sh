#!/usr/bin/env bash
# 用法：bash scripts/android-build.sh android-arm64     （或 android-x86_64）
#
# 做三件事：
#   1) 把所有外部库（x264、x265、字幕、AV1……）从源码交叉编译成 Android 版
#   2) 编"完整版"：ffmpeg / ffprobe 可执行文件（含 x264、x265，GPL）
#   3) 编"LGPL 版"：合并成一个 libffmpeg.so（不含 x264、x265），给软件里直接调用
#
# 每个外部库单独编，某一个失败不会拖垮整体——ffmpeg 只会启用"编成功了"的库，
# 成功/失败清单写在 out/<目标>/dep-report.txt 里。
set -u -o pipefail

TARGET="${1:?缺少参数：android-arm64 或 android-x86_64}"
FFVER="${FFMPEG_VERSION:-8.1.3}"
API=24                                   # 和 ZUI.Android.csproj 的最低版本 24 保持一致
NDK="${ANDROID_NDK_HOME:?没有找到 ANDROID_NDK_HOME}"
TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/linux-x86_64"
J="$(nproc)"

case "$TARGET" in
  android-arm64)  TRIPLE=aarch64-linux-android; ABI=arm64-v8a; ARCH=aarch64; MFAMILY=aarch64; MCPU=armv8-a; VPXTARGET=arm64-linux-gcc ;;
  android-x86_64) TRIPLE=x86_64-linux-android;  ABI=x86_64;    ARCH=x86_64;  MFAMILY=x86_64;  MCPU=x86_64;  VPXTARGET=x86_64-linux-gcc ;;
  *) echo "不认识的目标：$TARGET"; exit 1 ;;
esac

PLATFORM=android
PLAT_CFLAGS=""
ROOT="$PWD/build/$TARGET"
SRC="$ROOT/src"
PREFIX="$ROOT/prefix"
OUT="$PWD/out/$TARGET"
mkdir -p "$SRC" "$PREFIX/lib/pkgconfig" "$OUT/full/bin" "$OUT/lgpl/lib" "$OUT/logs"
REPORT="$OUT/dep-report.txt"
: > "$REPORT"

export CC="$TOOLCHAIN/bin/${TRIPLE}${API}-clang"
export CXX="$TOOLCHAIN/bin/${TRIPLE}${API}-clang++"
export AR="$TOOLCHAIN/bin/llvm-ar"
export RANLIB="$TOOLCHAIN/bin/llvm-ranlib"
export NM="$TOOLCHAIN/bin/llvm-nm"
export STRIP="$TOOLCHAIN/bin/llvm-strip"
export LD="$CC"
# 先确认 NDK 的编译器真的能用（上次就是 NDK 缓存坏了，clang 不见了，导致后面全部失败）
"$CC" --version >/dev/null 2>&1 || { echo "NDK 编译器不可用：$CC"; ls -la "$TOOLCHAIN/bin" | head -40; exit 1; }
export CFLAGS="-O2 -fPIC"
export CXXFLAGS="-O2 -fPIC"
export CPPFLAGS="-I$PREFIX/include"
export LDFLAGS="-L$PREFIX/lib"
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
unset PKG_CONFIG_PATH

CMAKE_BASE=(
  -G Ninja
  -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake"
  -DANDROID_ABI="$ABI" -DANDROID_PLATFORM="android-$API"
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_INSTALL_LIBDIR=lib
  -DCMAKE_PREFIX_PATH="$PREFIX" -DCMAKE_FIND_ROOT_PATH="$PREFIX"
  -DBUILD_SHARED_LIBS=OFF -DCMAKE_POSITION_INDEPENDENT_CODE=ON
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5
)

cat > "$ROOT/meson-cross.txt" <<MESON
[binaries]
c = '$CC'
cpp = '$CXX'
ar = '$AR'
strip = '$STRIP'
pkg-config = 'pkg-config'
[host_machine]
system = 'android'
cpu_family = '$MFAMILY'
cpu = '$MCPU'
endian = 'little'
[built-in options]
c_args = ['-O2', '-fPIC', '-I$PREFIX/include']
cpp_args = ['-O2', '-fPIC', '-I$PREFIX/include']
c_link_args = ['-L$PREFIX/lib']
cpp_link_args = ['-L$PREFIX/lib']
[properties]
needs_exe_wrapper = true
pkg_config_libdir = '$PREFIX/lib/pkgconfig'
MESON

# 安卓没有独立的 librt / libpthread（都在系统库里），有些库的构建会硬写 -lrt / -lpthread，放两个空库顶替
rm -f "$PREFIX/lib/librt.a" "$PREFIX/lib/libpthread.a"
"$AR" rc "$PREFIX/lib/librt.a" 2>/dev/null || true
"$AR" rc "$PREFIX/lib/libpthread.a" 2>/dev/null || true
X264_CFG=(--cross-prefix="$TOOLCHAIN/bin/llvm-")
merge_static() { # 输出 输入...：把几个 .a 合成一个
  local o="$1"; shift
  { echo "CREATE $o"; for f in "$@"; do echo "ADDLIB $f"; done; echo SAVE; echo END; } | "$AR" -M
}
# shellcheck source=deps.sh
source "$(dirname "$0")/deps.sh"
run_deps

# 这些库的 .pc 里写着 -lstdc++，Android 上不用，去掉（C++ 运行库在最后链接时静态带上）
# 安卓没有单独的 libpthread/librt（都在系统库里），.pc 里写了会导致链接失败，一并去掉
sed -i 's/-lstdc++//g; s/-lpthread//g; s/-lrt//g; s/-l-l:libunwind.a//g' "$PREFIX"/lib/pkgconfig/*.pc 2>/dev/null || true

# ---------------- 决定 ffmpeg 启用哪些库（只启用编成功的；清单和 Windows 共用 scripts/libflags.sh） ----------------
LIBDIR="$PREFIX/lib"; USE_MBEDTLS=1
# shellcheck source=libflags.sh
source "$(dirname "$0")/libflags.sh"

# ---------------- ffmpeg 源码 ----------------
rm -rf "$SRC/ffmpeg"
git clone --depth 1 --branch "n$FFVER" https://github.com/FFmpeg/FFmpeg.git "$SRC/ffmpeg" || { echo "下载 FFmpeg n$FFVER 失败（版本号对不对？）"; exit 1; }
unset CFLAGS CXXFLAGS CPPFLAGS LDFLAGS

ff_conf() { # 名字 额外参数...
  local name="$1"; shift
  rm -rf "$ROOT/ffb-$name"; mkdir -p "$ROOT/ffb-$name"; cd "$ROOT/ffb-$name" || return 1
  "$SRC/ffmpeg/configure" --prefix="$ROOT/ffi-$name" \
    --enable-cross-compile --target-os=android --arch="$ARCH" \
    --cc="$CC" --cxx="$CXX" --ld="$CXX" --ar="$AR" --nm="$NM" --ranlib="$RANLIB" --strip="$STRIP" \
    --pkg-config=pkg-config --pkg-config-flags=--static \
    --enable-pic --disable-autodetect --disable-doc --disable-debug --disable-avdevice --disable-symver \
    --enable-zlib --enable-jni --enable-mediacodec --extra-libs=-llog \
    --extra-cflags="-I$PREFIX/include -fPIC" \
    --extra-ldflags="-L$PREFIX/lib -static-libstdc++ -Wl,-z,max-page-size=16384" \
    "${LIBFLAGS[@]}" "$@" 2>&1 | tee "$OUT/logs/configure-$name.txt"
  local rc="${PIPESTATUS[0]}"
  [ "$rc" -eq 0 ] || cp ffbuild/config.log "$OUT/logs/config-$name.log" 2>/dev/null
  return "$rc"
}

ff_build() { # 名字：编译并安装，日志存到 logs/make-名字.log，失败时在屏幕上显示最后 40 行
  local name="$1"
  ( make -C "$ROOT/ffb-$name" -j"$J" && make -C "$ROOT/ffb-$name" install ) > "$OUT/logs/make-$name.log" 2>&1
  local rc=$?
  [ "$rc" -eq 0 ] || tail -n 40 "$OUT/logs/make-$name.log"
  return "$rc"
}

# ---------------- 第一套：完整版可执行文件（GPL，含 x264/x265） ----------------
FULL=(--enable-gpl --disable-shared --enable-static)
have x264 && FULL+=(--enable-libx264)
have x265 && FULL+=(--enable-libx265)
if ff_conf full "${FULL[@]}" && ff_build full; then
  cp "$ROOT/ffi-full/bin/ffmpeg" "$ROOT/ffi-full/bin/ffprobe" "$OUT/full/bin/"
  "$STRIP" --strip-unneeded "$OUT/full/bin/"*
  echo "OK    ffmpeg完整版（可执行文件）" | tee -a "$REPORT"
else
  echo "FAIL  ffmpeg完整版（可执行文件）" | tee -a "$REPORT"
fi

# ---------------- 第二套：LGPL 版，合并成一个 libffmpeg.so ----------------
if ff_conf lgpl --disable-gpl --disable-nonfree --disable-programs --disable-shared --enable-static \
   && ff_build lgpl; then
  FFLIB="$ROOT/ffi-lgpl/lib"
  EXTRA="$(PKG_CONFIG_LIBDIR="$FFLIB/pkgconfig:$PREFIX/lib/pkgconfig" pkg-config --static --libs \
            libavformat libavcodec libavfilter libswscale libswresample libavutil)"
  # shellcheck disable=SC2086
  "$CXX" -shared -o "$OUT/lgpl/lib/libffmpeg.so" -Wl,-soname,libffmpeg.so \
    -static-libstdc++ -Wl,-z,max-page-size=16384 -Wl,--allow-multiple-definition -Wl,-Bsymbolic \
    -Wl,--whole-archive "$FFLIB/libavformat.a" "$FFLIB/libavcodec.a" "$FFLIB/libavfilter.a" \
      "$FFLIB/libswscale.a" "$FFLIB/libswresample.a" "$FFLIB/libavutil.a" -Wl,--no-whole-archive \
    $EXTRA -landroid -llog -lmediandk -lm -lz -ldl > "$OUT/logs/merge-so.log" 2>&1 \
    && "$STRIP" --strip-unneeded "$OUT/lgpl/lib/libffmpeg.so" \
    && echo "OK    libffmpeg.so（LGPL）" | tee -a "$REPORT" \
    || { tail -n 30 "$OUT/logs/merge-so.log"; echo "FAIL  libffmpeg.so 合并链接（日志 logs/merge-so.log）" | tee -a "$REPORT"; }
else
  echo "FAIL  ffmpeg LGPL 版配置/编译" | tee -a "$REPORT"
fi

# ---------------- 第三套：标准的分开的 .so（libavcodec.so 这类，名字不带版本号） ----------------
if ff_conf shared --disable-gpl --disable-nonfree --disable-programs --enable-shared --disable-static; then
  # 把"带版本号的库名"改成"不带版本号"，Android 打包才认
  sed -i.bak -e 's|^SLIBNAME_WITH_MAJOR=.*|SLIBNAME_WITH_MAJOR=$(SLIBNAME)|' \
             -e 's|^SLIB_INSTALL_NAME=.*|SLIB_INSTALL_NAME=$(SLIBNAME)|' \
             -e 's|^SLIB_INSTALL_LINKS=.*|SLIB_INSTALL_LINKS=|' "$ROOT/ffb-shared/ffbuild/config.mak"
  if ff_build shared \
     && ls "$ROOT/ffi-shared/lib/libavcodec.so" >/dev/null 2>&1; then
    mkdir -p "$OUT/lgpl-split/$ABI"
    cp "$ROOT"/ffi-shared/lib/lib{avutil,swresample,swscale,avcodec,avformat,avfilter}.so "$OUT/lgpl-split/$ABI/"
    "$STRIP" --strip-unneeded "$OUT/lgpl-split/$ABI/"*.so
    echo "OK    分开的 .so（LGPL）" | tee -a "$REPORT"
  else
    echo "FAIL  分开的 .so 编译/改名" | tee -a "$REPORT"
  fi
else
  echo "FAIL  分开的 .so 配置" | tee -a "$REPORT"
fi

# ---------------- 汇总：两套各启用了哪些外部库 ----------------
for n in full lgpl shared; do
  { echo; echo "--- $n 启用的外部库 ---"; sed -n '/^External libraries:/,/^$/p' "$OUT/logs/configure-$n.txt" 2>/dev/null; } >> "$REPORT"
done
cat "$REPORT"
