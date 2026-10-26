#!/usr/bin/env bash
#
# 为 Android 交叉编译 LuaJIT（含 lovely 注入层），产出可直接给 love-android 使用的
# libluajit.a。和 build_android.ps1 等价，只是跑在 Linux/macOS 上。
#
# 用法：  ./build_android.sh [arm64-v8a|x86_64]
# 依赖：  ANDROID_NDK_HOME 指向 NDK 25.2.9519653、gcc、make、cargo + nightly
#
# 流程：make 自己用 HOST_CC 编出 minilua/buildvm → 生成头 → 交叉编译 libluajit.a
#       → cargo 编 liblovely.a → 合并成一个归档
#
set -euo pipefail

ABI="${1:-arm64-v8a}"
API="${API:-21}"

case "$ABI" in
  arm64-v8a) TRIPLE="aarch64-linux-android" ;;
  x86_64)    TRIPLE="x86_64-linux-android"  ;;
  *) echo "ERROR: 不支持的 ABI: $ABI（只支持 arm64-v8a / x86_64）" >&2; exit 1 ;;
esac

NDK="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}"
[ -n "$NDK" ] || { echo "ERROR: 请设置 ANDROID_NDK_HOME" >&2; exit 1; }

# NDK 的 host tag：Linux 是 linux-x86_64，macOS 是 darwin-x86_64
case "$(uname -s)" in
  Darwin) HOST_TAG="darwin-x86_64" ;;
  *)      HOST_TAG="linux-x86_64"  ;;
esac

TC="$NDK/toolchains/llvm/prebuilt/$HOST_TAG/bin"
CC_BIN="$TC/${TRIPLE}${API}-clang"
AR_BIN="$TC/llvm-ar"

[ -x "$CC_BIN" ] || { echo "ERROR: 找不到 NDK clang: $CC_BIN" >&2; exit 1; }

ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="$ROOT/src"
LOVELY="$ROOT/module/lovely"
OUT="$ROOT/android/$ABI"

echo "==> ABI=$ABI  TRIPLE=$TRIPLE  NDK=$NDK"

# ---------------------------------------------------------------- 清理
# 换 ABI 必须清掉上次的目标文件，否则 make 会复用旧 ABI 的 .o
echo "==> 清理旧产物"
( cd "$SRC" && make clean >/dev/null 2>&1 || true )
rm -rf "$SRC"/*.o "$SRC"/libluajit*.a "$SRC"/lj_vm.S "$SRC"/host/buildvm_arch.h

# ---------------------------------------------------------------- LuaJIT
echo "==> 交叉编译 LuaJIT（amalg / static）"
cd "$SRC"
git show -s --format=%ct > luajit_relver.txt

# make all 最后会尝试交叉链接 luajit 可执行文件，那一步必然失败；
# libluajit.a 在此之前已经产出，所以这里容忍非 0 退出，之后自己检查产物。
set +e
make all LJCORE_O=ljamalg.o BUILDMODE=static \
  HOST_CC="gcc -m64" \
  STATIC_CC="$CC_BIN -fPIC" \
  TARGET_AR="$AR_BIN rcus" \
  TARGET_STRIP= \
  TARGET_SYS=Linux \
  HOST_SYS=Linux
set -e
[ -f libluajit.a ] || { echo "ERROR: libluajit.a 未生成" >&2; exit 1; }

# ---------------------------------------------------------------- lovely
echo "==> 交叉编译 liblovely（cargo，$TRIPLE）"
UPPER="$(echo "$TRIPLE" | tr 'a-z-' 'A-Z_')"
UNDER="$(echo "$TRIPLE" | tr '-' '_')"
export "CARGO_TARGET_${UPPER}_LINKER=$CC_BIN"
export "CC_${UNDER}=$CC_BIN"
export "CXX_${UNDER}=${TC}/${TRIPLE}${API}-clang++"
export "AR_${UNDER}=$AR_BIN"
export "RANLIB_${UNDER}=$TC/llvm-ranlib"

( cd "$LOVELY" && cargo build -p liblovely --release --target "$TRIPLE" )

LOVELY_LIB="$LOVELY/target/$TRIPLE/release/liblovely.a"
[ -f "$LOVELY_LIB" ] || { echo "ERROR: 找不到 liblovely.a: $LOVELY_LIB" >&2; exit 1; }

# ---------------------------------------------------------------- 合并
# ljamalg.o 引用 Rust 的 lovely_init/lovely_apply_patches，Rust 侧又回头引用
# lovely_loadbufferx，分两个归档放需要 --start-group，所以合并成一个。
echo "==> 合并 liblovely 进 libluajit.a"
cd "$SRC"
"$AR_BIN" -M <<EOF
create libluajit-merged.a
addlib libluajit.a
addlib $LOVELY_LIB
save
end
EOF
[ -f libluajit-merged.a ] || { echo "ERROR: 合并失败" >&2; exit 1; }

# ---------------------------------------------------------------- 输出
echo "==> 输出到 android/$ABI"
mkdir -p "$OUT/jit"
cp libluajit-merged.a "$OUT/libluajit.a"
cp luajit.h "$OUT/luajit.h"
cp jit/*.lua "$OUT/jit/" 2>/dev/null || true

SIZE="$(du -h "$OUT/libluajit.a" | cut -f1)"
echo "完成：$OUT/libluajit.a ($SIZE)"
echo "关键符号："
"$TC/llvm-nm" "$OUT/libluajit.a" 2>/dev/null |
  grep -E " T (luaL_loadbufferx|lovely_loadbufferx|lovely_init|lovely_apply_patches)$" || true
