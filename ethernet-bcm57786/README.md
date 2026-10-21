# BCM57786 以太网补丁驱动（备选，本次未使用）

## 什么时候需要它

只有当你的坞板载网卡是 **Broadcom BCM57786**（PCI ID `14e4:16b3`）时才需要。

判定方法 —— 解锁坞之后看网口有没有出现：

```bash
networksetup -listallhardwareports
```

- 出现 `Broadcom NetXtreme ...` 一类的以太网口 → **原生驱动已支持，不需要本驱动**
- 没有以太网口 → 查 PCI 设备 ID：

```bash
ioreg -rw0 -c IOEthernetController | grep -i "device-id"
```

若含 `16b3`，才需要装。

## 背景

macOS 原生 `AppleBCM5701Ethernet.kext` 的 `IONameMatch` 只含
`1684 / 16b0 / 16b4 / 1682 / 1686`，**不含 `16b3`**。
Dortania 的《Thunderbolt and PCIe Ethernet in macOS》也直接标注
「HP Elite Thunderbolt 3 Dock → BCM57786 → Not supported in macOS」。

## 做法

基于 OCLP 的 `CatalinaBCM5701Ethernet`，做两处补丁：

1. `IONameMatch` 追加 `pci14e4,16b3`（**只加这一个**，避免和原生驱动抢其他型号）
2. Mach-O 静态补丁：把读取设备 ID 的调用替换为常量 `0x16b4`（BCM57765），
   绕过型号白名单

```
Find   : e8ca9effff 66898300050000
Replace: b8b4160000 66898300050000   # mov eax, 0x16b4
```

> 上游方案原本依赖 OpenCore 的 Kernel Patch 在启动时改写内存，
> 真 Mac 没有 OpenCore，所以这里改成**静态补丁**直接改二进制。

另外必须把 `NSHumanReadableCopyright` 还原成 Apple 版权字符串 ——
该 kext 链接了 `com.apple.kpi.private`，而 macOS 13 起只有"Apple 自家 kext"
才允许链接它，判定条件之一就是版权字符串（OCLP 把它改成了 "Dortania" 会校验失败）。

## 用法

```bash
python3 build_kext.py     # 下载 OCLP 驱动 + 打补丁，产出 build/ 目录
sudo sh install.sh        # 安装到 /Library/Extensions
```

然后重启。回滚：

```bash
sudo rm -rf /Library/Extensions/CatalinaBCM5701Ethernet.kext
sudo touch /Library/Extensions
```
