# 吊車作業模擬（手機網頁版）

KATO SR-300LX 吊車作業模擬的手機版（Flutter 網頁 APP）。iPhone 用 Safari 打開後「加入主畫面」，
就像一般 APP 一樣使用，第一次開啟後可離線。

網址：<https://cxzl2266.github.io/300lx/>

**僅供規劃參考。** 吊重表數據必須來自原廠操作手冊；實際吊掛仍以吊車荷重計（LMI）與合格人員判斷為準。

## 功能

- 側視圖：手指拖曳主臂（改臂角）、臂端紅點（改臂長；「自由」模式同時改臂角）、助臂尖；雙指縮放平移
- 參數：臂長、半徑、臂角、鉤底離地高度（輸入任一項反算）、助臂、主／副吊鉤
- 荷重：支撐座外伸、額定總荷重、實際吊重、使用率、原廠荷重表提醒
- 安全檢查：淨空、碰撞、吊物離地、過捲、尖端下彎量
- 物件：矩形、多邊形、吊物、貨櫃車、電線、地面高程、文字、尺寸標註、背景圖（可比例校正）
- 量測、復原／重做、操作紀錄、複製貼上
- 保存：圖面自動保存在手機，下次打開還在
- 自我檢查：在手機上用電腦版的標準答案逐筆比對（約 4.6 萬項）

## 和電腦版的關係

計算核心（`lib/core`、`lib/models`）是從電腦版（Python）逐行移植的。
電腦版是資料與驗證的依據：

1. 吊車資料改在 Excel → 電腦版 `tools/import_crane.py` 轉成 JSON
2. 複製到這裡：`data/cranes/kato_300lx.json` → `assets/cranes/kato_300lx.json`
3. 重新產生標準答案：電腦版專案執行 `python -m tools.export_golden crane_app/web/selftest/golden.json`
   （測試用吊車：`tests/cranes/test_crane.json` → `web/selftest/test_crane.json`）
4. `flutter test` 必須全部通過（和電腦版逐筆比對）

## 開發

需要 Flutter 3.47.6。這台電腦的 Flutter 在 `D:\software\flutter`，每個指令前要設：

```powershell
$env:PUB_CACHE = "D:\software\pub-cache"
```

```powershell
flutter test                       # 測試
flutter build web --release --no-web-resources-cdn
python tool/make_sw.py build/web   # 離線快取清單
```

其他工具：

- `python tool/make_font.py`：中文字型（Noto Sans TC 裁成常用字；介面加了新字要重跑）
- `python tool/make_icons.py`：APP 圖示（需要 PySide6，用電腦版的 .venv）

## 發布

推送到 GitHub 的 `main` 分支後，GitHub Actions 會自動測試、建置並發布到 GitHub Pages
（`.github/workflows/deploy.yml`）。手機開 APP 時會自動下載新版本，畫面下方出現「重新載入」。

## 授權

中文字型 Noto Sans TC：SIL Open Font License 1.1（`assets/fonts/OFL.txt`）。
