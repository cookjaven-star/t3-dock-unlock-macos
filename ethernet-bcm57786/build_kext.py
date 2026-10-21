#!/usr/bin/env python3
"""
为 HP Elite/ZBook Thunderbolt 3 Dock (HSTNN-CX01) 打补丁的 Broadcom 网卡驱动。

背景：
  该坞的板载网卡是 Broadcom BCM57786 (PCI 14e4:16b3)，走雷电 PCIe 隧道。
  macOS 原生 AppleBCM5701Ethernet.kext 的 IONameMatch 只含
  1684/16b0/16b4/1682/1686，不含 16b3 -> 网口在 Mac 上完全不出现。

做法（基于 Dortania / OCLP 社区方案，去掉 OpenCore 依赖，改为静态补丁）：
  1. IONameMatch 增加 pci14e4,16b3，让 kext 能匹配到这块网卡；
  2. 把 Mach-O 中的设备 ID 读取调用替换成常量 0x16b4 (BCM57765)，
     绕过驱动内部的型号白名单检查。
      Find    : E8 CA 9E FF FF 66 89 83 00 05 00 00   (call <取设备ID>; mov [rbx+0x500], ax)
      Replace : B8 B4 16 00 00 66 89 83 00 05 00 00   (mov eax, 0x16b4;  mov [rbx+0x500], ax)
"""
import os, re, shutil, plistlib, subprocess, sys

SRC = 'catbcm/CatalinaBCM5701Ethernet.kext'
DST = 'build/CatalinaBCM5701Ethernet.kext'
FIND = bytes.fromhex('e8ca9effff66898300050000')
REPL = bytes.fromhex('b8b416000066898300050000')
ADD_ID = 'pci14e4,16b3'   # BCM57786

os.chdir(os.path.dirname(os.path.abspath(__file__)))

# ---------- 1. 复制骨架 ----------
if os.path.exists(DST):
    shutil.rmtree(DST)
shutil.copytree(SRC, DST)

# ---------- 2. 改 Info.plist：加入 16b3 ----------
pl_path = os.path.join(DST, 'Contents/Info.plist')
xml = subprocess.run(['plutil', '-convert', 'xml1', '-o', '-', pl_path],
                     capture_output=True, check=True).stdout
m = re.search(rb'(<key>IONameMatch</key>\s*<array>)(.*?)(</array>)', xml, re.S)
assert m, '未找到 IONameMatch'
# 只保留 BCM57786 (14e4:16b3)：其余 ID (57761/57762/57765/57766/5764M)
# macOS 原生驱动已支持，留着会和原生 kext 抢设备，故全部移除。
only = f'\n\t\t\t<string>{ADD_ID}</string>\n\t\t'.encode()
xml = xml[:m.start(2)] + only + xml[m.end(2):]
print(f'[+] IONameMatch 收紧为仅 {ADD_ID}（避免与原生驱动冲突）')

# --- 2b. 还原 Apple 版权字符串 ---
# macOS 13 起，链接 com.apple.kpi.private 的 kext 必须被判定为 "Apple kext"：
# 条件是 CFBundleIdentifier 前缀 com.apple 且 版权字符串为 Apple 版权。
# OCLP 把它改成了 "Copyright © Dortania"，会在 kextload 时被 kmutil 拒绝
# (Code=30 invalid properties)。这里改回 Apple 版权格式。
APPLE_COPYRIGHT = b'Copyright \xc2\xa9 2003-2021 Apple Inc. All rights reserved.'
before = xml
xml = re.sub(rb'(<key>NSHumanReadableCopyright</key>\s*<string>)[^<]*(</string>)',
             rb'\1' + APPLE_COPYRIGHT + rb'\2', xml)
xml = re.sub(rb'(<key>CFBundleGetInfoString</key>\s*<string>)[^<]*(</string>)',
             rb'\1Apple Broadcom 57XX Ethernet 10.3.5, ' + APPLE_COPYRIGHT + rb'\2', xml)
if xml != before:
    print('[+] 版权字符串已还原为 Apple 版权（解锁 kpi.private 链接）')
else:
    print('[=] 版权字符串无需修改')

with open(pl_path, 'wb') as f:
    f.write(xml)
subprocess.run(['plutil', '-convert', 'binary1', pl_path], check=True)

# ---------- 3. 二进制补丁 ----------
bin_path = os.path.join(DST, 'Contents/MacOS/CatalinaBCM5701Ethernet')
d = open(bin_path, 'rb').read()
assert d.count(FIND) == 1, f'补丁点命中 {d.count(FIND)} 次，预期 1 次，已中止'
d = d.replace(FIND, REPL)
open(bin_path, 'wb').write(d)
os.chmod(bin_path, 0o755)
print('[+] 二进制补丁已应用（设备 ID -> 0x16b4 / BCM57765）')

# ---------- 4. ad-hoc 重签名 ----------
r = subprocess.run(['codesign', '-f', '-s', '-', '--timestamp=none', DST],
                   capture_output=True, text=True)
print('[+] 重签名:', r.returncode == 0, r.stderr.strip()[:120])

# ---------- 5. 校验 ----------
info = plistlib.load(open(pl_path, 'rb'))
ids = info['IOKitPersonalities']['PCI Matching']['IONameMatch']
print('\n最终匹配表:', ids)
print('含 BCM57786:', ADD_ID in ids)
print('产物:', os.path.abspath(DST))
