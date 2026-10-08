/// 吊重表（Load Chart）查詢（移植自 Python 版 core/load_chart.py，規則與文字相同）。
///
/// 主臂表：以「臂長 × 工作半徑」查；介於表列值之間取相鄰格最小值（原廠說明第 8 條，不內插不外插）。
/// 原表空白＝無額定值，例外：臂長介於兩欄、較短臂伸不到（該欄最低作業角度「—」、半徑在最後一列之後）
/// 改用較長臂那欄並以較短臂最遠一列為上限；半徑小於表列最小半徑用最小半徑那列。
/// 副臂表：以工作半徑查（主臂長、副臂長、偏置角須為表列值）；另依作業角度查一次只當提醒。
library;

import 'dart:math' as math;

import 'pyformat.dart';

const double lengthTol = 0.01;
const double radiusTol = 0.001;
const double offsetTol = 0.1;
const double angleTol = 0.01;

/// 半徑顯示到 0.01 m；四捨五入後和比較的表列值看起來一樣時，改顯示到 0.001 m。
String _rad(double x, List<double> listed) {
  final s = fixed(x, 2);
  return listed.any((v) => s == fixed(v, 2)) ? fixed(x, 3) : s;
}

/// xs 遞增。x 等於 xs[i] → (i, i)；介於 xs[i] 與 xs[i+1] → (i, i+1)；超出範圍 → null。
(int, int)? _bracket(List<double> xs, double x, double tol) {
  for (var i = 0; i < xs.length; i++) {
    if ((x - xs[i]).abs() <= tol) return (i, i);
  }
  for (var i = 0; i < xs.length - 1; i++) {
    if (xs[i] < x && x < xs[i + 1]) return (i, i + 1);
  }
  return null;
}

int? _match(List<double> xs, double x, double tol) {
  for (var i = 0; i < xs.length; i++) {
    if ((x - xs[i]).abs() <= tol) return i;
  }
  return null;
}

bool _increasing(List<double> xs) {
  for (var i = 0; i < xs.length - 1; i++) {
    if (!(xs[i + 1] > xs[i])) return false;
  }
  return true;
}

List<int> _sortedSet((int, int) p) => p.$1 == p.$2 ? [p.$1] : [math.min(p.$1, p.$2), math.max(p.$1, p.$2)];

double? _optLoad(Object? v) {
  if (v == null) return null;
  final d = (v as num).toDouble();
  if (d <= 0) throw FormatException('荷重表數值須大於 0（空白請填 null）：$d');
  return d;
}

List<T?> _perColumn<T extends num>(Map<String, dynamic> d, String key, int n, String name, T Function(num) kind) {
  final vals = d[key] as List?;
  if (vals == null) return const [];
  if (vals.length != n) throw FormatException('$name：$key 的個數 ${vals.length} 與欄數 $n 不符');
  final out = [for (final v in vals) v == null ? null : kind(v as num)];
  if (out.any((v) => v != null && v < 0)) throw FormatException('$name：$key 不可為負');
  return out;
}

/// 查表結果。capacity = null 表示無適用資料，basis 說明查表依據或無資料的原因。
class Rating {
  final double? capacity;
  final String chart;
  final String basis;
  final String note;

  const Rating(this.capacity, this.chart, this.basis, [this.note = '']);
}

/// 提醒（不影響額定值）。level：'warn' / 'info'。
class Reminder {
  final String level;
  final String text;

  const Reminder(this.level, this.text);
}

/// 主臂用副吊鉤（單滑輪）的吊物上限：主臂額定 − 吊臂上所有吊鉤、吊具，最多 limit（第 7 條）。
class AuxHookLimit {
  final double? capacity;
  final double attached;
  final double limit;

  const AuxHookLimit(this.capacity, this.attached, this.limit);

  double? get net => capacity == null ? null : math.max(math.min(capacity! - attached, limit), 0.0);
}

/// 原廠荷重表說明中只用來提醒的規則（不改變額定值）。
class ChartRules {
  final bool jibOtherBoomByAngle;
  final List<(double, double)> fullExtensionArea; // (中間外伸, α°)，由大到小
  final double? jibRiggedDeduction;
  final double? jibRiggedLimit;
  final List<(String, String)> clauses;
  final bool minBoomAngle;
  final double? ropeLimit;
  final double? auxHookLimit;

  const ChartRules({
    this.jibOtherBoomByAngle = false,
    this.fullExtensionArea = const [],
    this.jibRiggedDeduction,
    this.jibRiggedLimit,
    this.clauses = const [],
    this.minBoomAngle = false,
    this.ropeLimit,
    this.auxHookLimit,
  });

  factory ChartRules.fromJson(Map<String, dynamic>? d) {
    d ??= const {};
    final areaMap = (d['full_extension_area'] as Map?) ?? const {};
    final area = [
      for (final e in areaMap.entries) (double.parse(e.key as String), (e.value as num).toDouble())
    ]..sort((a, b) {
        final c = b.$1.compareTo(a.$1);
        return c != 0 ? c : b.$2.compareTo(a.$2);
      });
    double? opt(String key) => d![key] == null ? null : (d[key] as num).toDouble();
    final cl = (d['clauses'] as Map?) ?? const {};
    return ChartRules(
      jibOtherBoomByAngle: d['jib_other_boom_by_angle'] == true,
      fullExtensionArea: area,
      jibRiggedDeduction: opt('jib_rigged_deduction'),
      jibRiggedLimit: opt('jib_rigged_limit'),
      clauses: [for (final e in cl.entries) ('${e.key}', '${e.value}')],
      minBoomAngle: d['min_boom_angle'] == true,
      ropeLimit: opt('rope_limit'),
      auxHookLimit: opt('aux_hook_limit'),
    );
  }

  double? areaAngle(double outrigger) {
    for (final (o, a) in fullExtensionArea) {
      if ((o - outrigger).abs() <= lengthTol) return a;
    }
    return null;
  }

  /// 提醒開頭：「原廠說明第 N 條」（沒有條號時只寫「原廠說明」）。
  String clause(String key) {
    for (final (k, v) in clauses) {
      if (k == key) return '原廠說明$v';
    }
    return '原廠說明';
  }
}

class _BoomCells {
  final List<(double, int, int)> cells; // (額定值, 列, 欄)
  final String why;
  final (int, int) cols;
  final (int, int) rows;
  final bool below;
  final int? short;

  const _BoomCells(this.cells,
      [this.why = '', this.cols = (0, 0), this.rows = (0, 0), this.below = false, this.short]);
}

int _cellCompare((double, int, int) a, (double, int, int) b) {
  var c = a.$1.compareTo(b.$1);
  if (c != 0) return c;
  c = a.$2.compareTo(b.$2);
  return c != 0 ? c : a.$3.compareTo(b.$3);
}

/// 主臂荷重表：一種支撐座外伸一張。loads[i][j] = 半徑 radii[i]、臂長 boomLengths[j]。
class BoomChart {
  final double outrigger;
  final List<double> boomLengths;
  final List<double> radii;
  final List<List<double?>> loads;
  final String source;
  final List<double?> minAngles;
  final List<int?> parts;
  final List<int?> starParts;
  final List<List<double>> starRadii;

  BoomChart(this.outrigger, this.boomLengths, this.radii, this.loads,
      [this.source = '', this.minAngles = const [], this.parts = const [], this.starParts = const [],
      this.starRadii = const []]);

  String get title => '主臂｜支撐座外伸 ${numText(outrigger)} m${source.isNotEmpty ? '（$source）' : ''}';

  factory BoomChart.fromJson(Map<String, dynamic> d) {
    final lengths = [for (final v in d['boom_lengths'] as List) (v as num).toDouble()];
    final rows = (d['rows'] as List).cast<Map<String, dynamic>>();
    final radii = [for (final r in rows) (r['radius'] as num).toDouble()];
    final loads = [
      for (final r in rows) [for (final v in r['load'] as List) _optLoad(v)]
    ];
    final out = (d['outrigger'] as num).toDouble();
    if (!_increasing(lengths)) throw FormatException('支撐座 $out m 主臂表：臂長須遞增');
    if (!_increasing(radii)) throw FormatException('支撐座 $out m 主臂表：工作半徑須遞增');
    for (var i = 0; i < radii.length; i++) {
      if (loads[i].length != lengths.length) {
        throw FormatException('支撐座 $out m 主臂表：半徑 ${radii[i]} m 的荷重個數與臂長欄數不符');
      }
    }
    final name = '支撐座 $out m 主臂表';
    final minAngles = _perColumn<double>(d, 'min_angle', lengths.length, name, (v) => v.toDouble());
    final parts = _perColumn<int>(d, 'parts', lengths.length, name, (v) => v.toInt());
    final starParts = _perColumn<int>(d, 'star_parts', lengths.length, name, (v) => v.toInt());
    final star = [
      for (final col in (d['star'] as List?) ?? const []) [for (final r in col as List) (r as num).toDouble()]
    ];
    if (star.isNotEmpty && star.length != lengths.length) throw FormatException('$name：標 * 的半徑欄數與臂長欄數不符');
    for (var j = 0; j < star.length; j++) {
      if (star[j].isNotEmpty && (starParts.isEmpty || starParts[j] == null)) {
        throw FormatException('$name：主臂 ${lengths[j]} m 有標 * 的半徑，但沒有標 * 用的股數');
      }
      for (final r in star[j]) {
        if (_match(radii, r, radiusTol) == null) throw FormatException('$name：標 * 的半徑 $r m 不是表列半徑');
      }
    }
    if (parts.any((v) => v == null)) throw FormatException('$name：鋼索股數不可空白');
    return BoomChart(out, lengths, radii, loads, (d['source'] ?? '').toString(), minAngles, parts, starParts, star);
  }

  /// 最低作業角度：臂長介於兩欄之間取較嚴（較大）者。
  double? minAngle(double length) {
    final cols = minAngles.isNotEmpty ? _bracket(boomLengths, length, lengthTol) : null;
    if (cols == null) return null;
    final vals = [
      for (final j in _sortedSet(cols))
        if (minAngles[j] != null) minAngles[j]!
    ];
    return vals.isEmpty ? null : vals.reduce(math.max);
  }

  /// 查表那一格的標準鋼索股數。
  int? partsOfLine(double length, double radius) {
    final found = _lookup(length, radius);
    if (parts.isEmpty || found.cells.isEmpty) return null;
    final cell = found.cells.reduce((a, b) => _cellCompare(a, b) <= 0 ? a : b);
    final (_, i, j) = cell;
    final star = starRadii.isNotEmpty ? starRadii[j] : const <double>[];
    if (star.any((r) => (radii[i] - r).abs() <= radiusTol)) return starParts[j];
    return parts[j];
  }

  int _lastRow(int j) {
    var last = -1;
    for (var i = 0; i < loads.length; i++) {
      if (loads[i][j] != null) last = i;
    }
    return last;
  }

  bool _outOfReach((int, int) cols, int i, int j) =>
      cols.$1 != cols.$2 && j == cols.$1 && i > _lastRow(j) && minAngles.isNotEmpty && minAngles[j] == null;

  _BoomCells _lookup(double length, double radius) {
    final cols = _bracket(boomLengths, length, lengthTol);
    if (cols == null) {
      return _BoomCells(const [],
          '臂長 ${fixed(length, 2)} m 超出荷重表範圍（${numText(boomLengths.first)}–${numText(boomLengths.last)} m）');
    }
    final below = radius < radii.first - radiusTol;
    final rows = below ? (0, 0) : _bracket(radii, radius, radiusTol);
    if (rows == null) {
      return _BoomCells(const [], '半徑 ${_rad(radius, [radii.last])} m 超出荷重表最大半徑 ${numText(radii.last)} m');
    }
    final cells = <(double, int, int)>[];
    int? short;
    for (final i in _sortedSet(rows)) {
      for (final j in _sortedSet(cols)) {
        final v = loads[i][j];
        if (v != null) {
          cells.add((v, i, j));
        } else if (_outOfReach(cols, i, j)) {
          short = j;
        } else {
          final why = below
              ? '（半徑 ${_rad(radius, [radii.first])} m 小於荷重表最小半徑，用 ${numText(radii.first)} m 那列）'
              : '';
          return _BoomCells(
              const [], '原表空白：主臂 ${numText(boomLengths[j])} m × 半徑 ${numText(radii[i])} m 沒有額定值$why');
        }
      }
    }
    if (short != null) {
      final last = _lastRow(short);
      cells.add((loads[last][short]!, last, short));
    }
    return _BoomCells(cells, '', cols, rows, below, short);
  }

  Rating rating(double length, double radius) {
    final found = _lookup(length, radius);
    if (found.cells.isEmpty) return Rating(null, title, found.why);
    final cols = found.cols, rows = found.rows;
    final cap = found.cells.map((c) => c.$1).reduce(math.min);
    final String lenTxt;
    if (cols.$1 == cols.$2) {
      lenTxt = '主臂 ${numText(boomLengths[cols.$1])} m';
    } else {
      lenTxt = '臂長 ${fixed(length, 2)} m 介於 ${numText(boomLengths[cols.$1])}–${numText(boomLengths[cols.$2])} m';
    }
    final String radTxt;
    if (found.below) {
      final r0 = radii.first;
      radTxt = '半徑 ${_rad(radius, [r0])} m 小於荷重表最小半徑 ${numText(r0)} m，用 ${numText(r0)} m 那列';
    } else if (rows.$1 == rows.$2) {
      radTxt = '半徑 ${numText(radii[rows.$1])} m';
    } else {
      final lo = radii[rows.$1], hi = radii[rows.$2];
      radTxt = '半徑 ${_rad(radius, [lo, hi])} m 介於 ${numText(lo)}–${numText(hi)} m';
    }
    final distinct = {for (final (_, i, j) in found.cells) (i, j)};
    final rule = distinct.length == 1 ? '' : '，取相鄰格最小值（不內插）';
    var reach = '';
    if (found.short != null) {
      final j = found.short!, last = _lastRow(found.short!);
      reach = '；${numText(boomLengths[j])} m 伸不到這個半徑（原表最遠 ${numText(radii[last])} m），'
          '改取 ${numText(boomLengths[cols.$2])} m 欄，並以 ${numText(boomLengths[j])} m '
          '最遠一列 ${numText(loads[last][j]!)} t 為上限';
    }
    return Rating(cap, title, '$lenTxt × $radTxt$rule$reach');
  }
}

/// 副臂荷重表：一種（支撐座外伸, 副臂長）一張，主臂長固定。每列一個作業角度（由高到低）。
class JibChart {
  final double outrigger;
  final double jibLength;
  final double boomLength;
  final List<double> offsets;
  final List<double> angles;
  final List<List<double?>> radii;
  final List<List<double?>> loads;
  final String source;
  final List<double?> minAngles;
  final List<int?> parts;

  JibChart(this.outrigger, this.jibLength, this.boomLength, this.offsets, this.angles, this.radii, this.loads,
      [this.source = '', this.minAngles = const [], this.parts = const []]);

  String get title =>
      '副臂 ${numText(jibLength)} m｜支撐座外伸 ${numText(outrigger)} m${source.isNotEmpty ? '（$source）' : ''}';

  factory JibChart.fromJson(Map<String, dynamic> d) {
    final out = (d['outrigger'] as num).toDouble(), jl = (d['jib_length'] as num).toDouble();
    final name = '副臂 $jl m／支撐座 $out m 表';
    final offsets = [for (final v in d['offsets'] as List) (v as num).toDouble()];
    final rows = (d['rows'] as List).cast<Map<String, dynamic>>();
    final angles = [for (final r in rows) (r['angle'] as num).toDouble()];
    final radii = [
      for (final r in rows) [for (final v in r['radius'] as List) _optLoad(v)]
    ];
    final loads = [
      for (final r in rows) [for (final v in r['load'] as List) _optLoad(v)]
    ];
    if (!_increasing(offsets)) throw FormatException('$name：偏置角須遞增');
    if (!_increasing([for (final a in angles) -a])) throw FormatException('$name：作業角度須由高到低排列');
    for (var i = 0; i < angles.length; i++) {
      if (radii[i].length != offsets.length || loads[i].length != offsets.length) {
        throw FormatException('$name：作業角度 ${angles[i]}° 的欄數與偏置角個數不符');
      }
      for (var k = 0; k < offsets.length; k++) {
        if ((radii[i][k] == null) != (loads[i][k] == null)) {
          throw FormatException('$name：作業角度 ${angles[i]}° 的半徑與荷重須同時填寫或同時空白');
        }
      }
    }
    for (var k = 0; k < offsets.length; k++) {
      final col = [
        for (final rr in radii)
          if (rr[k] != null) rr[k]!
      ];
      if (!_increasing(col)) throw FormatException('$name：偏置 ${offsets[k]}° 的半徑須隨作業角度降低而遞增');
    }
    final minAngles = _perColumn<double>(d, 'min_angle', offsets.length, name, (v) => v.toDouble());
    final parts = _perColumn<int>(d, 'parts', offsets.length, name, (v) => v.toInt());
    if (parts.any((v) => v == null)) throw FormatException('$name：鋼索股數不可空白');
    return JibChart(out, jl, (d['boom_length'] as num).toDouble(), offsets, angles, radii, loads,
        (d['source'] ?? '').toString(), minAngles, parts);
  }

  double? minAngle(double offset) {
    final k = _match(offsets, offset, offsetTol);
    return k == null || minAngles.isEmpty ? null : minAngles[k];
  }

  int? partsOfLine(double offset) {
    final k = _match(offsets, offset, offsetTol);
    return k == null || parts.isEmpty ? null : parts[k];
  }

  (int?, Rating?) _offsetIndex(double offset) {
    final k = _match(offsets, offset, offsetTol);
    if (k == null) {
      final allowed = offsets.map((o) => '${numText(o)}°').join('、');
      return (null, Rating(null, title, '副臂偏置角須為 $allowed（目前 ${fixed(offset, 2)}°）'));
    }
    return (k, null);
  }

  /// 偏置角 offset 的表列最小半徑（最高作業角度那列）。
  double? minRadius(double offset) {
    final k = _match(offsets, offset, offsetTol);
    if (k == null) return null;
    for (final rr in radii) {
      if (rr[k] != null) return rr[k];
    }
    return null;
  }

  /// 依工作半徑查。
  Rating rating(double offset, double radius) {
    final (k0, err) = _offsetIndex(offset);
    if (err != null) return err;
    final k = k0!;
    final idx = [
      for (var i = 0; i < angles.length; i++)
        if (radii[i][k] != null) i
    ];
    final col = [for (final i in idx) radii[i][k]!];
    final pos = _bracket(col, radius, radiusTol);
    if (pos == null) {
      final String why;
      if (radius < col.first) {
        why = '小於偏置 ${numText(offsets[k])}° 最小半徑 ${numText(col.first)} m';
      } else {
        why = '超出偏置 ${numText(offsets[k])}° 最大半徑 ${numText(col.last)} m';
      }
      return Rating(null, title, '半徑 ${_rad(radius, [col.first, col.last])} m $why');
    }
    final rows = [for (final p in _sortedSet(pos)) idx[p]];
    final cap = rows.map((i) => loads[i][k]!).reduce(math.min);
    final head = '偏置 ${numText(offsets[k])}°';
    if (rows.length == 1) {
      final i = rows.first;
      return Rating(cap, title, '$head × 半徑 ${numText(radii[i][k]!)} m（作業角度 ${numText(angles[i])}°）');
    }
    final a = rows[0], b = rows[1];
    return Rating(
        cap,
        title,
        '$head × 半徑 ${_rad(radius, [radii[a][k]!, radii[b][k]!])} m 介於 '
        '${numText(radii[a][k]!)}–${numText(radii[b][k]!)} m（作業角度 ${numText(angles[a])}°–'
        '${numText(angles[b])}°），取兩列較小值（不內插）');
  }

  /// 依作業角度（主臂仰角）查；角度介於兩列之間取兩列較小值。
  Rating ratingByAngle(double offset, double angle) {
    final (k0, err) = _offsetIndex(offset);
    if (err != null) return err;
    final k = k0!;
    final idx = [
      for (var i = 0; i < angles.length; i++)
        if (loads[i][k] != null) i
    ].reversed.toList(); // 由低角度到高角度
    final col = [for (final i in idx) angles[i]];
    final pos = _bracket(col, angle, angleTol);
    final head = '偏置 ${numText(offsets[k])}°';
    if (pos == null) {
      final String why;
      if (angle < col.first) {
        why = '低於偏置 ${numText(offsets[k])}° 最低作業角度 ${numText(col.first)}°';
      } else {
        why = '超出偏置 ${numText(offsets[k])}° 最高作業角度 ${numText(col.last)}°';
      }
      return Rating(null, title, '作業角度 ${fixed(angle, 2)}° $why');
    }
    final rows = [for (final p in _sortedSet(pos)) idx[p]];
    final cap = rows.map((i) => loads[i][k]!).reduce(math.min);
    if (rows.length == 1) return Rating(cap, title, '$head × 作業角度 ${numText(angles[rows.first])}°');
    final lo = rows[0], hi = rows[1];
    return Rating(cap, title,
        '$head × 作業角度 ${fixed(angle, 2)}° 介於 ${numText(angles[lo])}°–${numText(angles[hi])}°，取兩列較小值（不內插）');
  }
}

/// 一台吊車的全部荷重表。
class LoadChartSet {
  final List<BoomChart> boom;
  final List<JibChart> jib;
  final String unit;
  final ChartRules rules;

  LoadChartSet(this.boom, [this.jib = const [], this.unit = 't', this.rules = const ChartRules()]);

  factory LoadChartSet.fromJson(Map<String, dynamic> d) {
    final boom = [for (final t in (d['boom'] as List?) ?? const []) BoomChart.fromJson(t as Map<String, dynamic>)];
    final jib = [for (final t in (d['jib'] as List?) ?? const []) JibChart.fromJson(t as Map<String, dynamic>)];
    if (boom.isEmpty) throw const FormatException('荷重表至少要有一張主臂表');
    final outs = boom.map((b) => b.outrigger).toList();
    if (outs.toSet().length != outs.length) throw const FormatException('主臂荷重表的支撐座外伸重複');
    final jkeys = jib.map((j) => '${j.outrigger}/${j.jibLength}').toList();
    if (jkeys.toSet().length != jkeys.length) throw const FormatException('副臂荷重表的（支撐座外伸, 副臂長）重複');
    final unit = (d['unit'] ?? 't').toString();
    if (unit != 't') throw FormatException('荷重單位只支援公噸 t（檔案為 $unit）');
    return LoadChartSet(boom, jib, unit, ChartRules.fromJson(d['rules'] as Map<String, dynamic>?));
  }

  /// 可選的支撐座外伸（由大到小）。
  List<double> get outriggers => boom.map((b) => b.outrigger).toList()..sort((a, b) => b.compareTo(a));

  List<double> jibLengths(double outrigger) =>
      [for (final j in jib) if ((j.outrigger - outrigger).abs() <= lengthTol) j.jibLength]..sort();

  BoomChart? boomChart(double outrigger) {
    for (final b in boom) {
      if ((b.outrigger - outrigger).abs() <= lengthTol) return b;
    }
    return null;
  }

  JibChart? jibChart(double outrigger, double jibLength) {
    for (final j in jib) {
      if ((j.outrigger - outrigger).abs() <= lengthTol && (j.jibLength - jibLength).abs() <= lengthTol) return j;
    }
    return null;
  }

  double? minBoomAngle(double outrigger, double boomLength, [(double, double)? jibSel]) {
    if (jibSel == null) return boomChart(outrigger)?.minAngle(boomLength);
    final jc = jibChart(outrigger, jibSel.$1);
    if (jc == null || (boomLength - jc.boomLength).abs() > lengthTol) return null;
    return jc.minAngle(jibSel.$2);
  }

  int? partsOfLine(double outrigger, double boomLength, double radius, [(double, double)? jibSel]) {
    if (jibSel == null) return boomChart(outrigger)?.partsOfLine(boomLength, radius);
    final jc = jibChart(outrigger, jibSel.$1);
    if (jc == null || (boomLength - jc.boomLength).abs() > lengthTol) return null;
    return jc.partsOfLine(jibSel.$2);
  }

  /// 副臂：目前偏置角的 (作業角度, 半徑) 各列，作業角度由低到高。
  List<(double, double)> jibRows(double outrigger, double boomLength, (double, double) jibSel) {
    final chart = jibChart(outrigger, jibSel.$1);
    if (chart == null || (boomLength - chart.boomLength).abs() > lengthTol) return const [];
    final k = _match(chart.offsets, jibSel.$2, offsetTol);
    if (k == null) return const [];
    final rows = <(double, double)>[
      for (var i = 0; i < chart.angles.length; i++)
        if (chart.radii[i][k] != null) (chart.angles[i], chart.radii[i][k]!)
    ];
    rows.sort((a, b) {
      final c = a.$1.compareTo(b.$1);
      return c != 0 ? c : a.$2.compareTo(b.$2);
    });
    return rows;
  }

  /// 目前適用的荷重表的表列半徑（拖曳吸附用）。
  List<double> listedRadii(double outrigger, double boomLength, [(double, double)? jibSel]) {
    if (jibSel == null) return boomChart(outrigger)?.radii ?? const [];
    return [for (final (_, r) in jibRows(outrigger, boomLength, jibSel).reversed) r];
  }

  AuxHookLimit? auxHookLimitFor(double outrigger, double boomLength, double radius, double attachedWeight) {
    final lim = rules.auxHookLimit;
    if (lim == null) return null;
    return AuxHookLimit(rating(outrigger, boomLength, radius).capacity, attachedWeight, lim);
  }

  /// 原廠荷重表說明（rules）的提醒，不改變額定值。
  List<Reminder> reminders(double outrigger, double boomLength, double radius,
      {(double, double)? jibSel,
      double? boomAngle,
      double attachedWeight = 0.0,
      double? loadWeight,
      bool auxHook = false}) {
    final ru = rules;
    final out = <Reminder>[];
    if (jibSel != null) {
      final chart = jibChart(outrigger, jibSel.$1);
      if (ru.jibOtherBoomByAngle &&
          chart != null &&
          boomAngle != null &&
          (boomLength - chart.boomLength).abs() > lengthTol) {
        final ra = chart.ratingByAngle(jibSel.$2, boomAngle);
        final got = ra.capacity != null ? '${numText(ra.capacity!)} t（${ra.basis}）' : '查不到（${ra.basis}）';
        out.add(Reminder(
            'warn',
            '${ru.clause('jib_other_boom_by_angle')}：主臂不是 ${numText(chart.boomLength)} m 時，副臂只依主臂仰角查表；'
                '依臂角 ${fixed(boomAngle, 2)}° 為 $got。額定值仍以荷重表（依半徑）為準'));
      }
    } else if (auxHook) {
      final ah = auxHookLimitFor(outrigger, boomLength, radius, attachedWeight);
      if (ah != null) {
        final head = '${ru.clause('aux_hook')}：主臂用副吊鉤（單滑輪、單股）作業';
        final net = ah.net;
        if (net == null) {
          out.add(Reminder('warn', '$head，吊物上限 = 主臂額定 − 吊鉤吊具，最多 ${numText(ah.limit)} t；目前查不到主臂額定值'));
        } else {
          var now = '';
          if (loadWeight != null) {
            now = '；目前吊物 ${fixed(loadWeight, 2)} t${loadWeight > net + 1e-9 ? '，超過' : ''}';
          }
          out.add(Reminder(
              'warn',
              '$head，吊物上限 = 額定 ${numText(ah.capacity!)} t − 吊鉤吊具 ${fixed(ah.attached, 2)} t，'
                  '最多 ${numText(ah.limit)} t → ${fixed(net, 2)} t$now'));
        }
      }
      if (ru.jibRiggedDeduction != null) {
        out.add(Reminder('info', '${ru.clause('jib_rigged')}：副臂裝在主臂前端（未收在側邊）時不可使用單滑輪（副吊鉤）'));
      }
    } else if (ru.jibRiggedDeduction != null) {
      final cap = rating(outrigger, boomLength, radius).capacity;
      if (cap != null) {
        var net = cap - ru.jibRiggedDeduction! - attachedWeight;
        var limit = '';
        if (ru.jibRiggedLimit != null) {
          limit = '，上限 ${numText(ru.jibRiggedLimit!)} t';
          net = math.min(net, ru.jibRiggedLimit!);
        }
        net = math.max(net, 0.0);
        var now = '';
        if (loadWeight != null) {
          now = '；目前吊物 ${fixed(loadWeight, 2)} t${loadWeight > net + 1e-9 ? '，超過' : ''}';
        }
        out.add(Reminder(
            'info',
            '${ru.clause('jib_rigged')}：若副臂裝在主臂前端（未收在側邊）用主臂作業，'
                '吊物上限 = 額定 ${numText(cap)} t − ${numText(ru.jibRiggedDeduction!)} t'
                ' − 吊鉤吊具 ${fixed(attachedWeight, 2)} t$limit → ${fixed(net, 2)} t$now'));
      }
    }
    final minAngle = minBoomAngle(outrigger, boomLength, jibSel);
    if (minAngle != null) {
      if (boomAngle != null && boomAngle < minAngle - 1e-9) {
        out.add(Reminder('warn',
            '${ru.clause('min_boom_angle')}：臂角 ${fixed(boomAngle, 2)}° 低於最低作業角度 ${numText(minAngle)}°，即使空載也可能翻車'));
      } else {
        out.add(Reminder('info', '最低作業角度 ${numText(minAngle)}°（${ru.clause('min_boom_angle')}：低於這個角度即使空載也可能翻車）'));
      }
    }
    final parts = partsOfLine(outrigger, boomLength, radius, jibSel);
    if (jibSel == null && auxHook) {
      if (ru.auxHookLimit != null) out.add(Reminder('info', '鋼索股數：副吊鉤單股（${ru.clause('aux_hook')}）'));
    } else if (parts != null) {
      final limit = ru.ropeLimit != null ? '；股數不同時每股不超過 ${numText(ru.ropeLimit!)} t' : '';
      out.add(Reminder('info', '鋼索股數：標準 $parts 股（${ru.clause('rope_limit')}$limit）'));
    }
    final areaDeg = ru.areaAngle(outrigger);
    final full = outriggers.first;
    if (areaDeg != null && (outrigger - full).abs() > lengthTol) {
      final rf = rating(full, boomLength, radius, jibSel, boomAngle);
      if (rf.capacity != null) {
        out.add(Reminder(
            'info',
            '${ru.clause('full_extension_area')}：在車頭、車尾方向左右各 ${numText(areaDeg)}° 範圍內作業，'
                '可用全伸 ${numText(full)} m 表：${numText(rf.capacity!)} t（目前採 ${numText(outrigger)} m 表）'));
      }
    }
    return out;
  }

  /// 查額定總荷重。jibSel = (副臂長, 偏置角)；null 表示用主臂表。
  Rating rating(double outrigger, double boomLength, double radius, [(double, double)? jibSel, double? boomAngle]) {
    final outTxt = '支撐座外伸 ${numText(outrigger)} m';
    if (jibSel == null) {
      final chart = boomChart(outrigger);
      if (chart == null) return Rating(null, '主臂', '沒有$outTxt的主臂荷重表');
      return chart.rating(boomLength, radius);
    }
    final (jibLength, offset) = jibSel;
    final chart = jibChart(outrigger, jibLength);
    if (chart == null) {
      final have = jibLengths(outrigger);
      if (have.isEmpty) return Rating(null, '副臂', '沒有$outTxt的副臂荷重表');
      return Rating(null, '副臂',
          '$outTxt沒有副臂 ${fixed(jibLength, 2)} m 的荷重表（有：${have.map((v) => '${numText(v)} m').join('、')}）');
    }
    if ((boomLength - chart.boomLength).abs() > lengthTol) {
      return Rating(
          null, chart.title, '副臂荷重表只適用主臂 ${numText(chart.boomLength)} m（目前 ${fixed(boomLength, 2)} m）');
    }
    final byRadius = chart.rating(offset, radius);
    if (boomAngle == null) return byRadius;
    final byAngle = chart.ratingByAngle(offset, boomAngle);
    if (byRadius.capacity == null) {
      final rmin = chart.minRadius(offset);
      if (rmin == null || radius >= rmin) return byRadius;
      if (byAngle.capacity == null) {
        return Rating(null, chart.title, '${byRadius.basis}；依作業角度也查不到（${byAngle.basis}）');
      }
      return Rating(
          byAngle.capacity,
          chart.title,
          '半徑 ${_rad(radius, [rmin])} m 小於表列最小半徑 ${numText(rmin)} m（荷重表半徑含吊臂下彎、'
          '畫面幾何不含）→ 改依作業角度：${byAngle.basis}');
    }
    const why = '副臂荷重表的半徑含吊臂受載下彎，畫面臂角不含下彎，實際吊重時臂角會比畫面高';
    final String note;
    if (byAngle.capacity == null) {
      note = '提醒：依畫面臂角查不到額定值（${byAngle.basis}）；$why';
    } else if (byAngle.capacity! < byRadius.capacity!) {
      note = '提醒：依畫面臂角查為 ${numText(byAngle.capacity!)} t（${byAngle.basis}），'
          '比依半徑的 ${numText(byRadius.capacity!)} t 小；$why';
    } else {
      return byRadius;
    }
    return Rating(byRadius.capacity, byRadius.chart, byRadius.basis, note);
  }
}
