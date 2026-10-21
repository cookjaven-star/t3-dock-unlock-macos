#!/bin/sh
#
# 安装 Thunderbolt3Unblocker.kext 并验证它是否真的被收录进 aux collection
#
#   sudo ./deploy.sh
#
# ⚠️ 关键：kmutil create「构建成功」≠ kext 被收录。
#    本脚本用 kmutil inspect 检查集合里到底有没有我们的 kext ——
#    这是唯一可信的判据，能避免"构建成功但重启后毫无变化"的假象。
#
set -u
cd "$(dirname "$0")"

SRC="$PWD/build/Thunderbolt3Unblocker.kext"
DST="/Library/Extensions/Thunderbolt3Unblocker.kext"
PREBOOT=$(find /System/Volumes/Preboot -maxdepth 1 -type d 2>/dev/null | grep -E "[0-9A-F]{8}-[0-9A-F]{4}" | head -1)
KC="$PREBOOT/boot/System/Library/KernelCollections"
BIN="Thunderbolt3Unblocker"

[ "$(id -u)" = 0 ] || { echo "❌ 需要 root：sudo ./deploy.sh"; exit 1; }
[ -d "$SRC" ] || { echo "❌ 没有构建产物，先跑 ./build.sh"; exit 1; }

echo "==== 0. 产物预检 ===="
nm -m "$SRC/Contents/MacOS/$BIN" 2>/dev/null | grep -q "external _kmod_info" \
    && echo "    ✅ _kmod_info 已导出" \
    || { echo "    ❌ 缺 _kmod_info"; exit 1; }

nm -m "$SRC/Contents/MacOS/$BIN" 2>/dev/null | grep undefined | grep -qiE "NVRAM|gIODTPlane" \
    && { echo "    ❌ 仍引用 NVRAM 符号"; exit 1; } \
    || echo "    ✅ 无未声明依赖的符号"

file "$SRC/Contents/Info.plist" | grep -q "XML" \
    && echo "    ✅ Info.plist 是 XML" \
    || { echo "    ❌ Info.plist 是 binary plist（会被静默排除）"; exit 1; }
echo "    OSBundleLibraries:"
/usr/libexec/PlistBuddy -c "Print :OSBundleLibraries" "$SRC/Contents/Info.plist" 2>/dev/null | sed 's/^/      /'
echo

echo "==== 1. 安装 kext ===="
rm -rf "$DST"
cp -R "$SRC" "$DST"
chown -R root:wheel "$DST"          # 属主必须是 root:wheel，否则直接被丢弃
find "$DST" -type d -exec chmod 755 {} \;
find "$DST" -type f -exec chmod 644 {} \;
chmod 755 "$DST/Contents/MacOS/$BIN"
codesign -f -s - "$DST" >/dev/null 2>&1
echo "    已装到 $DST  ($(stat -f '%Su:%Sg' "$DST"))"
echo

echo "==== 2. User Consent ===="
spctl kext-consent status 2>&1 | sed 's/^/    /'
echo

echo "==== 3. 构建 aux collection 并检查收录（关键）===="
rm -f /tmp/AuxKC.kc
kmutil create -n aux -V release -z -L --allow-missing-kdk \
  -B "$KC/BootKernelExtensions.kc" -A /tmp/AuxKC.kc -r /Library/Extensions 2>&1 | tail -6

[ -f /tmp/AuxKC.kc ] || { echo "    ❌ 构建失败（见上）"; exit 1; }
echo "    构建产物: $(ls -lh /tmp/AuxKC.kc | awk '{print $5}')"

T3U=$(kmutil inspect -p /tmp/AuxKC.kc --no-header 2>/dev/null | grep -ic "thunderbolt3unblocker")
HP=$(kmutil inspect -p /tmp/AuxKC.kc --no-header 2>/dev/null | grep -ic "highpoint")
echo
echo "    ┌─────────────────────────────────────┐"
echo "    │  集合内含 T3U       : $T3U"
echo "    │  集合内含 HighPoint : $HP   (对照)"
echo "    └─────────────────────────────────────┘"

if [ "$T3U" -gt 0 ]; then
    echo
    echo "    ✅✅ T3U 已被收录！重启后即可加载。"
else
    echo
    echo "    ❌ T3U 仍被排除。请检查："
    echo "       1) /Library/Extensions 下该 kext 是否 root:wheel"
    echo "       2) 系统设置 › 隐私与安全性 是否有待批准的提示"
    echo "       3) SIP：csrutil status（需含 Kext Signing / unapproved kext 豁免）"
    echo "       4) 详见 docs/TROUBLESHOOTING.md「静默排除的四种触发条件」"
    echo "       诊断工具: sudo python3 tools/probe_inclusion.py"
    echo "                kextlibs -c $DST        # 能暴露 plist 解析问题"
fi
echo

echo "==== 4. /Library/Extensions ===="
ls /Library/Extensions | sed 's/^/    /'
echo
echo "==> 重启后验证:"
echo "      kextstat | grep -i thunderbolt3unblocker"
echo "      system_profiler SPThunderboltDataType | grep -iA4 'Vendor Name'"
