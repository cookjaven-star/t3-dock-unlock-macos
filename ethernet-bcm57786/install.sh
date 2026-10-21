#!/bin/sh
# 安装打过补丁的 Broadcom BCM57786 网卡驱动
# 适用：HP Elite / ZBook Thunderbolt 3 Dock (HSTNN-CX01)，macOS 13.x
# 回滚：sudo rm -rf /Library/Extensions/CatalinaBCM5701Ethernet.kext && sudo touch /Library/Extensions

SRC="/Users/javen/WorkBuddy/2026-10-21-22-12-47/hstnn-cx01-fw/build/CatalinaBCM5701Ethernet.kext"
DST="/Library/Extensions/CatalinaBCM5701Ethernet.kext"

echo "==> 安装到 $DST"
rm -rf "$DST"
cp -R "$SRC" "$DST"
chown -R root:wheel "$DST"
find "$DST" -type d -exec chmod 755 {} \;
find "$DST" -type f -exec chmod 644 {} \;
chmod 755 "$DST/Contents/MacOS/CatalinaBCM5701Ethernet"
touch /Library/Extensions

# 注意：Ventura 下 kmutil install --update-all 需要匹配 build 22H730 的 KDK，
# 但 /Library/Extensions 的第三方 kext 开机时会自动构建 AuxKC，无需手动重建缓存。
echo "==> 跳过缓存重建（KDK 缺失属正常，开机自动构建 AuxKC）"

echo "==> 体检（离线校验是否可加载）"
kmutil print-diagnostics -p "$DST" -V release -z 2>&1 | tail -8

echo "==> 立即加载（坞未插也可能成功，插入后会自动匹配）"
kmutil load -p "$DST" -V release 2>&1 | tail -20

echo
echo "==> 结果"
if kmutil showloaded --list-only --variant-suffix release 2>/dev/null | grep -qi catalinabcm; then
    echo "✅ 驱动已加载 —— 现在插上扩展坞即可"
else
    echo "⚠️  本次未能热加载，请重启 Mac（开机时会自动构建 AuxKC 并加载）"
    echo "   重启后若仍未生效：系统设置 > 隐私与安全性 > 底部若出现"
    echo "   “已阻止加载来自…的系统扩展” -> 点“允许”，再重启"
fi
