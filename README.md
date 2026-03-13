# OnePlus Ace 5 Pro Kernel Source

OnePlus Ace 5 Pro (SM8750 / Snapdragon 8 Elite) kernel source for OxygenOS 16.0.

## Device Info

| Item | Value |
|------|-------|
| Device | OnePlus Ace 5 Pro (PKR110) |
| SoC | Qualcomm SM8750 (Snapdragon 8 Elite) |
| Codename | sun |
| OS | OxygenOS 16.0 (Android 16) |
| Kernel | 6.6.89, GKI android15-6.6 |
| Source Branch | `oneplus/sm8750_b_16.0.0_oneplus_ace5_pro` |
| Base Tag | `android15-6.6-2025-06_r27` |
| Firmware | PKR110_16.0.3.500(CN01) |

## Files

- `stock_defconfig` - Original kernel config extracted from factory boot.img via `extract-ikconfig`
- `build_config` - Working `.config` with build fixes applied (see below)
- `BUILD_GUIDE.md` - Complete build procedure and debug history

## Quick Build Guide

### Prerequisites

- WSL2 / Ubuntu 24.04 (or any Linux)
- AOSP Clang r510928
- `apt install build-essential bc flex bison libssl-dev libelf-dev dwarves lz4`

### Build

```bash
# Set up toolchain
export PATH="/path/to/clang-r510928/bin:$PATH"
cd /path/to/this/repo

# Prepare config
mkdir -p out
cp stock_defconfig out/.config

# Apply 5 required fixes
sed -i 's/CONFIG_LOCALVERSION_AUTO=y/# CONFIG_LOCALVERSION_AUTO is not set/' out/.config
sed -i 's/CONFIG_LOCALVERSION="-4k"/CONFIG_LOCALVERSION="-android15-8-o-4k"/' out/.config
sed -i 's/CONFIG_TRIM_UNUSED_KSYMS=y/# CONFIG_TRIM_UNUSED_KSYMS is not set/' out/.config
sed -i '/CONFIG_UNUSED_KSYMS_WHITELIST/d' out/.config
sed -i 's/CONFIG_MODULE_SIG_PROTECT=y/# CONFIG_MODULE_SIG_PROTECT is not set/' out/.config
sed -i 's/CONFIG_MODULE_SCMVERSION=y/# CONFIG_MODULE_SCMVERSION is not set/' out/.config

# Build
make -j$(nproc) LLVM=1 ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
  CC=clang LD=ld.lld HOSTLD=ld.lld O=out olddefconfig

make -j$(nproc) LLVM=1 ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
  CC=clang LD=ld.lld HOSTLD=ld.lld O=out all
```

Output: `out/arch/arm64/boot/Image` (~36MB)

### Flash

1. Copy `Image` to device
2. Unpack stock `boot.img` with `magiskboot unpack boot.img`
3. Replace `kernel` with our `Image`
4. Repack: `magiskboot repack boot.img new_boot.img`
5. Flash: `fastboot flash boot_b new_boot.img`

> **Note:** OnePlus devices do not support `fastboot boot` (temporary boot). You must `fastboot flash`.

### Vermagic

The built kernel must match: `6.6.89-android15-8-o-4k`

This matches vendor_dlkm modules so all `.ko` files load correctly.

## Config Fixes Explained

| Fix | Reason |
|-----|--------|
| Disable `LOCALVERSION_AUTO` | Prevents git hash in version string |
| Set `LOCALVERSION="-android15-8-o-4k"` | Match stock vermagic for module compatibility |
| Disable `TRIM_UNUSED_KSYMS` | Needs `abi_symbollist.raw` which we do not have |
| Disable `MODULE_SIG_PROTECT` | Allow loading unsigned modules |
| Disable `MODULE_SCMVERSION` | Prevents SCM version mismatch |

## Credits

- Kernel source: [OnePlusOSS](https://github.com/OnePlusOSS/android_kernel_common_oneplus_sm8750)
- Build reference: [HanKuCha/oneplus13_a5p_sukisu](https://github.com/HanKuCha/oneplus13_a5p_sukisu)
