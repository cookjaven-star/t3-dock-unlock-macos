#!/usr/bin/env python3
"""
探针：定位 T3U 被 kmutil 排除出 aux collection 的原因。

必须以 root 运行。做法：把不同 Info.plist 变体装进 /Library/Extensions（root 属主），
跑一次 kmutil create -r /Library/Extensions，看集合里有没有 T3U。全程不重启。

用法：
  sudo /Users/javen/.workbuddy/binaries/python/versions/3.13.12/bin/python3 \
       /Users/javen/WorkBuddy/2026-10-21-22-12-47/t3u/probe_inclusion.py
"""
import os, shutil, subprocess, plistlib, sys

KC = "/System/Volumes/Preboot/B77005F2-7244-4A73-8B68-C6FCA6510AF6/boot/System/Library/KernelCollections"
SRC = "/Users/javen/WorkBuddy/2026-10-21-22-12-47/t3u/build/Thunderbolt3Unblocker.kext"
DST = "/Library/Extensions/Thunderbolt3Unblocker.kext"
PROBE = "/tmp/probe.kc"
NAME = "Thunderbolt3Unblocker"
P = "IOKitPersonalities"

if os.geteuid() != 0:
    sys.exit("需要 root 运行")


def sh(cmd):
    return subprocess.run(cmd, shell=True, capture_output=True, text=True)


def install(mutate):
    shutil.rmtree(DST, ignore_errors=True)
    shutil.copytree(SRC, DST)
    pl = os.path.join(DST, "Contents/Info.plist")
    if mutate:
        with open(pl, "rb") as f:
            info = plistlib.load(f)
        mutate(info)
        with open(pl, "wb") as f:
            plistlib.dump(info, f)
    sh(f'chown -R root:wheel "{DST}" && chmod -R 755 "{DST}"')
    sh(f'codesign -f -s - "{DST}"')
    if os.path.exists(PROBE):
        os.remove(PROBE)
    r = sh(f'kmutil create -n aux -V release -z -L --allow-missing-kdk '
           f'-B "{KC}/BootKernelExtensions.kc" -A "{PROBE}" -r /Library/Extensions')
    if not os.path.exists(PROBE):
        return False, (r.stdout or r.stderr).strip()[:90]
    out = sh(f'kmutil inspect -p {PROBE} --no-header').stdout.lower()
    return out.count(NAME) > 0, f"T3U={out.count(NAME)} HighPoint={out.count('highpoint')}"


def m_platform(i):
    i["CFBundleSupportedPlatforms"] = ["MacOSX"]


def m_cat(i):
    i[P][NAME]["IOMatchCategory"] = "IOService"


def m_both(i):
    m_platform(i)
    m_cat(i)


def m_full(i):
    m_platform(i)
    m_cat(i)
    i.update({"CFBundleGetInfoString": "Thunderbolt3Unblocker 1.0",
              "BuildMachineOSBuild": "22G120", "DTSDKName": "macosx13.3",
              "DTPlatformVersion": "13.3", "DTXcode": "1430",
              "DTCompiler": "com.apple.compilers.llvm.clang.1_0"})


def m_nokpi(i):
    i["OSBundleLibraries"].pop("com.apple.kpi.unsupported", None)


def m_resources(i):
    i[P][NAME].update({"IOProviderClass": "IOResources",
                       "IOMatchCategory": "IOService",
                       "IOResourceMatch": "IOKit"})


def m_res3(i):
    i[P][NAME].update({"IOMatchCategory": "IOService",
                       "IOResourceMatch": "IOKit"})


def m_nopers(i):
    i.pop(P, None)


def m_ver(i):
    """CFBundleVersion 与 CFBundleShortVersionString 对齐"""
    i["CFBundleVersion"] = "1.0"


def m_hpkeys(i):
    """照抄 HighPoint 的元数据键集合"""
    m_platform(i)
    m_cat(i)
    i.update({
        "BuildMachineOSBuild": "19H2",
        "CFBundleGetInfoString": "Version: 1.0, Copyright (c) 2018 Ryan Govostes.",
        "DTCompiler": "com.apple.compilers.llvm.clang.1_0",
        "DTPlatformBuild": "11E608c",
        "DTPlatformVersion": "GM",
        "DTSDKBuild": "16C58",
        "DTSDKName": "macosx10.12",
        "DTXcode": "1150",
        "DTXcodeBuild": "11E608c",
    })


VARIANTS = [
    ("orig       原样", None),
    ("platform   +CFBundleSupportedPlatforms", m_platform),
    ("matchcat   +IOMatchCategory", m_cat),
    ("both       上两项", m_both),
    ("full       补全 Xcode 元数据", m_full),
    ("nokpi      去掉 kpi.unsupported 声明", m_nokpi),
    ("resources  provider 改 IOResources", m_resources),
    ("res3       原 provider + MatchCategory + ResourceMatch", m_res3),
    ("nopers     去掉全部 personality", m_nopers),
    ("ver10      CFBundleVersion 改成 1.0", m_ver),
    ("hpkeys     照抄 HighPoint 元数据键", m_hpkeys),
]

winner = None
print("=" * 72)
for tag, mut in VARIANTS:
    ok, msg = install(mut)
    print(f"{'🎉 收录' if ok else '❌ 排除'}  {tag:44s} {msg}")
    if ok and winner is None:
        winner = (tag, mut)

print("=" * 72)
if winner:
    print(f"✅ 可用方案：{winner[0]}")
    print("   该版本已留在 /Library/Extensions，重启即可生效")
else:
    print("❌ 所有 Info.plist 变体都被排除 —— 问题在 Info.plist 之外")
    print("   （最可能是 ad-hoc 签名：HighPoint 有 Team ID，T3U 没有）")
    install(None)
    print("   已恢复原样")
