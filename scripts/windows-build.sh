#!/usr/bin/env bash
# 在 GitHub 的 Windows 机器上（MSYS2 / MINGW64 环境）运行。
# 产出两套：
#   out/win-x64/full/bin/ffmpeg.exe、ffprobe.exe   完整版单文件（含 x264、x265，GPL，静态链接，不依赖别的 dll）
#   out/win-x64/lgpl/bin/av*.dll、sw*.dll + 依赖 dll   LGPL 版动态库（不含 x264、x265），给软件里直接调用
set -u -o pipefail

FFVER="${FFMPEG_VERSION:-8.1.3}"
ROOT="$PWD/build/win-x64"
OUT="$PWD/out/win-x64"
J="$(nproc)"
mkdir -p "$ROOT" "$OUT/full/bin" "$OUT/lgpl/bin" "$OUT/logs"
REPORT="$OUT/dep-report.txt"
: > "$REPORT"

git clone --depth 1 --branch "n$FFVER" https://github.com/FFmpeg/FFmpeg.git "$ROOT/ffmpeg" \
  || { echo "下载 FFmpeg n$FFVER 失败（版本号对不对？）"; exit 1; }

# ---- MSYS2 仓库里没有的三个库（vmaf、rist、chromaprint），从源码编，装进 /mingw64 ----
WSRC="$ROOT/wsrc"; mkdir -p "$WSRC"
wfetch() { # 网址 目录名
  local url="$1" name="$2" f="$WSRC/$2.dl"
  curl -fL --retry 5 --retry-all-errors -o "$f" "$url" && rm -rf "$WSRC/$name" && mkdir -p "$WSRC/$name" \
    && tar -xf "$f" --strip-components=1 -C "$WSRC/$name"
}
wtry() { # 名字 函数：失败只记录，不中断
  local n="$1"; shift
  ( set -e; "$@" ) > "$OUT/logs/dep-$n.log" 2>&1
  local rc=$?
  if [ $rc -eq 0 ]; then echo "OK    ${n}（源码编译）" | tee -a "$REPORT"
  else echo "FAIL  ${n}（日志 logs/dep-${n}.log）" | tee -a "$REPORT"; tail -n 20 "$OUT/logs/dep-$n.log"; fi
}
wdep_vmaf() {
  wfetch "https://github.com/Netflix/vmaf/archive/refs/tags/v3.0.0.tar.gz" vmaf
  cd "$WSRC/vmaf/libvmaf"
  meson setup _b --prefix=/mingw64 --libdir=lib --buildtype=release --default-library=static \
    -Denable_tests=false -Denable_docs=false -Dbuilt_in_models=true -Denable_float=true
  ninja -C _b install
}
wdep_librist() {
  wfetch "https://code.videolan.org/rist/librist/-/archive/v0.2.10/librist-v0.2.10.tar.gz" librist
  cd "$WSRC/librist"
  # mingw 的 winpthreads 已经提供了 clock_gettime，librist 自带的垫片又定义了一遍，冲突。把垫片里那个改成不对外的
  sed -i 's/^int clock_gettime(clockid_t clock_id, struct timespec \*tp)/static int rist_shim_clock_gettime(clockid_t clock_id, struct timespec *tp)/' contrib/time-shim.c
  meson setup _b --prefix=/mingw64 --libdir=lib --buildtype=release --default-library=static -Dbuilt_tools=false -Dtest=false
  ninja -C _b install
}
wdep_chromaprint() {
  wfetch "https://github.com/acoustid/chromaprint/releases/download/v1.5.1/chromaprint-1.5.1.tar.gz" chromaprint
  wfetch "https://github.com/mborgerding/kissfft/archive/refs/heads/master.tar.gz" kissfft
  mkdir -p "$WSRC/kissfft/tools"; cp "$WSRC/kissfft/kiss_fftr.c" "$WSRC/kissfft/kiss_fftr.h" "$WSRC/kissfft/tools/"
  cd "$WSRC/chromaprint"
  cmake -S . -B _b -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/mingw64 -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_TOOLS=OFF -DBUILD_TESTS=OFF -DFFT_LIB=kissfft -DKISSFFT_SOURCE_DIR="$WSRC/kissfft" -DCMAKE_POLICY_VERSION_MINIMUM=3.5
  cmake --build _b && cmake --install _b
}
wtry vmaf wdep_vmaf
wtry librist wdep_librist
wtry chromaprint wdep_chromaprint

# 两套都能用的库：清单和安卓共用 scripts/libflags.sh，保证功能一致
LIBDIR=/mingw64/lib; USE_MBEDTLS=0
# shellcheck source=libflags.sh
source "$(dirname "$0")/libflags.sh"

# Windows 专有的硬件加速（对界面来说和安卓的 MediaCodec 是同一个"硬件"开关）
HW=(--enable-d3d11va --enable-dxva2 --enable-mediafoundation --enable-schannel)
have ffnvcodec && HW+=(--enable-cuda --enable-cuvid --enable-nvenc --enable-nvdec --enable-ffnvcodec)
have vpl && HW+=(--enable-libvpl)
[ -f /mingw64/include/AMF/core/Factory.h ] && HW+=(--enable-amf)

COMMON=(--arch=x86_64 --target-os=mingw32 --extra-cflags=-DCHROMAPRINT_NODLL --extra-libs=-lstdc++ --disable-autodetect --disable-doc --disable-debug --disable-avdevice
        --enable-zlib --enable-bzlib --enable-lzma --enable-iconv --pkg-config-flags=--static)

ff_conf() { # 名字 额外参数...
  local name="$1"; shift
  rm -rf "$ROOT/ffb-$name"; mkdir -p "$ROOT/ffb-$name"; cd "$ROOT/ffb-$name" || return 1
  "$ROOT/ffmpeg/configure" --prefix="$ROOT/ffi-$name" "${COMMON[@]}" "${LIBFLAGS[@]}" "${HW[@]}" "$@" 2>&1 \
    | tee "$OUT/logs/configure-$name.txt"
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

# ---- 完整版：优先做成单个 exe（全部静态链接）；静态链接配不通就改成"exe + 它依赖的 dll" ----
FULL_COMMON=(--enable-gpl --disable-shared --enable-static)
have x264 && FULL_COMMON+=(--enable-libx264)
have x265 && FULL_COMMON+=(--enable-libx265)
full_done=0
if ff_conf full "${FULL_COMMON[@]}" --extra-ldflags=-static --extra-libs="-lstdc++ -liconv -lm" && ff_build full; then
  full_done=1
  echo "OK    ffmpeg完整版（exe，静态单文件）" | tee -a "$REPORT"
else
  echo "静态单文件配置/编译失败，改用动态依赖（exe + dll）重试" | tee -a "$REPORT"
  if ff_conf full "${FULL_COMMON[@]}" --extra-libs="-liconv" && ff_build full; then
    full_done=1
    echo "OK    ffmpeg完整版（exe + 依赖 dll）" | tee -a "$REPORT"
  else
    echo "FAIL  ffmpeg完整版（exe）" | tee -a "$REPORT"
  fi
fi
if [ "$full_done" = 1 ]; then
  cp "$ROOT/ffi-full/bin/ffmpeg.exe" "$ROOT/ffi-full/bin/ffprobe.exe" "$OUT/full/bin/"
  for e in "$OUT"/full/bin/*.exe; do
    ldd "$e" | awk '/\/mingw64\/bin\//{print $3}'
  done | sort -u | while read -r f; do cp -n "$f" "$OUT/full/bin/"; done
  strip --strip-unneeded "$OUT"/full/bin/*.exe 2>/dev/null || true
fi

# ---- LGPL 版：动态库 + 它们依赖的 dll ----
if ff_conf lgpl --disable-gpl --disable-nonfree --enable-shared --disable-static --disable-programs --extra-libs=-liconv \
   && ff_build lgpl; then
  cp "$ROOT"/ffi-lgpl/bin/*.dll "$OUT/lgpl/bin/"
  for d in "$OUT"/lgpl/bin/av*.dll "$OUT"/lgpl/bin/sw*.dll; do
    ldd "$d" | awk '/\/mingw64\/bin\//{print $3}'
  done | sort -u | while read -r f; do cp -n "$f" "$OUT/lgpl/bin/"; done
  strip --strip-unneeded "$OUT"/lgpl/bin/*.dll 2>/dev/null || true
  echo "OK    ffmpeg LGPL 动态库" | tee -a "$REPORT"
else
  echo "FAIL  ffmpeg LGPL 动态库" | tee -a "$REPORT"
fi

for n in full lgpl; do
  { echo; echo "--- $n 启用的外部库 ---"; sed -n '/^External libraries:/,/^$/p' "$OUT/logs/configure-$n.txt" 2>/dev/null; } >> "$REPORT"
done
cat "$REPORT"
