/// 非網頁環境（單元測試）用的替代版本：本機儲存放在記憶體，其他功能不做事。
library;

import 'dart:convert';
import 'dart:typed_data';

final Map<String, String> _memory = {};

String? storageGet(String key) => _memory[key];

/// 寫入本機儲存；空間不足時回傳 false。
bool storageSet(String key, String value) {
  _memory[key] = value;
  return true;
}

void storageRemove(String key) => _memory.remove(key);

Future<String> fetchText(String url) => Future.error(UnsupportedError('只有網頁版可以讀取 $url'));

/// 選擇檔案：(檔名, MIME 類型, 內容)；取消時為 null。
Future<(String, String, Uint8List)?> pickFile(String accept) async => null;

/// iPhone 瀏海、底部指示條的安全區域（px）：(上, 右, 下, 左)。
(double, double, double, double) safeArea() => (0.0, 0.0, 0.0, 0.0);

/// 圖片轉成 data URL（非網頁環境不縮小）。
Future<String> imageToDataUrl(Uint8List bytes, String mime, int maxSide) async =>
    'data:$mime;base64,${base64Encode(bytes)}';
