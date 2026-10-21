//
//  NVRAM.cpp  ——  macOS 13 适配版（stub）
//
//  原实现依赖 IODTNVRAM，需要声明 com.apple.driver.AppleEFINVRAM 依赖
//  （原头文件注释原文："You should declare a dependency on
//   com.apple.driver.AppleEFINVRAM."）。
//  该 kext 在 macOS 13 上已并入 AppleEFIRuntime.kext/Contents/PlugIns/，
//  而 kmutil 会把「二进制引用了未声明依赖提供的符号」的 kext 静默排除出
//  aux collection —— 不报错，极难排查（本次卡了 5 轮）。
//
//  这段 NVRAM 代码只用于读写 "t3u-incompatible" 标记（记录此 macOS 版本
//  不兼容、panic 后拒绝再次加载），是纯容错机制，删掉不影响核心解锁补丁。
//  stub 语义：读不到（= 无标记，不拒绝加载）；写/删 = no-op。
//

#include "NVRAM.h"

extern "C" {

int readNVRAMProperty(const char *symbol, void *value, size_t *len) {
    (void)symbol; (void)value; (void)len;
    return 0;   /* 读不到 → 视为无 incompatibility 标记 */
}

int writeNVRAMProperty(const char *symbol, const void *value, size_t len) {
    (void)symbol; (void)value; (void)len;
    return 1;   /* no-op */
}

int deleteNVRAMProperty(const char *symbol) {
    (void)symbol;
    return 1;   /* no-op */
}

}
