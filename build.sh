#!/bin/bash
#
# 用 Command Line Tools 编译 Thunderbolt3Unblocker.kext（无需 Xcode）
#
# 目标平台：macOS 13.x Ventura / x86_64（Intel Mac）
# Apple Silicon 需把 -arch x86_64 改为 arm64e，并自行确认
# IOThunderboltFamily 里的 shouldSkipEnumeration 符号仍存在（见 docs/TROUBLESHOOTING.md）
#
# 用法：
#   ./build.sh              # 编译，产物在 build/Thunderbolt3Unblocker.kext
#   ./build.sh && sudo ./deploy.sh
#
set -e
cd "$(dirname "$0")"

# ---------------------------------------------------------------- 环境检查
if ! xcode-select -p >/dev/null 2>&1; then
    echo "❌ 未安装 Xcode Command Line Tools，请先跑: xcode-select --install"
    exit 1
fi
SDK=$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX*.sdk 2>/dev/null | tail -1)
[ -n "$SDK" ] || { echo "❌ 找不到 macOS SDK"; exit 1; }
KF="$SDK/System/Library/Frameworks/Kernel.framework"
[ -d "$KF/Headers" ] || { echo "❌ 找不到 Kernel.framework: $KF"; exit 1; }
echo "SDK : $SDK"
echo "KF  : $KF"

# ---------------------------------------------------------------- 依赖
[ -d "$(ls -d zydis-* 2>/dev/null | head -1)" ] || ./fetch_zydis.sh
ZY="$(ls -d zydis-* | head -1)"
echo "Zydis: $ZY"

OUT="build/Thunderbolt3Unblocker.kext"
rm -rf obj "$OUT"
mkdir -p obj "$OUT/Contents/MacOS"

CFLAGS="-arch x86_64 -mkernel -fno-builtin -fno-common -O2 \
  -isysroot $SDK \
  -I$KF/Headers -I$KF/PrivateHeaders \
  -Isrc -Isrc/xnu_override -Isrc/Thunderbolt3Unblocker -I$ZY/include -I$ZY/src \
  -DKERNEL -DKERNEL_PRIVATE"

echo "==> 编译 Zydis (v2)"
for f in "$ZY"/src/*.c; do
    clang $CFLAGS -w -c "$f" -o "obj/z_$(basename "$f" .c).o" || exit 1
done
echo "    $(ls obj/z_*.o | wc -l | tr -d ' ') 个目标文件"

echo "==> 编译 kext 源码"
clang $CFLAGS -w -c src/xnu_override/xnu_override.c      -o obj/xnu_override.o
clang $CFLAGS -w -c src/xnu_override/xnu_override_test.c -o obj/xnu_override_test.o
clang $CFLAGS -w -c src/xnu_override/zydis_stubs.c       -o obj/zydis_stubs.o
clang $CFLAGS -w -c src/Thunderbolt3Unblocker/Thunderbolt3Unblocker.c -o obj/t3u.o
# 【补丁 1】kext 必须有 _kmod_info 符号。Xcode 会自动生成，命令行链接必须自己补。
clang $CFLAGS -w -c src/Thunderbolt3Unblocker/kmod_info.c -o obj/kmod_info.o
clang $CFLAGS -w -x c++ -std=gnu++14 -fno-rtti -fno-exceptions \
      -c src/Thunderbolt3Unblocker/NVRAM.cpp -o obj/NVRAM.o

echo "==> 链接"
# -u __start -u __stop：强制从 libkmod.a 拉入 c_start.o / c_stop.o。
# 静态库按需拉入，不加这两个 -u，提供 _kmod_info 引用的 c_start.o 不会进产物，
# 于是链接"成功"但产物不合格 —— 直到 kmutil 构建集合时才报
# "kexts must have a _kmod_info symbol"。
ld -arch x86_64 -kext -o "$OUT/Contents/MacOS/Thunderbolt3Unblocker" \
   obj/*.o -u __start -u __stop -L"$SDK/usr/lib" -lkmodc++ -lkmod
echo "    链接成功"

echo "==> 校验 kext 必需符号"
if nm -m "$OUT/Contents/MacOS/Thunderbolt3Unblocker" | grep -q "external _kmod_info"; then
    nm -m "$OUT/Contents/MacOS/Thunderbolt3Unblocker" | grep -E "kmod_info|realmain|antimain|__start|__stop$"
    echo "    ✅ _kmod_info 已导出"
else
    echo "    ❌ 仍缺 _kmod_info"; exit 1
fi

# 【补丁 2】确认没有引用未声明依赖提供的符号
# 二进制引用了 OSBundleLibraries 里没人提供的符号 → kmutil 静默排除，不报错。
if nm -m "$OUT/Contents/MacOS/Thunderbolt3Unblocker" | grep undefined | grep -qiE "NVRAM|gIODTPlane"; then
    echo "    ❌ 二进制仍引用 NVRAM 符号（应由 NVRAM.cpp stub 消除）"; exit 1
else
    echo "    ✅ 无未声明依赖的符号"
fi

echo "==> 生成 Info.plist"
cp src/Thunderbolt3Unblocker/Info.plist "$OUT/Contents/Info.plist"
P="$OUT/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable Thunderbolt3Unblocker" "$P"
/usr/libexec/PlistBuddy -c "Set :CFBundleName Thunderbolt3Unblocker" "$P"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier es.govost.ryan.Thunderbolt3Unblocker" "$P"
/usr/libexec/PlistBuddy -c "Set :CFBundleDevelopmentRegion en" "$P"
/usr/libexec/PlistBuddy -c "Set :IOKitPersonalities:Thunderbolt3Unblocker:CFBundleIdentifier es.govost.ryan.Thunderbolt3Unblocker" "$P"

# 【补丁 3】macOS 13 起 AppleEFINVRAM 已并入 AppleEFIRuntime.kext/Contents/PlugIns/，
# 声明该依赖会让 AuxKC 依赖解析失败（连坐同目录所有第三方 kext）。
# NVRAM.cpp 已 stub 化，二进制不再需要它。
echo "==> 移除已废弃依赖 com.apple.driver.AppleEFINVRAM"
/usr/libexec/PlistBuddy -c "Delete :OSBundleLibraries:com.apple.driver.AppleEFINVRAM" "$P" 2>/dev/null || true

# 【补丁 4】⚠️ Info.plist 必须是 XML！
# IOKit 的 IOCFUnserialize 解析不了 binary plist → 读不出 info dictionary
# → kmutil 静默排除该 kext（不报错、构建照样"成功"，极难排查）。
# 对照：HighPoint 与所有系统自带 kext 的 Info.plist 均为 XML。
plutil -convert xml1 "$P"
file "$P" | grep -q "XML" || { echo "❌ Info.plist 不是 XML"; exit 1; }
echo "    ✅ Info.plist = XML"

echo "==> ad-hoc 签名"
codesign -f -s - --timestamp=none "$OUT" 2>&1 | tail -1 || true

echo
echo "产物: $(pwd)/$OUT"
ls -lh "$OUT/Contents/MacOS/Thunderbolt3Unblocker"
echo
echo "下一步: sudo ./deploy.sh"
