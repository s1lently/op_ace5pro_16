#!/usr/bin/env bash
# build.sh — OnePlus Ace 5 Pro (SM8750) kernel build script
# Usage:
#   mkdir -p kernel_workspace/kernel_platform
#   git clone https://github.com/s1lently/op_ace5pro_16 kernel_workspace/kernel_platform/common
#   cd kernel_workspace/kernel_platform/common && bash build.sh
#
# Supports: arm64 Linux (OrbStack/native) + x86_64 Linux (WSL/native)
set -e

KERNEL_DIR="$(cd "$(dirname "$0")" && pwd)"
PLATFORM_DIR="$(dirname "$KERNEL_DIR")"             # kernel_platform/
WORKSPACE="$(dirname "$PLATFORM_DIR")"              # kernel_workspace/
OUT_DIR="$KERNEL_DIR/out"
JOBS=$(nproc 2>/dev/null || sysctl -n hw.ncpu)

# ── GitHub release URLs ─────────────────────────────────────────
REPO_URL="https://github.com/s1lently/op_ace5pro_16"
EXTRA_URL="$REPO_URL/releases/download/v1.0-source/kernel_workspace_extra.tar.gz"
VENDOR_URL="$REPO_URL/releases/download/v1.0-source/kernel_vendor.tar.gz"
CLANG_ARM64_URL="https://github.com/s1lently/llvm-project/releases/download/r510928-arm64/aosp-clang-r510928-arm64-kernel.tar.gz"

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

# ── 依赖检查 ──────────────────────────────────────────────────
MISSING=()
for cmd in make bc flex bison cpio gcc g++ curl; do
    command -v $cmd &>/dev/null || MISSING+=("$cmd")
done
# pahole: verify it actually works (not a stale wrapper)
if ! pahole --version &>/dev/null; then
    MISSING+=("pahole")
fi
if [[ ${#MISSING[@]} -gt 0 ]]; then
    log "Installing missing dependencies: ${MISSING[*]}"
    if command -v apt-get &>/dev/null; then
        apt-get update -qq && apt-get install -y -qq \
            build-essential bc flex bison cpio dwarves libssl-dev python3 curl 2>&1 | tail -1
    else
        die "Missing: ${MISSING[*]}. Install them manually."
    fi
fi

# ── 工作区自动恢复 ────────────────────────────────────────────
# 检查 msm-kernel 是否存在，不存在则从 release 下载
if [[ ! -d "$PLATFORM_DIR/msm-kernel" ]]; then
    log "msm-kernel not found, downloading workspace components..."
    curl -L "$EXTRA_URL" -o /tmp/kernel_workspace_extra.tar.gz
    tar xzf /tmp/kernel_workspace_extra.tar.gz -C "$PLATFORM_DIR/"
    rm -f /tmp/kernel_workspace_extra.tar.gz
    log "✓ Extracted msm-kernel, oplus, qcom, external, tools"
fi

if [[ ! -d "$WORKSPACE/vendor" ]]; then
    log "vendor modules not found, downloading..."
    curl -L "$VENDOR_URL" -o /tmp/kernel_vendor.tar.gz
    tar xzf /tmp/kernel_vendor.tar.gz -C "$WORKSPACE/"
    rm -f /tmp/kernel_vendor.tar.gz
    log "✓ Extracted vendor modules"
fi

# ── 工具链 ────────────────────────────────────────────────────
CLANG_PREBUILT="$PLATFORM_DIR/prebuilts/clang/host/linux-x86/clang-r510928/bin"
AOSP_CLANG_ARM64="$HOME/aosp-clang-r510928/bin"

if [[ "$PLATFORM" == "arm64" ]]; then
    if [[ ! -f "$AOSP_CLANG_ARM64/clang" ]]; then
        log "Downloading arm64 Clang from GitHub release..."
        curl -L "$CLANG_ARM64_URL" -o /tmp/aosp-clang.tar.gz
        rm -rf "$HOME/aosp-clang-r510928" "$HOME/clang-kernel-only"
        tar xzf /tmp/aosp-clang.tar.gz -C "$HOME"
        mv "$HOME/clang-kernel-only" "$HOME/aosp-clang-r510928"
        rm -f /tmp/aosp-clang.tar.gz
        log "✓ Clang installed to $AOSP_CLANG_ARM64"
    fi
    export PATH="$AOSP_CLANG_ARM64:$PATH"
    PAHOLE_CMD="pahole"
else
    if [[ ! -f "$CLANG_PREBUILT/clang" ]]; then
        die "x86_64 Clang not found at $CLANG_PREBUILT\nRun repo sync for AOSP prebuilts, or use arm64 Linux."
    fi
    export PATH="$CLANG_PREBUILT:$PATH"
    PAHOLE_BIN="$PLATFORM_DIR/prebuilts/kernel-build-tools/linux-x86/bin/pahole"
    PAHOLE_CMD="${PAHOLE_BIN:-pahole}"
    [[ -f "$PAHOLE_CMD" ]] || PAHOLE_CMD="pahole"
fi

log "Clang: $(clang --version | head -1)"
log "Jobs: $JOBS"

# ── 配置 ──────────────────────────────────────────────────────
log "Configuring kernel..."
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"
cp "$KERNEL_DIR/stock_defconfig" "$OUT_DIR/.config"

# 5 项必要修改
sed -i 's/CONFIG_LOCALVERSION_AUTO=y/# CONFIG_LOCALVERSION_AUTO is not set/' "$OUT_DIR/.config"
sed -i 's/CONFIG_LOCALVERSION="-4k"/CONFIG_LOCALVERSION="-android15-8-o-4k"/'  "$OUT_DIR/.config"
sed -i 's/CONFIG_TRIM_UNUSED_KSYMS=y/# CONFIG_TRIM_UNUSED_KSYMS is not set/'   "$OUT_DIR/.config"
sed -i '/CONFIG_UNUSED_KSYMS_WHITELIST/d'                                        "$OUT_DIR/.config"
sed -i 's/CONFIG_MODULE_SIG_PROTECT=y/# CONFIG_MODULE_SIG_PROTECT is not set/'  "$OUT_DIR/.config"
sed -i 's/CONFIG_MODULE_SCMVERSION=y/# CONFIG_MODULE_SCMVERSION is not set/'    "$OUT_DIR/.config"

make -j"$JOBS" LLVM=1 ARCH=arm64 CC=clang LD=ld.lld HOSTLD=ld.lld \
    PAHOLE="$PAHOLE_CMD" O=out olddefconfig

# ── 编译 ──────────────────────────────────────────────────────
log "Building kernel with $JOBS threads..."
make -j"$JOBS" LLVM=1 ARCH=arm64 CC=clang LD=ld.lld HOSTLD=ld.lld \
    PAHOLE="$PAHOLE_CMD" O=out all

IMAGE="$OUT_DIR/arch/arm64/boot/Image"
[[ -f "$IMAGE" ]] || die "Build failed: Image not generated"
SIZE=$(du -sh "$IMAGE" | cut -f1)
log "✓ Image: $IMAGE ($SIZE)"
log "vermagic: $(strings "$IMAGE" | grep 'Linux version' | head -1)"
