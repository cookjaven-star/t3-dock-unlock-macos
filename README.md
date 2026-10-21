# HP Thunderbolt 3 Dock (HSTNN-CX01) macOS 解锁方案

让 **HP Elite / ZBook Thunderbolt 3 Dock（HSTNN-CX01，一代长条坞）** 在 macOS 上
被正常枚举 —— 网口、USB、DisplayPort 全部恢复。

上游 [rgov/Thunderbolt3Unblocker](https://github.com/rgov/Thunderbolt3Unblocker)
只提供 Xcode 工程、且官方声明仅测试到 macOS 12。本项目是它的
**macOS 13 (Ventura) 命令行移植版**：不需要 Xcode，并从零解决了 7 层加载障碍。

---

## 实测通过环境

| 项 | 值 |
|---|---|
| 主机 | MacBookPro15,1（2018 15"，Intel，T2） |
| 系统 | macOS 13.7.8 (22H730) |
| 坞 | HP Thunderbolt 3 Dock / HSTNN-CX01 |
| 坞 Device ID | `0x8190`（Thunderbolt 3 模式） |
| 工具链 | Xcode Command Line Tools + MacOSX13.3.sdk（**无需完整 Xcode**） |
| 结果 | 雷雳枚举 ✅ / USB ✅ / DP 4K ✅ / 网口 ✅ |

Apple Silicon（arm64e）未实测，需自行调整 `-arch` 并确认 patch 目标符号仍存在。

---

## 快速开始

### 0. 前置：关闭 SIP 与 Kext User Consent

这是 kext 能加载的前提，只能在**恢复模式**做。

1. 关机，开机按住 <kbd>Cmd</kbd> + <kbd>R</kbd> 进入「macOS 恢复」
2. 菜单「实用工具 › 终端」，执行：

```bash
csrutil disable
spctl kext-consent disable
```

3. 若第二条报 `failed to store`，先 `reboot` **再进一次恢复模式**只跑第二条
   （`csrutil disable` 要重启后 NVRAM 保护才解除）
4. 正常重启

> 验证：`csrutil status` 应显示 disabled，`spctl kext-consent status` 应为 DISABLED。

### 1. 编译

```bash
./build.sh
```

自动下载 [Zydis](https://github.com/zyantific/zydis) v2 依赖，产出
`build/Thunderbolt3Unblocker.kext`。脚本内置 4 项自检，任一不过会直接报错退出。

### 2. 安装

```bash
sudo ./deploy.sh
```

脚本会安装到 `/Library/Extensions` 并**验证是否被收录进 aux collection**。
看到这个就成了：

```
集合内含 T3U       : 1
```

### 3. 重启并验证

```bash
kextstat | grep -i thunderbolt3unblocker
```

插上坞（**先插 4.5mm 电源，再插雷电口**）：

```bash
system_profiler SPThunderboltDataType | grep -iA4 "Vendor Name"
networksetup -listallhardwareports
system_profiler SPUSBDataType | grep -iA3 "Hub"
```

预期看到 `HP Thunderbolt 3 Dock`、新增以太网口、坞上 USB 集线器。

---

## 原理：坞为什么不被识别

Apple 在 `IOThunderboltFamily` 里维护了一份**「不受支持外设」黑名单**。
插上坞时，`IOThunderboltSwitchType3::shouldSkipEnumeration()` 返回真 →
**整条雷电链路不枚举**。

所以症状是**网口 / USB / DP 全部不可用**，而不只是网口。

本 kext 在加载时对该函数做**内存热补丁**，让它恒返回假，从而跳过黑名单。
它同时打补丁给 `IOThunderboltSwitchType3` 的 vtable，使坞上的 PCIe 隧道
（网卡）、USB 下行口、DP 一起恢复。

---

## 与上游的 4 处差异（macOS 13 适配）

上游工程在 macOS 13 上无法直接构建/加载，全部改动都在 `build.sh` 里标注了
`【补丁 N】`。

| # | 问题 | 现象 | 修法 |
|---|---|---|---|
| 1 | 命令行 `ld -kext` 不生成 `_kmod_info` | 链接"成功"，`kmutil` 报 `kexts must have a _kmod_info symbol` | 新增 `src/Thunderbolt3Unblocker/kmod_info.c` 显式定义；链接加 `-u __start -u __stop` 强制拉入 `c_start.o` |
| 2 | 二进制引用 `IODTNVRAM`，但依赖未声明 | kmutil **静默排除**，集合里根本没有它 | `NVRAM.cpp` 改 stub（原文件留档 `NVRAM.cpp.orig`） |
| 3 | `com.apple.driver.AppleEFINVRAM` 在 macOS 13 已并入 `AppleEFIRuntime.kext/Contents/PlugIns/` | AuxKC 依赖解析失败，**连坐**同目录所有第三方 kext | 从 `OSBundleLibraries` 删除该依赖 |
| 4 | Info.plist 被转成 binary plist | IOCFUnserialize 读不出 info dictionary → kmutil **静默排除** | 强制 `plutil -convert xml1` + 构建时格式断言 |

补丁 2/3/4 都属于「**静默失败**」类：不报错、构建照常成功，但 kext 不会进内核。
这类问题占了本次排查的绝大多数时间，详见 `docs/TROUBLESHOOTING.md`。

---

## 目录结构

```
.
├── build.sh                 编译（含 4 项自检）
├── deploy.sh                安装 + 收录验证
├── fetch_zydis.sh           下载 Zydis v2 + 生成缺失的 CMake 导出头文件
├── src/                     kext 源码（含 macOS 13 适配补丁）
│   ├── Thunderbolt3Unblocker/
│   │   ├── kmod_info.c      【新增】_kmod_info 定义
│   │   ├── NVRAM.cpp        【改】stub 版
│   │   └── NVRAM.cpp.orig   原始版留档
│   └── xnu_override/        上游的内存热补丁框架
├── tools/
│   ├── probe_inclusion.py   Info.plist 变体收录探针（无需重启即可定位排除原因）
│   └── cabx.py              纯 Python 的 HP SoftPaq (CAB+MSZIP) 解包器
├── ethernet-bcm57786/       BCM57786(14e4:16b3) 网卡驱动 —— 本次未用上，备选
└── docs/TROUBLESHOOTING.md  七层排查实录 + 静默排除的四种触发条件
```

---

## 常见问题

**`kmutil` 报 `Missing Developer Kit (KDK)`**
无害。`/Library/Extensions` 的 kext 由系统开机时自动构建 AuxKC，不需要手动重建缓存。

**重启后 `kextstat` 里没有**
按顺序查：① `deploy.sh` 里「集合内含 T3U」是否为 1（为 0 说明根本没收录）②
系统设置 › 隐私与安全性底部是否有「已阻止加载…」③ SIP 是否真的关了。
详见 `docs/TROUBLESHOOTING.md`。

**网口仍缺失**
本坞网卡多为 macOS 原生支持的 Broadcom 型号（实测识别为 `Broadcom NetXtreme`）。
若你的坞是 **BCM57786**（`14e4:16b3`），需额外装 `ethernet-bcm57786/` 里的补丁驱动
—— 它已收紧为只匹配 `16b3`，不会跟原生驱动抢设备。

**坞插上完全没反应**
先排除物理层：① 必须是 40Gbps 雷电 3/4 线（线身有闪电标 + "3"），普通 USB-C
充电线的表现就是完全无反应 ② 必须插 4.5mm 蓝口 HP 电源，不插电雷电链路不建立。

---

## 回滚

```bash
sudo rm -rf /Library/Extensions/Thunderbolt3Unblocker.kext
sudo touch /Library/Extensions
```

然后重启。要恢复 SIP，进恢复模式跑 `csrutil enable`（**这会同时让 kext 失效**）。

---

## 维护提醒

**macOS 大版本升级会清掉 `/Library/Extensions` 里的第三方 kext**，坞会再次
不识别。届时重新执行即可：

```bash
./build.sh && sudo ./deploy.sh && sudo reboot
```

---

## 版权

上游 Thunderbolt3Unblocker：Copyright 2018 Ryan Govostes，MIT。
本仓库新增部分：Copyright 2026 Javen，MIT。详见 `LICENSE`。

Zydis：Copyright Zyantific，MIT。由 `fetch_zydis.sh` 按需下载，不入库。

> ⚠️ 本项目修改内核运行时行为并需要关闭 SIP，可能导致系统不稳定。请备份数据，
> 自行承担风险。
