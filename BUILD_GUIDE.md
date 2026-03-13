# OnePlus Ace 5 Pro (SM8750) 内核编译完整记录

## 设备信息
- **设备**: 一加 Ace 5 Pro
- **SoC**: 骁龙 8 Elite (SM8750), 代号 `sun`
- **系统**: OxygenOS 16.0 (Android 16)
- **内核**: Linux 6.6.89, GKI 分支 `android15-6.6`
- **Boot slot**: boot_b (A/B 分区)
- **Root**: SukiSU (KernelSU), magiskboot 位于 `/data/adb/ksu/bin/magiskboot`

---

## 一键编译 (推荐)

```bash
# 1. 克隆完整源码树 (需要 repo 工具)
mkdir kernel_workspace && cd kernel_workspace
repo init -u https://github.com/HanKuCha/kernel_manifest.git \
  -b refs/heads/oneplus/sm8750 \
  -m JiuGeFaCai_oneplus_ace5_pro_v.xml --depth=1

# 用 local_manifests 覆盖: common 换成此仓库, msm-kernel 换成 OxygenOS 16 分支
mkdir -p .repo/local_manifests
cat > .repo/local_manifests/custom.xml << 'XML'
<?xml version="1.0" encoding="UTF-8"?>
<manifest>
  <remote fetch="https://github.com/s1lently" name="s1lently"/>
  <remove-project name="android_kernel_common_oneplus_sm8750" />
  <project remote="s1lently" name="op_ace5pro_16" path="kernel_platform/common" revision="main" clone-depth="1">
    <linkfile dest="kernel_platform/.source_date_epoch_dir" src="."/>
  </project>
  <remove-project name="android_kernel_oneplus_sm8750" />
  <project remote="origin" name="android_kernel_oneplus_sm8750" path="kernel_platform/msm-kernel" revision="oneplus/sm8750_b_16.0.0_oneplus_ace5_pro" clone-depth="1">
    <linkfile dest="kernel_platform/WORKSPACE" src="bazel.WORKSPACE"/>
    <linkfile dest="kernel_platform/build_with_bazel.py" src="build_with_bazel.py"/>
  </project>
  <remove-project name="android_kernel_modules_and_devicetree_oneplus_sm8750" />
  <project remote="origin" name="android_kernel_modules_and_devicetree_oneplus_sm8750" path="./" revision="oneplus/sm8750_b_16.0.0_oneplus_ace5_pro" clone-depth="1"/>
</manifest>
XML

repo sync -c -j$(nproc) --no-tags --force-sync

# 2. 安装依赖
sudo apt install -y build-essential bc flex bison libssl-dev libelf-dev \
  dwarves cpio lz4 git curl wget python3

# 3. 一键编译 (自动检测平台 + 下载工具链)
cd kernel_platform/common
bash build.sh

# 4. 产出
# out/arch/arm64/boot/Image
```

---

## 编译环境

### macOS arm64 (Apple Silicon + OrbStack) ✅ 已验证
- OrbStack → Ubuntu 22.04 arm64 VM
- 工具链: arm64 原生 AOSP Clang r510928
  - 仓库: https://github.com/s1lently/llvm-project/releases/tag/r510928-arm64
  - `build.sh` 自动下载，无需手动操作
- 编译速度: ~5 分钟 (M 系列 Mac)

### WSL2 / Linux x86_64 ✅ 已验证 (原始方案)
- Ubuntu 24.04 推荐
- 工具链: AOSP Clang r510928 (x86_64 prebuilt，通过 repo sync 自动获取)
  - 路径: `kernel_platform/prebuilts/clang/host/linux-x86/clang-r510928/`
  - 或手动下载: `https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/heads/android15-release/clang-r510928.tar.gz`

---

## 手动编译步骤

### 1. 安装依赖
```bash
sudo apt install -y build-essential bc flex bison libssl-dev libelf-dev \
  dwarves cpio lz4 git curl wget python3
```

### 2. 配置
```bash
cd kernel_platform/common
mkdir -p out
cp stock_defconfig out/.config

# 必须修改的 5 项配置
sed -i 's/CONFIG_LOCALVERSION_AUTO=y/# CONFIG_LOCALVERSION_AUTO is not set/' out/.config
sed -i 's/CONFIG_LOCALVERSION="-4k"/CONFIG_LOCALVERSION="-android15-8-o-4k"/'  out/.config
sed -i 's/CONFIG_TRIM_UNUSED_KSYMS=y/# CONFIG_TRIM_UNUSED_KSYMS is not set/'   out/.config
sed -i '/CONFIG_UNUSED_KSYMS_WHITELIST/d'                                        out/.config
sed -i 's/CONFIG_MODULE_SIG_PROTECT=y/# CONFIG_MODULE_SIG_PROTECT is not set/'  out/.config
sed -i 's/CONFIG_MODULE_SCMVERSION=y/# CONFIG_MODULE_SCMVERSION is not set/'    out/.config

make -j$(nproc) LLVM=1 ARCH=arm64 CC=clang LD=ld.lld HOSTLD=ld.lld O=out olddefconfig
```

### 3. 编译
```bash
# macOS arm64
export PATH="$HOME/aosp-clang-r510928/bin:$PATH"

# WSL x86_64
export PATH="../../prebuilts/clang/host/linux-x86/clang-r510928/bin:$PATH"

make -j$(nproc) LLVM=1 ARCH=arm64 CC=clang LD=ld.lld HOSTLD=ld.lld O=out all
# 产出: out/arch/arm64/boot/Image (~35MB)
```

### 4. 打包 boot.img
```bash
# 先备份当前分区
adb shell "su -c 'dd if=/dev/block/by-name/boot_b of=/sdcard/boot_backup.img'"
adb pull /sdcard/boot_backup.img

# 解包 + 替换 kernel + 重新打包
python3 kernel_platform/tools/mkbootimg/unpack_bootimg.py \
  --boot_img boot_backup.img --out boot_unpack/
cp out/arch/arm64/boot/Image boot_unpack/kernel
python3 kernel_platform/tools/mkbootimg/mkbootimg.py \
  --header_version 4 --kernel boot_unpack/kernel --ramdisk boot_unpack/ramdisk \
  --output new_boot.img
```

### 5. 刷入
```bash
adb reboot bootloader
fastboot flash boot_b new_boot.img
fastboot reboot

# 恢复 (如果变砖)
fastboot flash boot_b boot_backup.img
fastboot reboot
```

---

## 关键经验 (踩坑记录)

1. **必须用 repo sync 拉完整源码树** — 不能只 clone 一个仓库，oplus 私有代码和 vendor 配置需要完整树
2. **必须从 stock_defconfig 开始** — 不要用 `/proc/config.gz`（已被 KSU 修改），不要用 `gki_defconfig`（缺 vendor 驱动）
3. **5 项配置必须修改** — 否则编译失败或 Image 太小无法启动
4. **vermagic 必须匹配** — `6.6.89-android15-8-o-4k`，LOCALVERSION_AUTO 必须关闭
5. **pahole 版本要对** — v1.25（AOSP prebuilt）或 v1.31+（系统自带）均可，v1.25 经 qemu 可在 arm64 上跑
6. **一加 `fastboot boot` 不生效** — 只能 `fastboot flash`，务必先备份
7. **arm64 host 用 arm64 Clang** — 系统 Ubuntu Clang 18 能编过但启动失败，必须用 AOSP 同源的 Clang

## 工具链

| 平台 | 工具链 | 来源 |
|------|--------|------|
| x86_64 | AOSP Clang r510928 (x86) | repo sync 自动获取 |
| arm64 | AOSP Clang r510928 (arm64) | https://github.com/s1lently/llvm-project/releases/tag/r510928-arm64 |

arm64 版本从 `llvm-project@82e851a407` + llvm_android@32255e1 patches 编译而来。

## 文件说明
- `stock_defconfig` — 从原厂 boot.img 用 `extract-ikconfig` 提取的原始配置
- `build.sh` — 一键编译脚本，自动检测平台
