//
//  kmod_info.c
//
//  用命令行 clang/ld 手工链接 kext 时，Xcode 不会帮我们生成 `_kmod_info`。
//  libkmod.a 的 c_start.o 里 `_kmod_info` 是 (undefined) external —— 也就是说
//  **每个 kext 必须自己导出这个符号**，否则 kmutil 构建 AuxKC 时会报：
//      "cannot be placed in kernel collection because: kexts must have a _kmod_info symbol"
//
//  `__realmain` / `__antimain` 同理：正常 kext 里它们是 __DATA,__common 里的空符号，
//  OSKext 发现其值为 NULL 时会跳过 kmod 级 start/stop（IOKit kext 走 IOService）。
//
#include <mach/kmod.h>
#include <stddef.h>

extern kern_return_t Thunderbolt3Unblocker_start(kmod_info_t *ki, void *d);
extern kern_return_t Thunderbolt3Unblocker_stop(kmod_info_t *ki, void *d);

/* 与正常 kext 一致：置于 __DATA,__common，初值 0
   注意：C 变量名 _realmain 编出来才是 c_start.o 引用的 __realmain（符号 = 前缀 _ + 名字）*/
void *_realmain;
void *_antimain;

__attribute__((used))
__attribute__((section("__DATA,__data")))
kmod_info_t kmod_info = {
    NULL,                                    /* next            */
    1,                                       /* info_version    */
    (uint32_t)-1,                            /* id (未分配)      */
    "es.govost.ryan.Thunderbolt3Unblocker",  /* name            */
    "1.0",                                   /* version         */
    0,                                       /* reference_count */
    NULL,                                    /* reference_list  */
    0,                                       /* address         */
    0,                                       /* size            */
    0,                                       /* hdr_size        */
    Thunderbolt3Unblocker_start,             /* start           */
    Thunderbolt3Unblocker_stop               /* stop            */
};
