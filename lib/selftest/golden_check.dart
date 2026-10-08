/// 自我檢查：和 Python 版（已驗證）逐筆比對，數值誤差 1e-9 以內、文字完全相同。
///
/// 標準答案由 Python 專案的 tools/export_golden.py 產生（golden.json）。
/// 單元測試（test/golden_test.dart）和 APP 內「自我檢查」共用這裡的比對，
/// APP 內執行時就是用手機瀏覽器的 JavaScript 引擎算，可確認網頁版數字和桌面版一樣。
library;

import '../core/collision.dart';
import '../core/geometry.dart';
import '../core/load_chart.dart';
import '../core/vehicle.dart';
import '../models/crane_spec.dart';
import '../models/objects.dart';
import '../models/simulation.dart';

const double tol = 1e-9;

double? numOf(Object? v) {
  if (v == null) return null;
  if (v is String) {
    if (v == 'inf') return double.infinity;
    if (v == '-inf') return double.negativeInfinity;
    return double.parse(v);
  }
  return (v as num).toDouble();
}

Pt ptOf(Object? v) {
  final l = v as List;
  return pt(numOf(l[0])!, numOf(l[1])!);
}

List<Pt> ptsOf(Object? v) => [for (final p in v as List) ptOf(p)];

List<double>? ptList(Pt? p) => p == null ? null : [p.x, p.y];

List<List<double>> ptsList(List<Pt> ps) => [
      for (final p in ps) [p.x, p.y]
    ];

/// 比對差異收集器：先全部比完再一起報告。
class Diff {
  final List<String> fails = [];
  int checks = 0;

  void same(Object? actual, Object? expected, String where) {
    checks += 1;
    _cmp(actual, expected, where);
  }

  void _cmp(Object? a, Object? e, String where) {
    if (fails.length > 400) return;
    if (a is num || e is num || (e is String && (e == 'inf' || e == '-inf') && a is num)) {
      final x = a == null ? null : (a as num).toDouble();
      final y = numOf(e);
      if (x == null || y == null) {
        if (x != y) fails.add('$where：$a ≠ $e');
        return;
      }
      if (x.isInfinite || y.isInfinite) {
        if (x != y) fails.add('$where：$a ≠ $e');
        return;
      }
      if ((x - y).abs() > tol * (1 + y.abs())) fails.add('$where：$x ≠ $y（差 ${x - y}）');
      return;
    }
    if (a is Map && e is Map) {
      final ka = a.keys.map((k) => '$k').toSet(), ke = e.keys.map((k) => '$k').toSet();
      if (ka.length != ke.length || !ka.containsAll(ke)) {
        fails.add('$where：欄位不同 ${ka.difference(ke)} / ${ke.difference(ka)}');
        return;
      }
      for (final k in e.keys) {
        _cmp(a[k], e[k], '$where.$k');
      }
      return;
    }
    if (a is List && e is List) {
      if (a.length != e.length) {
        fails.add('$where：長度 ${a.length} ≠ ${e.length}');
        return;
      }
      for (var i = 0; i < a.length; i++) {
        _cmp(a[i], e[i], '$where[$i]');
      }
      return;
    }
    if (a != e) fails.add('$where：「$a」≠「$e」');
  }
}

/// 一個比對項目的結果。
class SectionResult {
  final String name;
  final int checks;
  final List<String> fails;
  final Duration elapsed;

  const SectionResult(this.name, this.checks, this.fails, this.elapsed);

  bool get ok => fails.isEmpty;
}

/// 比對所需的資料：標準答案與兩份規格檔（KATO 與測試用吊車）。
class GoldenData {
  final Map<String, dynamic> golden;
  final CraneSpec kato;
  final CraneSpec generic;

  GoldenData(this.golden, this.kato, this.generic);
}

typedef Section = (String, void Function(GoldenData g, Diff d));

/// 所有比對項目（名稱, 比對函式），依序執行。
const List<Section> sections = [
  ('規格檔讀取：鉸點、偏移、吊鉤', checkSpec),
  ('幾何：正算、反算、拖曳', checkGeometry),
  ('下彎、伸縮節', checkDeflection),
  ('荷重表：查表、股數、最低角度、提醒', checkCharts),
  ('車身外型與尺寸檢查', checkVehicle),
  ('碰撞距離', checkCollision),
  ('圖面物件', checkObjects),
  ('操作情境：每一步的完整狀態', checkScenarios),
];

SectionResult runSection(Section s, GoldenData g) {
  final d = Diff();
  final sw = Stopwatch()..start();
  try {
    s.$2(g, d);
  } catch (e, st) {
    d.fails.add('執行時發生例外：$e\n$st');
  }
  return SectionResult(s.$1, d.checks, d.fails, sw.elapsed);
}

Map<String, Object?> attempt(double Function() fn) {
  try {
    return {'value': fn()};
  } on OutOfReachError catch (e) {
    return {'error': e.message};
  }
}

Map<String, Object?> poseMap(BoomPose p) => p.toJson();

BoomLimits limitsOf(Map<String, dynamic> d) => BoomLimits(
      pivotX: numOf(d['pivot_x'])!,
      pivotY: numOf(d['pivot_y'])!,
      boomMin: numOf(d['boom_min'])!,
      boomMax: numOf(d['boom_max'])!,
      angleMin: numOf(d['angle_min'])!,
      angleMax: numOf(d['angle_max'])!,
      jibMin: numOf(d['jib_min'])!,
      jibMax: numOf(d['jib_max'])!,
      jibOffsetMin: numOf(d['jib_offset_min'])!,
      jibOffsetMax: numOf(d['jib_offset_max'])!,
      tipOffset: numOf(d['tip_offset'])!,
      auxAlong: numOf(d['aux_along'])!,
      auxBelow: numOf(d['aux_below'])!,
      auxRope: numOf(d['aux_rope'])!,
      lengthOffset: numOf(d['length_offset'])!,
    );

Map<String, Object?> limitsMap(BoomLimits l) => {
      'pivot_x': l.pivotX,
      'pivot_y': l.pivotY,
      'boom_min': l.boomMin,
      'boom_max': l.boomMax,
      'angle_min': l.angleMin,
      'angle_max': l.angleMax,
      'jib_min': l.jibMin,
      'jib_max': l.jibMax,
      'jib_offset_min': l.jibOffsetMin,
      'jib_offset_max': l.jibOffsetMax,
      'tip_offset': l.tipOffset,
      'aux_along': l.auxAlong,
      'aux_below': l.auxBelow,
      'aux_rope': l.auxRope,
      'length_offset': l.lengthOffset,
    };

Map<String, Object?>? ratingMap(Rating? r) =>
    r == null ? null : {'capacity': r.capacity, 'chart': r.chart, 'basis': r.basis, 'note': r.note};

List<List<String>> remindersList(List<Reminder> rs) => [
      for (final r in rs) [r.level, r.text]
    ];

(double, double)? jibSelOf(Object? v) => v == null ? null : (numOf((v as List)[0])!, numOf(v[1])!);

// ====================================================================== 各比對項目
void checkSpec(GoldenData g, Diff d) {
  final golden = g.golden;
  d.same(limitsMap(g.kato.limits), golden['limits']['kato'], 'kato');
  d.same(limitsMap(g.generic.limits), golden['limits']['generic'], 'generic');
  for (final name in ['kato', 'generic']) {
    final s = name == 'kato' ? g.kato : g.generic;
    for (final row in golden['hook_setups'][name] as List) {
      final h = s.hookSetup(row[0] as String, row[1] as bool);
      d.same({
        'hook': h.hook,
        'on_jib': h.onJib,
        'sheave': h.sheave,
        'block_height': h.blockHeight,
        'overhoist': h.overhoist,
        'warning': h.warning,
        'bottom_drop': h.bottomDrop,
        'drop': h.drop,
        'min_hoist': h.minHoist,
      }, row[2], 'hook_setups.$name.${row[0]}.${row[1]}');
    }
  }
}

void checkGeometry(GoldenData g, Diff d) {
  final golden = g.golden;
  final lims = {for (final e in (golden['limits'] as Map).entries) e.key as String: limitsOf(e.value)};
  for (final (n, c) in (golden['geometry'] as List).indexed) {
    final lim = lims[c['limits']]!;
    final pose = BoomPose.fromJson(c['pose']);
    final r = solve(pose, lim);
    final w = 'geometry[$n]';
    d.same(ptList(r.mainTip), c['main_tip'], '$w.main_tip');
    d.same(ptList(r.head), c['head'], '$w.head');
    d.same(ptList(r.jibTip), c['jib_tip'], '$w.jib_tip');
    d.same(ptList(r.auxTip), c['aux_tip'], '$w.aux_tip');
    d.same(r.radius, c['radius'], '$w.radius');
    d.same(r.height, c['height'], '$w.height');
    for (final row in c['angle_for_radius'] as List) {
      final dr = numOf(row[0])!;
      d.same(attempt(() => angleForRadius(r.radius + dr, pose, lim)), row[1], '$w.angle_for_radius($dr)');
    }
    for (final row in c['angle_for_height'] as List) {
      final dh = numOf(row[0])!;
      d.same(attempt(() => angleForHeight(r.height + dh, pose, lim)), row[1], '$w.angle_for_height($dh)');
    }
    for (final row in c['angle_for_radius_near'] as List) {
      final dr = numOf(row[0])!;
      d.same(angleForRadiusNear(r.radius + dr, pose, lim), row[1], '$w.angle_for_radius_near($dr)');
    }
    for (final row in c['drag_main'] as List) {
      d.same(poseMap(poseFromMainTipDrag(ptOf(row[0]), pose, lim)), row[1], '$w.drag_main');
    }
    for (final row in c['drag_length'] as List) {
      d.same(poseMap(poseFromTipLengthDrag(ptOf(row[0]), pose, lim)), row[1], '$w.drag_length');
    }
    for (final row in c['drag_angle'] as List) {
      d.same(poseMap(poseFromBoomAngleDrag(ptOf(row[0]), pose, lim, numOf(row[1])!)), row[2], '$w.drag_angle');
    }
    for (final row in c['pointer_angle'] as List) {
      d.same(pointerAngle(ptOf(row[0]), lim), row[1], '$w.pointer_angle');
    }
    for (final row in (c['drag_jib'] as List?) ?? const []) {
      d.same(poseMap(poseFromJibTipDrag(ptOf(row[0]), pose, lim)), row[1], '$w.drag_jib');
    }
    d.same(poseMap(clampPose(pose.copyWith(length: pose.length * 3, angle: pose.angle + 50), lim)), c['clamp_pose'],
        '$w.clamp_pose');
  }
}

void checkDeflection(GoldenData g, Diff d) {
  final x = g.golden['deflection'] as Map<String, dynamic>;
  for (final row in x['at'] as List) {
    d.same(deflectionAt(numOf(row[0])!, numOf(row[1])!), row[2], 'at');
  }
  for (final row in x['polyline'] as List) {
    d.same(ptsList(deflectedPolyline(ptsOf(row[0]), numOf(row[1])!, row[2] as int)), row[3], 'polyline');
  }
  for (final row in x['telescopic'] as List) {
    final secs = telescopicSections(numOf(row[0])!, numOf(row[1])!, row[2] as int);
    d.same([
      for (final (s, e) in secs) [s, e]
    ], row[3], 'telescopic');
  }
}

void checkCharts(GoldenData g, Diff d) {
  final golden = g.golden;
  for (final c in golden['charts'] as List) {
    final name = c['name'] as String;
    final LoadChartSet lc = name == 'kato'
        ? g.kato.loadCharts!
        : LoadChartSet.fromJson(golden['chart_sources'][name] as Map<String, dynamic>);
    d.same(lc.outriggers, c['outriggers'], '$name.outriggers');
    for (final row in c['boom'] as List) {
      final o = numOf(row[0])!, len = numOf(row[1])!, rad = numOf(row[2])!;
      d.same(ratingMap(lc.rating(o, len, rad)), row[3], '$name.boom($o, $len, $rad)');
      d.same(lc.partsOfLine(o, len, rad), row[4], '$name.parts($o, $len, $rad)');
    }
    for (final row in c['min_angle'] as List) {
      d.same(lc.minBoomAngle(numOf(row[0])!, numOf(row[1])!), row[2], '$name.min_angle');
    }
    for (final row in c['jib'] as List) {
      if (row[0] == 'min') {
        final o = numOf(row[1])!, bl = numOf(row[2])!;
        final sel = (numOf(row[3])!, numOf(row[4])!);
        d.same(lc.minBoomAngle(o, bl, sel), row[5], '$name.jib_min');
        d.same(lc.partsOfLine(o, bl, 10.0, sel), row[6], '$name.jib_parts');
        d.same([
          for (final (a, r) in lc.jibRows(o, bl, sel)) [a, r]
        ], row[7], '$name.jib_rows');
        d.same(lc.listedRadii(o, bl, sel), row[8], '$name.jib_listed');
        continue;
      }
      final o = numOf(row[0])!, bl = numOf(row[1])!, rad = numOf(row[2])!;
      final sel = (numOf(row[3])!, numOf(row[4])!);
      final ang = numOf(row[5]);
      d.same(ratingMap(lc.rating(o, bl, rad, sel, ang)), row[6], '$name.jib($o, $bl, $rad, $sel, $ang)');
    }
    for (final row in c['reminders'] as List) {
      if (row[0] == 'aux_limit') {
        final ah = lc.auxHookLimitFor(numOf(row[1])!, numOf(row[2])!, numOf(row[3])!, numOf(row[4])!);
        d.same(ah == null ? null : [ah.capacity, ah.attached, ah.limit, ah.net], row[5], '$name.aux_limit');
        continue;
      }
      final rs = lc.reminders(numOf(row[0])!, numOf(row[1])!, numOf(row[2])!,
          jibSel: jibSelOf(row[3]),
          boomAngle: numOf(row[4]),
          attachedWeight: numOf(row[5])!,
          loadWeight: numOf(row[6]),
          auxHook: row[7] as bool);
      d.same(remindersList(rs), row[8], '$name.reminders(${row.take(8).join(', ')})');
    }
    for (final row in c['listed'] as List) {
      d.same(lc.listedRadii(numOf(row[0])!, numOf(row[1])!), row[2], '$name.listed');
    }
  }
}

void checkVehicle(GoldenData g, Diff d) {
  final x = g.golden['vehicle'] as Map<String, dynamic>;
  List<double> rect((double, double, double, double) r) => [r.$1, r.$2, r.$3, r.$4];
  for (final (n, c) in (x['layout'] as List).indexed) {
    final lay = layoutBody(VehicleBody.fromJson(c['body']), ptOf(c['pivot']));
    d.same({
      'body': VehicleBody.fromJson(c['body']).toJson(),
      'pivot': c['pivot'],
      'rear_x': lay.rearX,
      'front_x': lay.frontX,
      'chassis': rect(lay.chassis),
      'wheels': [
        for (final (x, y, r) in lay.wheels) [x, y, r]
      ],
      'legs': [for (final r in lay.outriggerLegs) rect(r)],
      'pads': [for (final r in lay.outriggerPads) rect(r)],
      'turntable': rect(lay.turntable),
      'upper': ptsList(lay.upper),
      'bracket': ptsList(lay.bracket),
      'cab': ptsList(lay.cab),
      'window': ptsList(lay.window),
      'center_mark': rect(lay.centerMark),
      'cylinder_base': ptList(lay.cylinderBase),
      'bumpers': [for (final r in lay.bumpers) rect(r)],
      'bounds': rect(lay.bounds()),
      'shapes': [
        for (final (name, (p, closed)) in lay.shapes()) [name, ptsList(p), closed]
      ],
    }, c, 'layout[$n]');
  }
  for (final row in x['validate'] as List) {
    d.same(validateBody(VehicleBody.fromJson(row[0]), numOf(row[1])), row[2], 'validate');
  }
}

void checkCollision(GoldenData g, Diff d) {
  final x = g.golden['collision'] as Map<String, dynamic>;
  for (final row in x['segments'] as List) {
    final p = ptsOf(row[0]);
    d.same(segmentsIntersect(p[0], p[1], p[2], p[3]), row[1], 'intersect');
    d.same(segmentDistance(p[0], p[1], p[2], p[3]), row[2], 'segment_distance');
    d.same(pointSegmentDistance(p[0], p[2], p[3]), row[3], 'point_segment');
  }
  for (final row in x['rects'] as List) {
    final r = Rect(numOf(row[0][0])!, numOf(row[0][1])!, numOf(row[0][2])!, numOf(row[0][3])!);
    final p = ptsOf(row[1]);
    d.same(segmentRectDistance(p[0], p[1], r), row[2], 'segment_rect');
    d.same(polylineClearance(p, r, 0.3), row[3], 'polyline_clearance');
  }
  for (final row in x['shapes'] as List) {
    final a = ptsOf(row[0]), b = ptsOf(row[2]);
    final ca = row[1] as bool, cb = row[3] as bool;
    final lim = numOf(row[4])!;
    d.same(shapeDistance(a, ca, b, cb, lim), row[5], 'shape_distance');
    d.same(preparedDistance(Prepared(a, ca), Prepared(b, cb), lim), row[6], 'prepared_distance');
    d.same([for (final p in a) pointInPolygon(p, b)], row[7], 'point_in_polygon');
  }
}

void checkObjects(GoldenData g, Diff d) {
  final x = g.golden['objects'] as Map<String, dynamic>;
  for (final (n, c) in (x['trucks'] as List).indexed) {
    final t = TruckObject.fromJson(Map<String, Object?>.from(c['obj'] as Map));
    final w = 'truck[$n]';
    d.same(t.toJson(), c['obj'], '$w.obj');
    d.same([
      for (final b in t.boxes()) [b.part, b.x0, b.y0, b.x1, b.y1, b.grounded]
    ], c['boxes'], '$w.boxes');
    d.same([
      for (final (x, y, r) in t.wheels()) [x, y, r]
    ], c['wheels'], '$w.wheels');
    final leg = t.landingLeg();
    d.same(leg == null ? null : [leg.$1, leg.$2, leg.$3], c['leg'], '$w.leg');
    d.same([
      for (final (a, b, lo, hi) in t.profile()) [a, b, lo, hi]
    ], c['profile'], '$w.profile');
    d.same(ptsList(t.outline()), c['outline'], '$w.outline');
    d.same(ptsList(t.keyPoints()), c['key_points'], '$w.key_points');
    d.same(t.totalLength, c['total_length'], '$w.total_length');
    d.same(t.topHeight, c['top_height'], '$w.top_height');
    d.same(t.extent(), c['extent'], '$w.extent');
    for (final row in c['top_max'] as List) {
      d.same(t.topMax(numOf(row[0])!, numOf(row[1])!), row[2], '$w.top_max');
    }
    final b = t.bounds();
    d.same([b.$1, b.$2, b.$3, b.$4], c['bounds'], '$w.bounds');
  }
  final lg = x['load'] as Map<String, dynamic>;
  final load = LoadObject.fromJson(Map<String, Object?>.from(lg['obj'] as Map));
  final tip = pt(6.0, 20.0);
  d.same(load.toJson(), lg['obj'], 'load.obj');
  d.same(ptList(load.hookAt(tip)), lg['hook'], 'load.hook');
  d.same(ptsList(load.rectAt(tip)), lg['rect'], 'load.rect');
  final (l, r) = load.attachPoints(tip);
  d.same(ptsList([l, r]), lg['attach'], 'load.attach');
  d.same(load.slingLegLength(), lg['leg'], 'load.leg');
  d.same(load.slingAngle(), lg['angle'], 'load.angle');
  final bs = LoadObject.blockSize(1.123);
  d.same([bs.$1, bs.$2], lg['block'], 'load.block');
  d.same(ptsList(load.blockRect(tip, 1.123)), lg['block_rect'], 'load.block_rect');
  d.same([
    for (final (p, c) in load.riggingShapes(tip, 1.123)) [ptsList(p), c]
  ], lg['rigging'], 'load.rigging');
  d.same([
    for (final (p, c) in load.riggingShapes(tip, 0.0)) [ptsList(p), c]
  ], lg['rigging0'], 'load.rigging0');

  final m = x['misc'] as Map<String, dynamic>;
  final rect = RectObject.fromJson({'id': 'r', 'x': 3.0, 'y': 1.0, 'width': 4.0, 'height': 2.0});
  d.same(ptsList(rect.outline()), m['rect_outline'], 'rect_outline');
  for (final row in m['rect_handles'] as List) {
    d.same(rect.withHandle(row[0] as int, ptOf(row[1])), row[2], 'rect_handle');
  }
  d.same(rect.translated(1.5, -2), m['rect_translated'], 'rect_translated');
  final poly = PolygonObject.fromJson({'id': 'p'});
  d.same(poly.withHandle(2, pt(9.0, 9.0)), m['poly_handle'], 'poly_handle');
  d.same(poly.translated(1, 1), m['poly_translated'], 'poly_translated');
  final ground = GroundObject.fromJson({'id': 'g', 'x1': 10.0, 'x2': 4.0, 'elevation': -2.0});
  d.same(ptsList(ground.outline()), m['ground_outline'], 'ground_outline');
  d.same(ptsList(ground.handles()), m['ground_handles'], 'ground_handles');
  for (final row in m['ground_covers'] as List) {
    d.same(ground.covers(numOf(row[0])!), row[1], 'ground_covers');
  }
  d.same([ground.withHandle(0, pt(2.0, -3.0)), ground.withHandle(1, pt(12.0, 1.0))], m['ground_handle'],
      'ground_handle');
  for (final row in m['dims'] as List) {
    final dim = DimensionObject.fromJson({'id': 'd', 'x1': 1, 'y1': 2, 'x2': 4, 'y2': 6, 'mode': row[0]});
    d.same(dim.value(), row[1], 'dims');
  }
  final img = ImageObject.fromJson({'id': 'i'});
  d.same(img.withHandle(0, pt(40.0, 10.0)), m['img_handle'], 'img_handle');
  d.same([img.calibrated(pt(0, 0), pt(3, 4), 10.0), img.calibrated(pt(1, 1), pt(1, 1), 5.0)], m['img_calibrated'],
      'img_calibrated');
  final tb = TextObject.fromJson({'id': 'x'}).bounds();
  d.same([tb.$1, tb.$2, tb.$3, tb.$4], m['text_bounds'], 'text_bounds');
  d.same(ptsList(WireObject.fromJson({'id': 'w'}).outline()), m['wire_outline'], 'wire_outline');
  for (final e in x['defaults'] as List) {
    final dflt = Map<String, Object?>.from(e as Map);
    final obj = objectFromJson({'id': dflt['id'], 'kind': dflt['kind']});
    d.same(obj.toJson(), dflt, 'default.${dflt['kind']}');
  }
  for (final e in x['roundtrip'] as List) {
    final dd = Map<String, Object?>.from(e as Map);
    d.same(objectFromJson(dd).toJson(), dd, 'roundtrip.${dd['kind']}');
  }
}

void checkScenarios(GoldenData g, Diff d) {
  final specs = {'kato': g.kato, 'generic': g.generic};
  for (final sc in g.golden['scenarios'] as List) {
    final name = sc['name'] as String;
    final m = SimulationModel(specs[sc['start']]!);
    final steps = sc['steps'] as List;
    // 預設障礙物的 id 是隨機產生的：把 Dart 版的 id 換成 Python 版的再比
    final pyId = (steps.first['state']['objects'] as List).first['id'] as String;
    final dartId = m.objects().first.id;
    Object? fix(Object? v) {
      if (v is String) return v == dartId ? pyId : v;
      if (v is Map) return {for (final e in v.entries) fix(e.key): fix(e.value)};
      if (v is List) return [for (final x in v) fix(x)];
      return v;
    }

    for (final (n, step) in steps.indexed) {
      final op = step['op'] as List;
      String? err;
      if (op.first != 'init') err = runOp(m, op, specs);
      final w = '$name[$n] ${op.join(' ')}';
      d.same(err, step['error'], '$w.error');
      d.same(fix(snapshot(m)), step['state'], w);
    }
    m.dispose();
  }
}

String? runOp(SimulationModel m, List op, Map<String, CraneSpec> specs) {
  final fn = op.first as String;
  final a = op.sublist(1);
  double n(int i) => numOf(a[i])!;
  try {
    switch (fn) {
      case 'undo':
        m.undoStack.undo();
      case 'redo':
        m.undoStack.redo();
      case 'remove_all':
        m.removeObjects([for (final o in m.objects()) o.id]);
      case 'add':
        m.addObject(objectFromJson(Map<String, Object?>.from(a[0] as Map)));
      case 'update':
        m.updateObject(a[0] as String, Map<String, Object?>.from(a[1] as Map));
      case 'translate':
        m.translateObjects((a[0] as List).cast<String>(), n(1), n(2));
      case 'remove':
        m.removeObjects((a[0] as List).cast<String>());
      case 'set_spec':
        m.setSpec(specs[a[0]]!);
      case 'set_boom_length':
        m.setBoomLength(n(0));
      case 'set_boom_angle':
        m.setBoomAngle(n(0));
      case 'set_hook':
        m.setHook(a[0] as String);
      case 'set_radius':
        m.setRadius(n(0));
      case 'set_hook_bottom_height':
        m.setHookBottomHeight(n(0));
      case 'set_outrigger':
        m.setOutrigger(n(0));
      case 'set_rigging_weight':
        m.setRiggingWeight(n(0));
      case 'set_tip_deflection':
        m.setTipDeflection(n(0));
      case 'set_jib_enabled':
        m.setJibEnabled(a[0] as bool);
      case 'set_jib_offset':
        m.setJibOffset(n(0));
      case 'set_jib_length':
        m.setJibLength(n(0));
      case 'set_body_field':
        m.setBodyField(a[0] as String, n(1));
      case 'move_layer':
        m.moveLayer(a[0] as String, a[1] as String);
      case 'begin_pose_drag':
        m.beginPoseDrag();
      case 'end_pose_drag':
        m.endPoseDrag();
      case 'drag_main_tip':
        m.dragMainTip(n(0), n(1), n(2));
      case 'drag_boom_angle':
        m.dragBoomAngle(n(0), n(1), n(2), n(3));
      case 'drag_main_tip_length':
        m.dragMainTipLength(n(0), n(1));
      case 'drag_jib_tip':
        m.dragJibTip(n(0), n(1));
      default:
        throw StateError('不認得的操作：$fn');
    }
  } on OutOfReachError catch (e) {
    return e.message;
  }
  return null;
}

Map<String, Object?> snapshot(SimulationModel m) {
  final r = m.result;
  final rep = m.safety();
  final load = m.load();
  final (wv, wo, ws) = rep.worst;
  final ah = m.auxHookLimit();
  final lc = rep.loadCheck;
  final hr = load == null ? null : m.hoistDragRange(load);
  return {
    'pose': poseMap(m.pose),
    'geo_pose': poseMap(m.geometryPose),
    'droop': m.jibDroop(),
    'limits': limitsMap(m.limits),
    'result': {
      'main_tip': ptList(r.mainTip),
      'head': ptList(r.head),
      'jib_tip': ptList(r.jibTip),
      'aux_tip': ptList(r.auxTip),
      'radius': r.radius,
      'height': r.height,
    },
    'hook': m.hook,
    'hook_choice': m.hookChoice,
    'hook_drop': m.hookDrop,
    'hook_bottom': m.hookBottomHeight,
    'min_hoist': m.minHoist,
    'outrigger': m.outrigger,
    'rigging': m.riggingWeight,
    'deflection': m.deflection,
    'rating': ratingMap(m.loadRating()),
    'reminders': remindersList(m.loadReminders()),
    'parts': m.partsOfLine(),
    'min_angle': m.minBoomAngle(),
    'aux_limit': ah == null ? null : [ah.capacity, ah.net],
    'boom_polyline': ptsList(m.boomPolyline()),
    'main_count': m.boomMainCount(),
    'objects': [for (final o in m.objects()) o.toJson()],
    'safety': {
      'issues': [
        for (final i in rep.issues) [i.level, i.message, i.objId]
      ],
      'status': rep.status,
      'labels': rep.labels,
      'clearances': rep.clearances,
      'body_clearances': rep.bodyClearances,
      'worst': [wv, wo?.id, ws],
      'load_ground': rep.loadGround,
      'support': rep.loadSupport?.id,
      'rigging_tip': ptList(rep.riggingTip),
      'deflected': ptsList(rep.deflectedBoom),
      'checked': rep.checked,
      'level': rep.levelName,
      'load_check': lc == null ? null : {'total': lc.total, 'usage': lc.usage, 'level': lc.levelName},
    },
    'hoist_range': hr == null ? null : [hr.$1, hr.$2],
    'undo': [m.undoStack.count, m.undoStack.index, m.undoStack.undoText, m.undoStack.redoText],
    'body': m.body.toJson(),
  };
}
