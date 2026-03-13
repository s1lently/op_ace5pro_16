# OnePlus Ace 5 Pro (SM8750) 内核编译完整记录

## 设备信息
- **设备**: 一加 Ace 5 Pro
- **SoC**: 骁龙 8 Elite (SM8750), 代号 `sun`
- **系统**: OxygenOS 16.0 (Android 16)
- **内核**: Linux 6.6.89, GKI 分支 `android15-6.6`
- **Boot slot**: boot_b (A/B 分区)
- **Root**: SukiSU (KernelSU), magiskboot 位于 `/data/adb/ksu/bin/magiskboot`

## 编译环境
- **主机**: Windows 11, i9-12900HX, 16GB RAM
- **WSL**: Ubuntu 24.04 (虚拟磁盘在 E:\WSL\Ubuntu, 约 1TB)
- **工具链**: AOSP Clang r510928 (build 11368308, +pgo +bolt +lto +mlgo)

## 最终成功的编译流程

### 1. 安装依赖
```bash
# WSL 中以 root 登录
apt install -y build-essential bc flex bison libssl-dev libelf-dev lz4 \
  libncurses-dev git curl wget zip unzip cpio rsync gcc-aarch64-linux-gnu \
  binutils-aarch64-linux-gnu dwarves  # dwarves 提供 pahole, BTF 必需
```

### 2. 用 repo sync 拉取完整源码树
```bash
# 安装 repo
curl -s https://storage.googleapis.com/git-repo-downloads/repo > /usr/local/bin/repo
chmod a+x /usr/local/bin/repo
git config --global user.email "build@local"
git config --global user.name "build"

# 初始化 (使用自定义 manifest, 见下文)
mkdir -p /root/kernel_workspace && cd /root/kernel_workspace
repo init -u <manifest_repo> -m ace5pro_16.xml
repo sync -c -j4 --no-tags
```

manifest XML 需要包含以下关键仓库:
- `android_kernel_common_oneplus_sm8750` → `kernel_platform/common` (分支: oneplus/sm8750_b_16.0.0_oneplus_ace5_pro)
- `android_kernel_oneplus_sm8750` → `kernel_platform/msm-kernel` (同分支)
- `android_kernel_modules_and_devicetree_oneplus_sm8750` → `./` (同分支)
- AOSP prebuilts: clang, gcc, build-tools, kernel-build-tools, rust, dtc, mkbootimg 等

最终目录结构:
```
kernel_workspace/
├── kernel_platform/
│   ├── common/          ← 通用内核源码 (编译在这里进行)
│   ├── msm-kernel/      ← 高通平台代码 + vendor configs
│   ├── oplus/           ← 一加私有代码
│   ├── prebuilts/       ← 工具链 (clang, gcc, etc.)
│   └── ...
└── vendor/              ← vendor 模块和设备树
```

### 3. 获取原厂内核配置 (关键步骤!)
```bash
# 从原厂 stock boot.img 提取内嵌的 config
# 不要用手机上 /proc/config.gz — 那是当前运行内核的配置, 可能已被修改
cd /tmp
python3 -c "
import struct
with open('/path/to/stock/boot.img', 'rb') as f:
    f.seek(4096)  # boot header v4, kernel starts at page 1
    kernel = f.read(36661760)  # KERNEL_SZ from magiskboot unpack
    open('stock_kernel', 'wb').write(kernel)
"
/root/kernel_workspace/kernel_platform/common/scripts/extract-ikconfig stock_kernel > real_stock_config
```

### 4. 修改配置并编译
```bash
export PATH="/root/kernel_workspace/kernel_platform/prebuilts/clang/host/linux-x86/clang-r510928/bin:$PATH"
cd /root/kernel_workspace/kernel_platform/common
mkdir -p out
cp /tmp/real_stock_config out/.config

# 必须修改的配置:
# 1. 禁用 LOCALVERSION_AUTO (我们没有原版 git 历史)
sed -i 's/CONFIG_LOCALVERSION_AUTO=y/# CONFIG_LOCALVERSION_AUTO is not set/' out/.config
# 2. 手动设置 LOCALVERSION 匹配 stock vermagic
sed -i 's/CONFIG_LOCALVERSION="-4k"/CONFIG_LOCALVERSION="-android15-8-o-4k"/' out/.config
# 3. 禁用需要 abi_symbollist.raw 的配置
sed -i 's/CONFIG_TRIM_UNUSED_KSYMS=y/# CONFIG_TRIM_UNUSED_KSYMS is not set/' out/.config
sed -i '/CONFIG_UNUSED_KSYMS_WHITELIST/d' out/.config
# 4. 禁用模块签名保护 (需要签名基础设施)
sed -i 's/CONFIG_MODULE_SIG_PROTECT=y/# CONFIG_MODULE_SIG_PROTECT is not set/' out/.config
# 5. 禁用模块 SCM 版本
sed -i 's/CONFIG_MODULE_SCMVERSION=y/# CONFIG_MODULE_SCMVERSION is not set/' out/.config

# 应用配置
make -j6 LLVM=1 ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
  CC=clang LD=ld.lld HOSTLD=ld.lld O=out olddefconfig

# 编译
make -j6 LLVM=1 ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
  CC=clang LD=ld.lld HOSTLD=ld.lld O=out all
```

产出: `out/arch/arm64/boot/Image` (~36.4MB, stock 为 ~36.6MB)

### 5. 打包 boot.img
```bash
# 在手机上用 magiskboot 操作 (需要 root)
adb push stock_boot.img /sdcard/
adb push Image /sdcard/
adb shell "su -c '
  mkdir -p /data/local/tmp/bootwork && cd /data/local/tmp/bootwork
  cp /sdcard/stock_boot.img .
  /data/adb/ksu/bin/magiskboot unpack stock_boot.img
  cp /sdcard/Image kernel
  /data/adb/ksu/bin/magiskboot repack stock_boot.img new_boot.img
  cp new_boot.img /sdcard/
'"
adb pull /sdcard/new_boot.img
```

### 6. 刷入
```bash
adb reboot bootloader
fastboot flash boot_b new_boot.img
fastboot reboot
```

### 7. 恢复 (如果变砖)
```bash
# 进 fastboot (长按电源+音量下)
fastboot flash boot_b boot_backup.img
fastboot reboot
```

---

## Debug 历程 (踩坑记录)

### 尝试 1: 单独 clone + 系统 Clang 18 + gki_defconfig
**结果**: 编译成功但刷入后砖
**原因**:
- 只 clone 了 `android_kernel_oneplus_sm8750` 一个仓库, 缺少 common 内核和 vendor 代码
- 大量 oplus 私有目录是断裂的符号链接 (指向不存在的 vendor 路径)
- 需要手动创建空的 Kconfig 和 Makefile stub 才能编译通过
- 使用系统 Ubuntu Clang 18.1.3 而非 AOSP 特定版本
- `fastboot boot` 临时启动在一加设备上不生效

### 尝试 2: 正确 AOSP Clang + 手动 vermagic 匹配
**结果**: 编译成功, vermagic 匹配, 仍然砖
**原因**:
- 下载了正确的 AOSP Clang r510928 (从 googlesource +archive 接口)
- vermagic 字符串匹配了 (`6.6.89-android15-8-o-4k`)
- 但 Image 只有 30MB, stock 是 35MB — 缺少大量驱动
- 只用 gki_defconfig 编译, 没有 vendor 平台配置

### 尝试 3: repo sync 完整源码 + gki_defconfig
**结果**: 砖
**原因**:
- 正确使用了 repo sync 拉取完整源码树 (common + msm-kernel + modules)
- 但仍然只用 gki_defconfig, Image 依然 30MB
- vendor config (sun_perf.config) 在 msm-kernel 目录下, 不在 common 里

### 尝试 4: gki_defconfig + sun_perf.config 合并
**结果**: 砖
**原因**:
- 合并了 vendor config, 但大多数驱动被编译为模块 (=m) 而非内置 (=y)
- 配置和 stock 仍有较大差异

### 尝试 5: 从手机 /proc/config.gz 提取配置
**结果**: 编译失败 → 修复后砖
**原因**:
- /proc/config.gz 是**当前运行内核**的配置, 不是原厂的
- 手机已经刷了 KSU, 配置里包含 CONFIG_KSU=y, CONFIG_SUSFS=y 等
- 缺少 `abi_symbollist.raw` 导致编译失败 (CONFIG_TRIM_UNUSED_KSYMS)
- 禁用后编译通过, 但 Image 仍然只有 30MB (缺 BTF)

### 尝试 6 (成功): 从原厂 boot.img 提取 ikconfig
**结果**: 开机成功!
**关键**:
- 使用 `scripts/extract-ikconfig` 从原厂 stock boot.img 中的内核提取嵌入配置
- 这才是**真正的原厂配置**, 包含 CONFIG_DEBUG_INFO_BTF=y (增加 ~5MB)
- 包含 CONFIG_HMBIRD_SCHED=y (一加鸿鸟调度器)
- 只需禁用 5 个需要特殊基础设施的配置项
- Image 大小 36.4MB, 接近 stock 36.6MB
- vermagic 完全匹配, 所有 vendor 模块正常加载

---

## 关键经验总结

1. **必须用 repo sync 拉完整源码树**, 不能单独 clone 一个仓库
2. **必须从原厂 boot.img 提取 config** (extract-ikconfig), 不能用手机上的 /proc/config.gz
3. **必须用 AOSP Clang r510928**, 从 `https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/heads/android15-release/clang-r510928.tar.gz` 下载, 或通过 repo sync 自动获取
4. **必须安装 dwarves (pahole)** 以支持 CONFIG_DEBUG_INFO_BTF
5. **vermagic 必须匹配** vendor_boot/vendor_dlkm 里的模块: `6.6.89-android15-8-o-4k`
6. **LOCALVERSION_AUTO 必须关闭**, 手动设置 LOCALVERSION 为 `-android15-8-o-4k`
7. **一加设备 fastboot boot 不生效**, 只能 fastboot flash, 务必先备份原始 boot 分区
8. **刷入前备份**: `adb shell "su -c 'dd if=/dev/block/by-name/boot_b of=/sdcard/boot_backup.img'"`

## 文件位置
- WSL 源码: `/root/kernel_workspace/kernel_platform/common/`
- WSL 产出: `/root/kernel_workspace/kernel_platform/common/out/arch/arm64/boot/Image`
- AOSP Clang: `/root/kernel_workspace/kernel_platform/prebuilts/clang/host/linux-x86/clang-r510928/`
- Windows 工作目录: `E:\fuckVT\`
