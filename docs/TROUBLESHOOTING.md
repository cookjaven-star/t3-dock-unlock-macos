# 排查实录：为什么 kext 构建成功却不加载

本文记录一次完整的 macOS 13 kext 加载故障排查，从"完全没反应"到"坞全功能恢复"，
共剥掉 7 层。绝大多数时间花在**静默失败**上 —— 命令不报错、构建显示成功，
但 kext 从未进过内核。

如果你也在给 macOS 13+ 装第三方 kext，本文的判据和工具可以直接复用。

---

## 一、最重要的判据

> **`kmutil create` 构建成功 ≠ kext 被收录。**

`kmutil create` 即便把一个 kext 完全排除掉，也会输出成功、生成 `.kc` 文件、
退出码 0。唯一可信的检查是**看集合里到底有没有它**：

```bash
kmutil create -n aux -V release -z -L --allow-missing-kdk \
  -B "$KC/BootKernelExtensions.kc" -A /tmp/x.kc -r /Library/Extensions

kmutil inspect -p /tmp/x.kc --no-header | grep -i thunderbolt3unblocker
```

`deploy.sh` 已内置这一步。同理：

- `kmutil print-diagnostics` 对"被排除"一律输出 `appears valid and loadable` —— **不可信**
- `plutil -lint` 对 binary plist 输出 `OK` —— **不可信**
- `kextstat` 里没有 ≠ 没装对，也可能只是没重启（staging 只在开机发生）

---

## 二、静默排除的四种触发条件

kext 被 `kmutil` 丢弃时**不产生任何错误**，以下四条逐一核对：

| # | 条件 | 症状 | 检查 |
|---|---|---|---|
| 1 | **文件属主不是 `root:wheel`** | 报 `No binaries or codeless kexts were provided` | `ls -ld /Library/Extensions/X.kext` |
| 2 | **二进制引用了 `OSBundleLibraries` 未声明依赖提供的符号** | 无任何报错，集合里没有它 | `nm -m <bin> \| grep undefined` 逐条对照 `OSBundleLibraries` |
| 3 | **Info.plist 是 binary plist** | `IOCFUnserialize: syntax error near line 1` | `file .../Info.plist` 必须是 XML |
| 4 | **未获用户批准 / consent 未关** | 设置 › 隐私与安全性 有"已阻止加载…" | `spctl kext-consent status`、`csrutil status` |

第 3 条尤其阴险：`plutil`、`kmutil print-diagnostics` 都支持 binary plist 因而
都说 OK，但真正加载的那条链路（IOKit 的 `IOCFUnserialize`）不支持。

---

## 三、七层排查实录

| 轮 | 剥掉的问题 | 关键线索 |
|---|---|---|
| 1 | 误判为"固件问题" | 官方更新器用 `TBT_IOCTL_UPDATE_FIRMWARE`（Windows 专有 IOCTL），macOS 无路径 → 刷机路线不成立 |
| 2 | 误判为"网卡驱动缺失" | Dortania 文档称 HSTNN-CX01 网卡 BCM57786 不被 macOS 支持。方向错了一半：真正问题是整坞不枚举 |
| 3 | 废弃依赖 `AppleEFINVRAM` 等 | AuxKC **all-or-nothing**：一个 kext 依赖解析失败，同目录所有第三方 kext 都不加载（连坐 HighPoint） |
| 4 | **缺 `_kmod_info` 符号** | `kmutil` 报 `kexts must have a _kmod_info symbol`。命令行链接的隐蔽坑，见下 |
| 5 | Kext User Consent | 独立于 SIP 的第二道拦截，只能在恢复模式关 |
| 6 | 依赖声明与二进制引用不一致 | 删了 `AppleEFINVRAM` 依赖，但二进制仍引用 `IODTNVRAM` → 静默排除 |
| 7 | **Info.plist 是 binary plist**（真根因） | `kextlibs` 报 `IOCFUnserialize: syntax error near line 1` |

### 第 4 层的细节：命令行编译 kext 的 `_kmod_info` 坑

`libkmod.a` 的符号表里：

```
c_start.o:  private external __start
            (undefined) external _kmod_info   ← 只引用，不定义
```

每个 kext **必须自己导出 `_kmod_info`**。Xcode 链接时自动处理，命令行 `ld` 不会。
更隐蔽的是：静态库按需拉入，若产物没引用 `__start`，`c_start.o` 根本不进链接，
于是"链接成功"但产物不合格 —— 直到构建集合时才暴露。

修法：自己写 `kmod_info` 结构 + 链接加 `-u __start -u __stop`。

> 踩坑：C 变量名要写成 `_realmain` 才编出符号 `__realmain`
> （写成 `__realmain` 会得到 `___realmain`，对不上 `c_start.o` 的引用）。

### 第 7 层的细节：怎么找到的

所有常规工具都说"没问题"。最后靠 **`kextlibs`** 破案：

```bash
kextlibs -c /Library/Extensions/Thunderbolt3Unblocker.kext
# → Can't read info dictionary: IOCFUnserialize: syntax error near line 1
```

它用的是 IOKit 的 `IOCFUnserialize` 解析器（不支持 binary plist），
因此能暴露 `plutil` 和 `kmutil` 都发现不了的问题。

对照实测确认：HighPoint 与**所有**系统自带 kext 的 Info.plist 均为 XML。

---

## 四、诊断工具箱

```bash
# ① 这个 kext 到底有没有被收录进集合（唯一可信判据）
kmutil inspect -p /tmp/x.kc --no-header | grep -i <bundle-id>

# ② 暴露 Info.plist 解析问题（plutil 查不出来）
kextlibs -c /path/to/X.kext

# ③ 列出二进制引用的、需要依赖提供的符号
nm -m X.kext/Contents/MacOS/X | grep undefined

# ④ 反推应该声明哪些依赖
kextlibs -c X.kext

# ⑤ 体检（注意：会误报 OK，只能当参考）
kmutil print-diagnostics -p X.kext -V release -z -v

# ⑥ AuxKC 到底建出来没有
find /System/Volumes/Preboot -maxdepth 7 -name "*.kc"
# 期望同时有 BootKernelExtensions.kc 和 AuxKernelExtensions.kc

# ⑦ Info.plist 格式（必须 XML）
file X.kext/Contents/Info.plist

# ⑧ 确认是否重启过（staging 只在开机发生）
date -r "$(sysctl -n kern.boottime | awk '{print $4}' | tr -d ',')" "+%F %T"

# ⑨ 确认 patch 是否成功：kext 在 kextstat 里 = start 返回 KERN_SUCCESS
kextstat | grep -i thunderbolt3unblocker
```

---

## 五、AuxKC 机制要点（macOS 11+）

理解这套机制能省掉大量无效重启：

1. `/Library/Extensions` 下的第三方 kext 必须先 **staging** 进 SIP 保护的
   `/Library/StagedExtensions/`，再编进 AuxKC
2. **staging 只在开机时发生** → 任何热加载（`kmutil load` / `kextload`）必然失败，
   这是设计如此，不是报错
3. AuxKC 依赖解析是 **all-or-nothing**：一个 kext 挂掉，整批第三方 kext 全部不加载
4. 因此判断"链路是否健康"，可以拿一个**无关的、已知能加载的**第三方 kext 当对照
   （本机用 HighPointRR）。它如果也消失，说明是整批问题，不是你的 kext 的问题

### `kmutil create` 有用参数

| 参数 | 作用 |
|---|---|
| `-n aux` | 只构建 AuxKC，不碰 BootKC（安全） |
| `-z` | 跳过 kext-consent 审批检查 |
| `--allow-missing-kdk` | 绕过 KDK 缺失报错 |
| `-L` | 不生成 system collection |
| `-x -p <kext>` | 强制显式包含（**绕不过静默排除**，但可用来做对照实验） |
| `-r <dir>` | 扫描目录。**注意**：只认 `root:wheel` 属主 |

---

## 六、本次用到的对照实验方法

当怀疑某个变量时，用**已知的对照组**跑同样的命令，能立刻区分"我的 kext 有问题"
还是"通路本身有问题"：

| 实验 | HighPoint | T3U | 结论 |
|---|---|---|---|
| `-r /Library/Extensions` 全量扫描 | 2 | 0 | T3U 被单独排除 |
| `-x -p` 强制点名 HighPoint | 2 | — | 通路正常 |
| `-x -p` 强制点名 T3U | — | 0 | **强制包含也救不了 → 是依赖解析阶段被丢的** |
| 11 个 Info.plist 变体 | 6 | 0 | 问题不在 Info.plist 的**内容**…… |
| → 转而检查 Info.plist 的**格式** | — | — | 是 binary plist ✓ |

最后一行是本次的关键转折：内容试遍无效后，才想到检查格式。
