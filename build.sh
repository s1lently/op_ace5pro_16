#!/usr/bin/env bash
# build.sh — OnePlus Ace 5 Pro (SM8750) kernel build script
# Supports: macOS arm64 (OrbStack) + WSL/Linux x86_64
set -e

KERNEL_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE="$(dirname "$(dirname "$KERNEL_DIR")")"   # kernel_workspace/
PLATFORM_DIR="$(dirname "$KERNEL_DIR")"             # kernel_platform/
OUT_DIR="$KERNEL_DIR/out"
JOBS=$(nproc 2>/dev/null || sysctl -n hw.ncpu)

# ── 颜色输出 ──────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[build]${NC} $*"; }
warn() { echo -e "${YELLOW}[warn]${NC} $*"; }
die()  { echo -e "${RED}[error]${NC} $*"; exit 1; }

# ── 检测平台 ──────────────────────────────────────────────────
ARCH=$(uname -m)
log "Host: $(uname -s) $ARCH"

if [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]]; then
    PLATFORM="arm64"
else
    PLATFORM="x86_64"
fi

# ── 工具链路径 ────────────────────────────────────────────────
CLANG_PREBUILT="$PLATFORM_DIR/prebuilts/clang/host/linux-x86/clang-r510928/bin"
AOSP_CLANG_ARM64="$HOME/aosp-clang-r510928/bin"
AOSP_CLANG_ARM64_RELEASE="https://github.com/s1lently/llvm-project/releases/download/r510928-arm64/aosp-clang-r510928-arm64-kernel.tar.gz"

if [[ "$PLATFORM" == "arm64" ]]; then
    # macOS arm64 / OrbStack: 用我们编译的 arm64 原生 Clang
    if [[ ! -f "$AOSP_CLANG_ARM64/clang" ]]; then
        warn "arm64 AOSP Clang not found at $AOSP_CLANG_ARM64"
        log "Downloading from GitHub release..."
        curl -L "$AOSP_CLANG_ARM64_RELEASE" -o /tmp/aosp-clang.tar.gz
        rm -rf "$HOME/aosp-clang-r510928" "$HOME/clang-kernel-only"
        tar xzf /tmp/aosp-clang.tar.gz -C "$HOME"
        mv "$HOME/clang-kernel-only" "$HOME/aosp-clang-r510928"
        log "Clang installed to $AOSP_CLANG_ARM64"
    fi
    export PATH="$AOSP_CLANG_ARM64:$PATH"
    PAHOLE_CMD="pahole"   # 系统 dwarves
else
    # WSL / Linux x86_64: 用 prebuilts 里的 x86_64 AOSP Clang
    if [[ ! -f "$CLANG_PREBUILT/clang" ]]; then
        die "Clang not found at $CLANG_PREBUILT\nRun repo sync first."
    fi
    export PATH="$CLANG_PREBUILT:$PATH"
    PAHOLE_BIN="$PLATFORM_DIR/prebuilts/kernel-build-tools/linux-x86/bin/pahole"
    if [[ -f "$PAHOLE_BIN" ]]; then
        PAHOLE_CMD="$PAHOLE_BIN"
    else
        PAHOLE_CMD="pahole"
    fi
fi

log "Clang: $(clang --version | head -1)"
log "Jobs: $JOBS"

# ── 依赖检查 ──────────────────────────────────────────────────
for cmd in make bc flex bison cpio pahole; do
    command -v $cmd &>/dev/null || die "Missing: $cmd (apt install $cmd)"
done

# ── 配置 ──────────────────────────────────────────────────────
log "Configuring kernel..."
mkdir -p "$OUT_DIR"
cp "$KERNEL_DIR/stock_defconfig" "$OUT_DIR/.config"

# 5 项必要修改 (see BUILD_GUIDE.md)
sed -i 's/CONFIG_LOCALVERSION_AUTO=y/# CONFIG_LOCALVERSION_AUTO is not set/' "$OUT_DIR/.config"
sed -i 's/CONFIG_LOCALVERSION="-4k"/CONFIG_LOCALVERSION="-android15-8-o-4k"/'  "$OUT_DIR/.config"
sed -i 's/CONFIG_TRIM_UNUSED_KSYMS=y/# CONFIG_TRIM_UNUSED_KSYMS is not set/'   "$OUT_DIR/.config"
sed -i '/CONFIG_UNUSED_KSYMS_WHITELIST/d'                                        "$OUT_DIR/.config"
sed -i 's/CONFIG_MODULE_SIG_PROTECT=y/# CONFIG_MODULE_SIG_PROTECT is not set/'  "$OUT_DIR/.config"
sed -i 's/CONFIG_MODULE_SCMVERSION=y/# CONFIG_MODULE_SCMVERSION is not set/'    "$OUT_DIR/.config"

# arm64 kernel-only clang 缺 host headers, 必须用系统 gcc 编译 host 工具
if [[ "$PLATFORM" == "arm64" ]]; then
    HOST_OPTS="HOSTCC=gcc HOSTCXX=g++"
else
    HOST_OPTS=""
fi

make -j"$JOBS" LLVM=1 ARCH=arm64 CC=clang LD=ld.lld HOSTLD=ld.lld \
    $HOST_OPTS PAHOLE="$PAHOLE_CMD" O=out olddefconfig

# ── 编译 ──────────────────────────────────────────────────────
log "Building kernel with $JOBS threads..."
make -j"$JOBS" LLVM=1 ARCH=arm64 CC=clang LD=ld.lld HOSTLD=ld.lld \
    $HOST_OPTS PAHOLE="$PAHOLE_CMD" O=out all

IMAGE="$OUT_DIR/arch/arm64/boot/Image"
[[ -f "$IMAGE" ]] || die "Build failed: Image not generated"
SIZE=$(du -sh "$IMAGE" | cut -f1)
log "✓ Image: $IMAGE ($SIZE)"
log "vermagic: $(strings "$IMAGE" | grep 'Linux version' | head -1)"
