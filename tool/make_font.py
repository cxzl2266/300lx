"""產生 APP 用的中文字型：Noto Sans TC 裁成常用字（離線也能顯示中文）。

來源：Windows 11 內建的 C:\\Windows\\Fonts\\NotoSansTC-VF.ttf（SIL Open Font License 1.1，可散布、可裁切）。
工具：Flutter SDK 附的 font-subset（HarfBuzz），不需要另外下載。

收錄：Big5 符號與常用字（5401 字）、ASCII、Latin-1、常用標點與符號、全形字，
     以及 lib/ 程式碼與 assets/ 資料用到的所有字。介面加了新字後要重跑：

    python tool/make_font.py
"""
from __future__ import annotations

import glob
import os
import struct
import subprocess
import sys

APP = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE = r"C:\Windows\Fonts\NotoSansTC-VF.ttf"
FLUTTER = os.environ.get("FLUTTER_ROOT", r"D:\software\flutter")
SUBSET = os.path.join(FLUTTER, "bin", "cache", "artifacts", "engine", "windows-x64", "font-subset.exe")
OUT = os.path.join(APP, "assets", "fonts", "NotoSansTC-Subset.ttf")

RANGES = [(0x20, 0x7E), (0xA0, 0xFF), (0x0391, 0x03C9), (0x2000, 0x206F), (0x2100, 0x214F), (0x2190, 0x21FF),
          (0x2200, 0x22FF), (0x2460, 0x24FF), (0x2500, 0x257F), (0x25A0, 0x25FF), (0x2600, 0x26FF),
          (0x3000, 0x303F), (0xFF00, 0xFFEF)]


def big5(lo: int, hi: int) -> set[int]:
    out = set()
    for b1 in range(lo >> 8, (hi >> 8) + 1):
        for b2 in list(range(0x40, 0x7F)) + list(range(0xA1, 0xFF)):
            if lo <= (b1 << 8) | b2 <= hi:
                try:
                    out.update(ord(c) for c in bytes([b1, b2]).decode("big5"))
                except UnicodeDecodeError:
                    pass
    return out


def cmap(path: str) -> set[int]:
    """字型實際有的字（font-subset 遇到沒有的字會中止）。"""
    f = open(path, "rb").read()
    tables = {}
    for i in range(struct.unpack(">H", f[4:6])[0]):
        tag, _cs, off, ln = struct.unpack(">4sIII", f[12 + 16 * i:28 + 16 * i])
        tables[tag.decode()] = (off, ln)
    off, _ = tables["cmap"]
    out: set[int] = set()
    for i in range(struct.unpack(">H", f[off + 2:off + 4])[0]):
        _pid, _eid, so = struct.unpack(">HHI", f[off + 4 + 8 * i:off + 12 + 8 * i])
        st = off + so
        fmt = struct.unpack(">H", f[st:st + 2])[0]
        if fmt == 12:
            for g in range(struct.unpack(">I", f[st + 12:st + 16])[0]):
                a, b, _gid = struct.unpack(">III", f[st + 16 + 12 * g:st + 28 + 12 * g])
                out.update(range(a, b + 1))
        elif fmt == 4:
            segx2 = struct.unpack(">H", f[st + 6:st + 8])[0]
            seg = segx2 // 2
            ends = struct.unpack(">%dH" % seg, f[st + 14:st + 14 + segx2])
            starts = struct.unpack(">%dH" % seg, f[st + 16 + segx2:st + 16 + 2 * segx2])
            for a, b in zip(starts, ends):
                if a != 0xFFFF:
                    out.update(range(a, b + 1))
    return out


def main() -> int:
    want = big5(0xA140, 0xA3BF) | big5(0xA440, 0xC67E)
    for a, b in RANGES:
        want.update(range(a, b + 1))
    used = set()
    for pat in ("lib/**/*.dart", "assets/**/*.json", "web/selftest/test_crane.json"):
        for p in glob.glob(os.path.join(APP, pat), recursive=True):
            used.update(open(p, encoding="utf-8").read())
    want.update(ord(c) for c in used)
    have = cmap(SOURCE)
    missing = sorted(c for c in {ord(c) for c in used} if c >= 0x80 and c not in have)
    if missing:
        print("注意：程式用到但字型沒有的字：", "".join(chr(c) for c in missing))
    keep = sorted(c for c in want if c >= 0x20 and c in have)
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    r = subprocess.run([SUBSET, OUT, SOURCE], input=" ".join(map(str, keep)).encode(), capture_output=True)
    sys.stdout.write(r.stdout.decode(errors="replace"))
    if r.returncode != 0:
        sys.stderr.write(r.stderr.decode(errors="replace"))
        return r.returncode
    print(f"{len(keep)} 字 → {OUT}（{os.path.getsize(OUT) / 1e6:.2f} MB）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
