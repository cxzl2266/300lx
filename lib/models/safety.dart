/// 安全檢查報告（移植自 Python 版 models/safety.py；判斷與訊息相同）。
///
/// 1. 障礙物淨空：主臂、助臂（扣半寬）、鋼索、吊鉤組、吊索、吊物 → 各「參與碰撞檢查」物件
/// 2. 車身：各障礙物、吊物 → 車身各部位
/// 3. 地面：吊物底部、掛鉤、主臂尖端、助臂尖端 → 該處地面（或聯結車車頂）
/// 4. 過捲：吊鉤頂距滑輪中心 < 過捲極限 + 0.30 m 警告；< 過捲極限 紅色
/// 5. 吊重表：使用率 ≥ 90% 警告、> 100% 或無額定值紅色
library;

import 'dart:math' as math;

import '../core/collision.dart';
import '../core/geometry.dart';
import '../core/load_chart.dart';
import '../core/pyformat.dart';
import '../core/vehicle.dart';
import 'crane_spec.dart';
import 'objects.dart';

const Map<String, int> level = {'none': 0, 'ok': 0, 'info': 1, 'warning': 2, 'collision': 3};
const double loadBodyMargin = 0.5;
const double groundTouch = 0.05;
const double groundEps = 0.01;
const double usageCaution = 0.80;
const double usageWarning = 0.90;

class Issue {
  final String level; // info / warning / collision
  final String message;
  final String? objId;

  const Issue(this.level, this.message, [this.objId]);
}

/// 吊重表檢查：額定總荷重 vs 實際吊重（吊物 + 吊鉤 + 吊具）。
class LoadCheck {
  final Rating rating;
  final double? loadWeight;
  final double riggingWeight;
  final double hookWeight;

  const LoadCheck(this.rating, this.loadWeight, this.riggingWeight, [this.hookWeight = 0.0]);

  double? get total => loadWeight == null ? null : loadWeight! + hookWeight + riggingWeight;

  bool get valid => total != null && total!.isFinite;

  double? get usage {
    final cap = rating.capacity;
    if (!valid || cap == null) return null;
    return total! / cap;
  }

  /// 'none' / 'ok' / 'caution' / 'warning' / 'collision'
  String get levelName {
    if (loadWeight == null) return 'none';
    final u = usage;
    if (u == null || u > 1.0 + 1e-9) return 'collision';
    if (u >= usageWarning - 1e-9) return 'warning';
    if (u >= usageCaution - 1e-9) return 'caution';
    return 'ok';
  }
}

/// 把吊重表檢查結果併入安全報告。
void applyLoadCheck(SafetyReport rep, LoadCheck check, LoadObject? load) {
  rep.loadCheck = check;
  if (load == null || check.loadWeight == null) return;
  final name = load.name.isNotEmpty ? load.name : load.label;
  final lv = check.levelName;
  String tag;
  if (!check.valid) {
    tag = '重量無效';
    rep.issues.add(Issue('collision', '「$name」重量不是有效數字，無法計算使用率', load.id));
  } else if (check.rating.capacity == null) {
    tag = '無額定荷重';
    rep.issues.add(Issue('collision', '「$name」無適用額定荷重：${check.rating.basis}', load.id));
  } else {
    final pct = check.usage! * 100;
    tag = '使用率 ${fixed(pct, 1)}%';
    if (lv == 'collision') {
      tag = '超載 ${fixed(pct, 1)}%';
      rep.issues.add(Issue(
          'collision',
          '超過額定荷重：實際 ${fixed(check.total!, 2)} t ＞ 額定 ${fixed(check.rating.capacity!, 2)} t'
              '（使用率 ${fixed(pct, 1)}%）',
          load.id));
    } else if (lv == 'warning') {
      rep.issues.add(Issue('warning', '吊重使用率 ${fixed(pct, 1)}%（≥ ${percent0(usageWarning)}）', load.id));
    }
  }
  final st = switch (lv) { 'collision' => 'collision', 'warning' => 'warning', _ => 'ok' };
  if (level[st]! > level[rep.status[load.id] ?? 'ok']!) rep.status[load.id] = st;
  final old = rep.labels[load.id] ?? '';
  rep.labels[load.id] = old.isNotEmpty ? '$old｜$tag' : tag;
}

class SafetyReport {
  final Map<String, double> clearances = {};
  final Map<String, double> bodyClearances = {};
  final Map<String, String> status = {};
  final Map<String, String> labels = {};
  final List<Issue> issues = [];
  (double, SceneObject?, String) worst = (double.infinity, null, 'none');
  double? loadGround;
  SceneObject? loadSupport;
  Pt? riggingTip;
  List<Pt> deflectedBoom = [];
  int checked = 0;
  LoadCheck? loadCheck;

  String get levelName {
    var best = 'ok';
    for (final i in issues) {
      if (level[i.level]! > level[best]!) best = i.level;
    }
    return best;
  }

  Issue? topIssue() {
    if (issues.isEmpty) return null;
    var best = issues.first;
    for (final i in issues.skip(1)) {
      if (level[i.level]! > level[best.level]!) best = i;
    }
    return best;
  }
}

// ====================================================================== 地面
double groundLevel(List<GroundObject> grounds, double x) {
  for (final g in grounds.reversed) {
    if (g.covers(x)) return g.elevation;
  }
  return 0.0;
}

double groundMax(List<GroundObject> grounds, double a, double b) {
  final lo = math.min(a, b), hi = math.max(a, b);
  final cuts = <double>{lo, hi};
  for (final g in grounds) {
    for (final x in [g.x1, g.x2]) {
      if (lo < x && x < hi) cuts.add(x);
    }
  }
  final xs = cuts.toList()..sort();
  final probes = [...xs, for (var i = 0; i < xs.length - 1; i++) (xs[i] + xs[i + 1]) / 2];
  return probes.map((x) => groundLevel(grounds, x)).reduce(math.max);
}

/// [a, b] 範圍內吊物最先碰到的面：(高程, 物件)。物件為 null 表示是地面。
(double, SceneObject?) supportLevel(List<GroundObject> grounds, List<SceneObject> supports, double a, double b) {
  var lv = groundMax(grounds, a, b);
  SceneObject? who;
  for (final s in supports) {
    final t = (s as TruckObject).topMax(a, b);
    if (t != null && t > lv) {
      lv = t;
      who = s;
    }
  }
  return (lv, who);
}

List<SceneObject> loadSupports(List<SceneObject> objects) => [
      for (final o in objects)
        if (o.supportsLoad && o.activeCollision) o
    ];

// ====================================================================== 主要計算
double _minClearance(List<(Prepared, double)> parts, Prepared shape) {
  final sb = shape.box;
  final order = [for (final (pp, pad) in parts) (bboxDistance(pp.box, sb) - pad, pp, pad)];
  // Python sorted(key=lower) 是穩定排序
  final idx = List.generate(order.length, (i) => i)
    ..sort((i, j) {
      final c = order[i].$1.compareTo(order[j].$1);
      return c != 0 ? c : i.compareTo(j);
    });
  var best = double.infinity;
  for (final i in idx) {
    final (lower, pp, pad) = order[i];
    if (lower >= best) break;
    final d = preparedDistance(pp, shape, best + pad);
    best = math.min(best, d - pad);
  }
  return best;
}

/// 車身距離快取：物件 id → (物件, 車身外形代碼, 距車身)。
typedef BodyCache = Map<String, (SceneObject, String, double)>;

/// 碰撞外形快取：物件 id → (物件, 預先整理好的形狀)。
typedef ShapeCache = Map<String, (SceneObject, Prepared)>;

String _bodyKey(List<(String, Shape)> shapes) =>
    shapes.map((s) => '${s.$2.$2}:${s.$2.$1.map((p) => '${p.x},${p.y}').join(';')}').join('|');

SafetyReport computeSafety({
  required List<SceneObject> objects,
  required List<Pt> boomPoints,
  int? mainCount,
  required double boomHalf,
  required double jibHalf,
  required double deflection,
  required BodyLayout body,
  required HookSetup hook,
  Pt hangOffset = (x: 0.0, y: 0.0),
  BodyCache? bodyCache,
  ShapeCache? shapeCache,
}) {
  final rep = SafetyReport();
  final visible = [for (final o in objects) if (o.visible) o];
  final grounds = visible.whereType<GroundObject>().toList();
  final supports = loadSupports(visible);
  LoadObject? load;
  for (final o in visible) {
    if (o is LoadObject) {
      load = o;
      break;
    }
  }

  // ---------------- 吊臂（含下彎）
  const samples = 6;
  final nMain = mainCount ?? 2;
  final hasJib = boomPoints.length > nMain;
  List<Pt> pts, mainPts, jibPts;
  if (deflection > 0) {
    pts = deflectedPolyline(boomPoints, deflection, samples);
    rep.deflectedBoom = pts;
    final k = (nMain - 1) * samples;
    mainPts = pts.sublist(0, k + 1);
    jibPts = hasJib ? pts.sublist(k) : [];
  } else {
    pts = List.of(boomPoints);
    mainPts = pts.sublist(0, math.min(nMain, pts.length));
    jibPts = hasJib ? pts.sublist(nMain - 1) : [];
  }
  final tip = pt(pts.last.x + hangOffset.x, pts.last.y + hangOffset.y);
  rep.riggingTip = tip;

  final rawParts = <(List<Pt>, bool, double)>[(mainPts, false, boomHalf)];
  if (jibPts.isNotEmpty) rawParts.add((jibPts, false, jibHalf));
  final loadShapes = load != null ? load.riggingShapes(tip, hook.blockHeight) : <Shape>[];
  rawParts.addAll([for (final (p, c) in loadShapes) (p, c, 0.0)]);
  final parts = [for (final (p, c, pad) in rawParts) (Prepared(p, c), pad)];
  final partsRigging = loadShapes.isNotEmpty ? parts.sublist(0, parts.length - 1) : parts;

  List<Pt>? loadRect;
  if (load != null) {
    loadRect = load.rectAt(tip);
    final (lv, who) = supportLevel(grounds, supports, loadRect[0].x, loadRect[1].x);
    rep.loadSupport = who;
    rep.loadGround = loadRect[0].y - lv;
  }

  final bodyShapes = body.shapes();
  final bodyParts = [for (final (_, (p, c)) in bodyShapes) (Prepared(p, c), 0.0)];
  final bodyKey = _bodyKey(bodyShapes);

  // ---------------- 1 + 2. 障礙物：淨空與車身
  var worstKey = double.infinity;
  for (final o in visible) {
    if (!o.activeCollision) continue;
    final shape = o.collisionShape();
    if (shape == null) continue;
    rep.checked += 1;
    final pc = shapeCache?[o.id];
    final Prepared prep;
    if (pc != null && identical(pc.$1, o)) {
      prep = pc.$2;
    } else {
      prep = Prepared(shape.$1, shape.$2);
      shapeCache?[o.id] = (o, prep);
    }
    final resting = o.supportsLoad &&
        identical(rep.loadSupport, o) &&
        rep.loadGround != null &&
        rep.loadGround! <= groundTouch;
    var c = _minClearance(resting ? partsRigging : parts, prep);
    final pressed = identical(rep.loadSupport, o) && rep.loadGround != null && rep.loadGround! < -groundEps;
    final cached = bodyCache?[o.id];
    final double cb;
    if (cached != null && identical(cached.$1, o) && cached.$2 == bodyKey) {
      cb = cached.$3;
    } else {
      cb = _minClearance(bodyParts, prep);
      bodyCache?[o.id] = (o, bodyKey, cb);
    }
    rep.clearances[o.id] = c;
    rep.bodyClearances[o.id] = cb;
    final name = o.name.isNotEmpty ? o.name : o.label;
    String st, lab;
    if (c <= 0) {
      st = 'collision';
      lab = '碰撞！';
      rep.issues.add(Issue('collision', '「$name」與吊臂或吊物碰撞', o.id));
    } else if (pressed) {
      st = 'collision';
      lab = '吊物壓入 ${fixed(-rep.loadGround!, 2)} m';
      c = math.min(c, rep.loadGround!);
      rep.clearances[o.id] = c;
    } else if (cb <= 0) {
      st = 'collision';
      lab = '與吊車車身重疊';
      rep.issues.add(Issue('collision', '「$name」與吊車車身重疊', o.id));
    } else {
      st = 'ok';
      lab = '淨空 ${fixed(c, 2)} m';
      if (c < o.margin) {
        st = 'warning';
        rep.issues.add(Issue('warning', '「$name」淨空 ${fixed(c, 2)} m，小於安全間距 ${fixed(o.margin, 1)} m', o.id));
      }
      if (cb < o.margin) {
        st = 'warning';
        lab += '｜距吊車車身 ${fixed(cb, 2)} m';
        rep.issues.add(Issue('warning', '「$name」距吊車車身 ${fixed(cb, 2)} m，小於安全間距 ${fixed(o.margin, 1)} m', o.id));
      }
    }
    rep.status[o.id] = st;
    rep.labels[o.id] = lab;
    final key = c - o.margin;
    if (key < worstKey) {
      worstKey = key;
      rep.worst = (c, o, st);
    }
  }

  // ---------------- 3. 地面（主臂 / 助臂尖端）
  final mainTipP = mainPts.last;
  for (final (name, p) in [('主臂尖端', mainTipP), ('助臂尖端', jibPts.isNotEmpty ? jibPts.last : null)]) {
    if (p != null && p.y < groundLevel(grounds, p.x) - groundEps) {
      rep.issues.add(Issue('collision', '$name低於地面'));
    }
  }

  // ---------------- 吊物：地面 / 車頂、過捲、車身
  if (load != null) {
    var lst = 'ok';
    final llabels = <String>[];
    final name = load.name.isNotEmpty ? load.name : load.label;
    final lg = rep.loadGround!;
    final sup = rep.loadSupport;
    final sname = sup != null ? (sup.name.isNotEmpty ? sup.name : sup.label) : '';
    if (lg < -groundEps) {
      lst = 'collision';
      if (sup == null) {
        llabels.add('低於地面 ${fixed(-lg, 2)} m');
        rep.issues.add(Issue('collision', '「$name」低於地面 ${fixed(-lg, 2)} m', load.id));
      } else {
        llabels.add('壓到$sname ${fixed(-lg, 2)} m');
        rep.issues.add(Issue('collision', '「$name」壓到「$sname」${fixed(-lg, 2)} m', load.id));
      }
    } else if (lg <= groundTouch) {
      lst = 'info';
      if (sup == null) {
        llabels.add('著地');
        rep.issues.add(Issue('info', '「$name」著地', load.id));
      } else {
        llabels.add('放置在車上');
        rep.issues.add(Issue('info', '「$name」放置在「$sname」上', load.id));
      }
    } else {
      llabels.add(sup == null ? '離地 ${fixed(lg, 2)} m' : '離車頂 ${fixed(lg, 2)} m');
      final hookPt = load.hookAt(tip);
      if (hookPt.y < groundLevel(grounds, hookPt.x) - groundEps) {
        lst = 'collision';
        rep.issues.add(Issue('collision', '掛鉤低於地面', load.id));
      }
    }

    final over = hook.overhoistState(load.hoist);
    final where = '${hook.name}頂距${hook.sheave} ${fixed(hook.topGap(load.hoist), 2)} m';
    if (over == 'over') {
      lst = 'collision';
      llabels.add('超過過捲極限');
      rep.issues.add(Issue('collision', '超過過捲極限：$where，小於過捲極限 ${fixed(hook.overhoist, 3)} m（原廠）', load.id));
    } else if (over == 'near') {
      if (level[lst]! < level['warning']!) lst = 'warning';
      llabels.add('接近過捲');
      rep.issues.add(Issue(
          'warning',
          '接近過捲：$where（過捲極限 ${fixed(hook.overhoist, 3)} m，提早 ${fixed(hook.warning, 2)} m 警告）',
          load.id));
    }

    var lb = double.infinity;
    for (final (p, c) in loadShapes.skip(1)) {
      lb = math.min(lb, _minClearance(bodyParts, Prepared(p, c)));
    }
    if (lb <= 0) {
      lst = 'collision';
      llabels.add('碰到吊車車身');
      rep.issues.add(Issue('collision', '「$name」碰到吊車車身', load.id));
    } else if (lb < loadBodyMargin) {
      if (level[lst]! < level['warning']!) lst = 'warning';
      llabels.add('距吊車車身 ${fixed(lb, 2)} m');
      rep.issues.add(Issue('warning', '「$name」距吊車車身 ${fixed(lb, 2)} m', load.id));
    }
    rep.status[load.id] = lst;
    rep.labels[load.id] = llabels.join('｜');
  }
  return rep;
}
