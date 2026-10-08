// 和 Python 版（已驗證）逐筆比對：數值誤差 1e-9 以內、文字完全相同。
// 比對內容在 lib/selftest/golden_check.dart（APP 內「自我檢查」也用同一份）。
// 標準答案由 Python 專案的 tools/export_golden.py 產生（web/selftest/golden.json）。
import 'dart:convert';
import 'dart:io';

import 'package:crane_app/models/crane_spec.dart';
import 'package:crane_app/selftest/golden_check.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _json(String path) => jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;

void main() {
  late GoldenData data;

  setUpAll(() {
    data = GoldenData(
      _json('web/selftest/golden.json'),
      CraneSpec.fromJson(_json('assets/cranes/kato_300lx.json')),
      CraneSpec.fromJson(_json('web/selftest/test_crane.json')),
    );
  });

  for (final s in sections) {
    test(s.$1, () {
      final r = runSection(s, data);
      expect(r.fails, isEmpty, reason: '${r.name}：${r.fails.length} 處不同（共比對 ${r.checks} 項）\n'
          '${r.fails.take(25).join('\n')}');
      expect(r.checks, greaterThan(0));
    });
  }
}
