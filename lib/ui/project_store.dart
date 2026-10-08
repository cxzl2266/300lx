/// 自動保存在手機瀏覽器（localStorage）：目前圖面 + 偏好設定（只存在這支手機的這個瀏覽器裡）。
library;

import 'dart:convert';

import '../platform/web_io.dart' as io;

const _autosaveKey = 'crane.autosave';
const _prefsKey = 'crane.prefs';

Map<String, Object?>? _decode(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  try {
    final v = jsonDecode(raw);
    return v is Map<String, Object?> ? v : null;
  } catch (_) {
    return null;
  }
}

/// 檢查保存的圖面格式；錯誤時回傳原因。
String? checkProject(Map<String, Object?> d, String craneId) {
  if (d['format'] != 'crane-sim-project') return '這不是吊車作業模擬的專案檔';
  final v = d['version'];
  if (v is! num || v > 1) return '專案檔版本 $v 比這個 APP 新，請先更新 APP';
  if (d['crane'] != craneId) return '專案檔的吊車型號（${d['crane']}）和目前的吊車不同';
  return null;
}

// ---------------------------------------------------------------- 自動保存
bool saveAutosave(Map<String, Object?> project) => io.storageSet(_autosaveKey, jsonEncode(project));

Map<String, Object?>? loadAutosave() => _decode(io.storageGet(_autosaveKey));

// ---------------------------------------------------------------- 偏好設定
Map<String, Object?> loadPrefs() => _decode(io.storageGet(_prefsKey)) ?? {};

void savePrefs(Map<String, Object?> prefs) => io.storageSet(_prefsKey, jsonEncode(prefs));
