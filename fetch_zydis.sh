#!/bin/bash
# 下载 Zydis v2（Thunderbolt3Unblocker 的反汇编依赖）
# 固定到上游 submodule 锁定的 commit，保证可复现。
#
# 注意：不要用 codeload 的分支名（如 refs/heads/v2 会 404），必须用 commit sha。
set -e
cd "$(dirname "$0")"

SHA="2852492484c9053c26a3655fa2efdbb4d16aa9de"
DEST="zydis-$SHA"

if [ -d "$DEST" ]; then
    echo "已存在 $DEST"
    exit 0
fi

echo "==> 下载 Zydis @ $SHA"
curl -sSL --max-time 180 -o zydis.zip \
    "https://codeload.github.com/zyantific/zydis/zip/$SHA" \
    || { echo "❌ 下载失败（检查网络/代理）"; exit 1; }

unzip -o -q zydis.zip
rm -f zydis.zip

# ZydisExportConfig.h 本是 CMake 的 generate_export_header 产物。
# kext 构建环境没有 cmake，这里手工补一份等价实现。
cat > "$DEST/include/ZydisExportConfig.h" <<'EOF'
#ifndef ZYDIS_EXPORT_CONFIG_H
#define ZYDIS_EXPORT_CONFIG_H

/* 手工替代 CMake generate_export_header 产物（kext 环境无 cmake） */
#define ZYDIS_STATIC_DEFINE

#ifdef ZYDIS_STATIC_DEFINE
#  define ZYDIS_EXPORT
#  define ZYDIS_NO_EXPORT
#else
#  ifndef ZYDIS_EXPORT
#    define ZYDIS_EXPORT __attribute__((visibility("default")))
#  endif
#  ifndef ZYDIS_NO_EXPORT
#    define ZYDIS_NO_EXPORT __attribute__((visibility("hidden")))
#  endif
#endif

#ifndef ZYDIS_DEPRECATED
#  define ZYDIS_DEPRECATED __attribute__((__deprecated__))
#endif
#ifndef ZYDIS_DEPRECATED_EXPORT
#  define ZYDIS_DEPRECATED_EXPORT ZYDIS_EXPORT ZYDIS_DEPRECATED
#endif
#ifndef ZYDIS_DEPRECATED_NO_EXPORT
#  define ZYDIS_DEPRECATED_NO_EXPORT ZYDIS_NO_EXPORT ZYDIS_DEPRECATED
#endif

#endif /* ZYDIS_EXPORT_CONFIG_H */
EOF

echo "    ✅ $DEST"
