"""建置後處理：在 build/web/sw.js 填入版本與離線快取檔案清單。

    flutter build web --release --base-href /300lx/ --no-web-resources-cdn
    python tool/make_sw.py build/web

版本＝所有快取檔案內容的雜湊：內容一變，手機就會下載新版本並顯示「重新載入」。
不預先快取（用到才下載，下載後一樣會存起來）：selftest/（自我檢查資料，不存）、授權條文 NOTICES、
Chrome 專用與其他版本的 CanvasKit（APP 固定用完整版 canvaskit/canvaskit.wasm）、除錯符號。
"""
from __future__ import annotations

import hashlib
import json
import os
import sys

SKIP_DIRS = ("selftest/", "canvaskit/chromium/", "canvaskit/webparagraph/")
SKIP_FILES = {"sw.js", ".last_build_id", "flutter_service_worker.js", "NOTICES"}
SKIP_SUFFIX = (".symbols", ".map")
SKIP_PREFIX = ("skwasm", "wimp")


def wanted(rel: str) -> bool:
    name = rel.rsplit("/", 1)[-1]
    if name in SKIP_FILES or rel.startswith(SKIP_DIRS) or rel.endswith(SKIP_SUFFIX):
        return False
    if name.startswith(SKIP_PREFIX):
        return False
    return True


def main() -> int:
    web = sys.argv[1] if len(sys.argv) > 1 else os.path.join("build", "web")
    tmpl = os.path.join(web, "sw.js")
    src = open(tmpl, encoding="utf-8").read()
    if "__ASSETS__" not in src:
        print("sw.js 已經處理過（或不是範本），請重新 flutter build web")
        return 1
    files = []
    for root, _dirs, names in os.walk(web):
        for n in names:
            rel = os.path.relpath(os.path.join(root, n), web).replace(os.sep, "/")
            if wanted(rel):
                files.append(rel)
    files.sort()
    h = hashlib.sha256()
    total = 0
    for rel in files:
        data = open(os.path.join(web, rel), "rb").read()
        total += len(data)
        h.update(rel.encode())
        h.update(hashlib.sha256(data).digest())
    version = h.hexdigest()[:16]
    assets = ["./"] + files
    src = src.replace("'__VERSION__'", json.dumps(version)).replace("__ASSETS__", json.dumps(assets, indent=1))
    open(tmpl, "w", encoding="utf-8").write(src)
    print(f"sw.js：版本 {version}，離線快取 {len(files)} 個檔案，共 {total / 1e6:.1f} MB")
    return 0


if __name__ == "__main__":
    sys.exit(main())
