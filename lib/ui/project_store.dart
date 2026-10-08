/// 專案存放在手機瀏覽器（localStorage）：自動保存目前圖面 + 命名的專案清單 + 偏好設定。
///
/// 只存在這支手機的這個瀏覽器裡；要換手機或備份請用「匯出專案檔」。
library;

import 'dart:convert';

import '../platform/web_io.dart' as io;

const _autosaveKey = 'crane.autosave';
const _projectsKey = 'crane.projects';
const _prefsKey = 'crane.prefs';

class SavedProject {
  final String name;
  final DateTime saved;
  final Map<String, Object?> data;

  SavedProject(this.name, this.saved, this.data);
}

Map<String, Object?>? _decode(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  try {
    final v = jsonDecode(raw);
    return v is Map<String, Object?> ? v : null;
  } catch (_) {
    return null;
  }
}

/// 檢查專案檔格式；錯誤時回傳原因。
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

// ---------------------------------------------------------------- 命名專案
List<SavedProject> listProjects() {
  final all = _decode(io.storageGet(_projectsKey)) ?? const {};
  final out = <SavedProject>[];
  for (final e in all.entries) {
    final v = e.value;
    if (v is! Map<String, Object?>) continue;
    final data = v['data'];
    if (data is! Map<String, Object?>) continue;
    out.add(SavedProject(e.key, DateTime.tryParse('${v['saved']}') ?? DateTime(2000), data));
  }
  out.sort((a, b) => b.saved.compareTo(a.saved));
  return out;
}

/// 儲存（同名覆蓋）；空間不足時回傳 false。
bool saveProject(String name, Map<String, Object?> data) {
  final all = Map<String, Object?>.of(_decode(io.storageGet(_projectsKey)) ?? const {});
  all[name] = {'saved': DateTime.now().toIso8601String(), 'data': data};
  return io.storageSet(_projectsKey, jsonEncode(all));
}

void deleteProject(String name) {
  final all = Map<String, Object?>.of(_decode(io.storageGet(_projectsKey)) ?? const {});
  all.remove(name);
  io.storageSet(_projectsKey, jsonEncode(all));
}

// ---------------------------------------------------------------- 偏好設定
Map<String, Object?> loadPrefs() => _decode(io.storageGet(_prefsKey)) ?? {};

void savePrefs(Map<String, Object?> prefs) => io.storageSet(_prefsKey, jsonEncode(prefs));
