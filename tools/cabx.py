#!/usr/bin/env python3
# 极简 CAB 解包器 (支持 MSZIP / NONE)，用于扒开 HP softpaq 固件包
import struct, sys, os, zlib

def parse(path, outdir):
    raw = open(path, 'rb').read()
    # 遍历所有 MSCF 候选，挑一个头字段自洽的（避免误报）
    off, d = None, None
    i = raw.find(b'MSCF')
    while i >= 0:
        cand = raw[i:]
        if len(cand) > 40 and cand[25] == 1 and struct.unpack('<H', cand[26:28])[0] > 0:
            cb, = struct.unpack('<I', cand[8:12])
            if 0 < cb <= len(cand):
                off, d = i, cand
                break
        i = raw.find(b'MSCF', i + 1)
    if d is None: raise SystemExit('未找到有效的 CAB 头')
    print(f'CAB 位于偏移 {off}')
    cbCabinet, = struct.unpack('<I', d[8:12])
    coffFiles, = struct.unpack('<I', d[16:20])
    verMin, verMax = d[24], d[25]
    cFolders, cFiles, flags = struct.unpack('<HHH', d[26:32])
    setID, iCab = struct.unpack('<HH', d[32:36])
    p = 36
    cbCFHeader = cbCFolder = cbCFData = 0
    if flags & 0x0004:
        cbCFHeader, cbCFolder, cbCFData = struct.unpack('<HBB', d[p:p+4])
        p += 4 + cbCFHeader
    if flags & 0x0001: raise SystemExit('split cabinet, unsupported')
    if flags & 0x0002: raise SystemExit('cabinet has preceding cab, unsupported')

    folders = []
    for _ in range(cFolders):
        coffCabStart, cCFData, typeCompress = struct.unpack('<IHH', d[p:p+8])
        p += 8 + cbCFolder
        folders.append([coffCabStart, cCFData, typeCompress])
    print(f'CAB v{verMax}.{verMin}  files={cFiles}  folders={cFolders} '
          f'compress={set(f[2] for f in folders)}  size={cbCabinet}/{len(d)}')

    # 文件条目
    p = coffFiles
    entries = []
    for _ in range(cFiles):
        cbFile, uoff, iFolder, dt, tm, attrib = struct.unpack('<IIHHHH', d[p:p+16])
        q = p + 16
        e = d.index(b'\x00', q)
        name = d[q:e].decode('utf-8', 'replace')
        entries.append((name, cbFile, uoff, iFolder))
        p = e + 1

    os.makedirs(outdir, exist_ok=True)
    # 逐 folder 解压出完整数据流
    streams = {}
    for fi, (start, cdata, comp) in enumerate(folders):
        if comp not in (0, 1):
            print(f'  [skip] folder {fi}: compression type {comp} (LZX/Quantum) 不支持')
            streams[fi] = None
            continue
        buf = bytearray()
        pos = start
        bad = 0
        for _ in range(cdata):
            csum, cbData, cbUncomp = struct.unpack('<IHH', d[pos:pos+8])
            body = d[pos+8+cbCFData: pos+8+cbCFData+cbData]
            pos += 8 + cbCFData + cbData
            if comp == 1:
                # MSZIP: 每块是独立 deflate 流，但可回溯前 32KB 窗口
                zdict = bytes(buf[-32768:]) if buf else b''
                out = b''
                for payload in (body[2:] if body[:2] == b'CK' else body, body):
                    try:
                        dec = zlib.decompressobj(-15, zdict=zdict) if zdict else zlib.decompressobj(-15)
                        out = dec.decompress(payload)
                        if out:
                            break
                    except zlib.error:
                        continue
                if not out:
                    bad += 1
                    continue
            else:
                out = body
            buf += out
        if bad:
            print(f'  [warn] folder {fi}: {bad} 个块解压失败')
        streams[fi] = bytes(buf)
        print(f'  folder {fi}: {len(buf)} bytes')

    ok = 0
    for name, cbFile, uoff, iFolder in entries:
        s = streams.get(iFolder)
        if s is None:
            continue
        rel = name.replace('\\', '/').lstrip('/')
        dst = os.path.join(outdir, rel)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        open(dst, 'wb').write(s[uoff:uoff+cbFile])
        ok += 1
    print(f'解出 {ok}/{cFiles} 个文件 -> {outdir}')

if __name__ == '__main__':
    parse(sys.argv[1], sys.argv[2])
