/// 模擬狀態模型（移植自 Python 版 models/simulation.py）：吊車姿態 + 圖面物件 + 復原 / 重做。
///
/// 介面只呼叫這裡的方法、監聽 ChangeNotifier 重新繪製；所有改變狀態的操作都推進 undoStack。
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../core/geometry.dart' as geo;
import '../core/geometry.dart' show BoomLimits, BoomPose, OutOfReachError, Pt, TipResult, pt;
import '../core/load_chart.dart';
import '../core/pyformat.dart';
import '../core/vehicle.dart';
import 'crane_spec.dart';
import 'objects.dart';
import 'safety.dart';
import 'undo.dart';

const double jibLengthTol = 0.01;
const double jibOffsetTol = 0.1;
const int nudgeId = 1001;

double _nearest(List<double> allowed, double value) {
  var best = allowed.first;
  for (final v in allowed.skip(1)) {
    if ((v - value).abs() < (best - value).abs()) best = v;
  }
  return best;
}

double _nextListed(List<double> allowed, double base, int steps, double tol) {
  if (steps > 0) {
    for (final v in allowed) {
      if (v > base + tol) return v;
    }
    return allowed.last;
  }
  for (final v in allowed.reversed) {
    if (v < base - tol) return v;
  }
  return allowed.first;
}

List<SceneObject> defaultObjects() => [RectObject(name: '障礙物', x: 8.0, y: 0.0, width: 8.0, height: 8.0)];

bool deepEquals(Object? a, Object? b) {
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final k in a.keys) {
      if (!b.containsKey(k) || !deepEquals(a[k], b[k])) return false;
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!deepEquals(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}

class SimulationModel extends ChangeNotifier {
  final UndoStack undoStack = UndoStack();
  CraneSpec _spec;
  BoomPose _pose;
  VehicleBody _body;
  late BoomLimits _limits;
  double? _outrigger;
  late BoomPose _geoPose;
  late TipResult _result;
  final Map<String, SceneObject> _objs = {};
  List<String> _order = [];
  double _deflection;
  double _rigging = 0.0;
  BoomPose? _poseBefore;
  (Map<String, Map<String, Object?>?>, List<String>)? _editBefore;
  SafetyReport? _safety;
  final BodyCache _bodyCache = {};
  final ShapeCache _shapeCache = {};

  /// 每次變動的種類（介面可用來決定要重畫什麼）。
  bool specChangedFlag = false;

  SimulationModel(CraneSpec spec)
      : _spec = spec,
        _pose = spec.defaultPose,
        _body = spec.body,
        _deflection = spec.tipDeflection {
    _limits = effectiveLimits(spec, spec.body);
    _outrigger = defaultOutrigger(spec);
    _updateResult();
    for (final o in defaultObjects()) {
      _insert(o);
    }
    undoStack.onChanged = () => notifyListeners();
  }

  void _emit({bool spec = false}) {
    _safety = null;
    specChangedFlag = spec;
    notifyListeners();
  }

  // ================================================================ 吊車讀取
  CraneSpec get spec => _spec;

  BoomLimits get limits => _limits;

  /// 車高比規格預設高（或低）多少，臂根鉸點就跟著升（降）多少（pivotFixed 時不連動）。
  static BoomLimits effectiveLimits(CraneSpec spec, VehicleBody body) {
    final dh = spec.pivotFixed ? 0.0 : body.height - spec.body.height;
    final lim = spec.limits;
    final boom = spec.limitBoomLength ? (lim.boomMin, lim.boomMax) : (geo.minLength, double.infinity);
    final jib = spec.limitJibLength ? (lim.jibMin, lim.jibMax) : (geo.minLength, double.infinity);
    return lim.copyWith(
        pivotY: lim.pivotY + dh, boomMin: boom.$1, boomMax: boom.$2, jibMin: jib.$1, jibMax: jib.$2);
  }

  BoomPose get pose => _pose;
  TipResult get result => _result;
  VehicleBody get body => _body;

  BodyLayout bodyLayout() => layoutBody(_body, limits.pivot);

  /// 碰撞用吊臂折線：臂身中心線（鉸點 → 臂頭）→ 臂尖滑輪 →（助臂尖）。
  List<Pt> boomPolyline() {
    final r = _result;
    final List<Pt> pts;
    if (boomMainCount() == 2) {
      pts = [r.pivot, r.mainTip];
    } else {
      final t = geo.radians(_geoPose.angle);
      final o = _spec.boomBodyOffset;
      final dx = -o * math.sin(t), dy = o * math.cos(t);
      final head = r.head ?? r.mainTip;
      pts = [pt(r.pivot.x + dx, r.pivot.y + dy), pt(head.x + dx, head.y + dy), r.mainTip];
    }
    if (r.jibTip != null) pts.add(r.jibTip!);
    return pts;
  }

  int boomMainCount() => (_result.head != null || _spec.boomBodyOffset != 0) ? 3 : 2;

  // ================================================================ 物件讀取
  List<SceneObject> objects() => [for (final i in _order) _objs[i]!];

  SceneObject? get(String id) => _objs[id];

  List<LoadObject> loads() => [
        for (final o in objects())
          if (o is LoadObject && o.visible) o
      ];

  LoadObject? load() {
    for (final o in objects()) {
      if (o is LoadObject) return o;
    }
    return null;
  }

  bool hasLoad() => load() != null;

  /// 吊物實際掛的尖端：有設定下彎量時為下彎後的尖端。
  Pt riggingTip() => safety().riggingTip ?? _result.workingTip;

  List<Pt> loadOutline(LoadObject l) => l.rectAt(riggingTip());

  // ================================================================ 安全檢查
  SafetyReport safety() {
    if (_safety == null) {
      final r = _result;
      final hang = r.auxTip == null ? pt(0, 0) : pt(r.auxTip!.x - r.mainTip.x, r.auxTip!.y - r.mainTip.y);
      final rep = computeSafety(
        objects: objects(),
        boomPoints: boomPolyline(),
        mainCount: boomMainCount(),
        boomHalf: _spec.boomWidth / 2,
        jibHalf: _spec.jibWidth / 2,
        deflection: _deflection,
        body: bodyLayout(),
        hook: hookSetup,
        hangOffset: hang,
        bodyCache: _bodyCache,
        shapeCache: _shapeCache,
      );
      _safety = rep;
      final rating = loadRating();
      final ls = loads();
      final l = ls.isEmpty ? null : ls.first;
      if (rating != null) {
        applyLoadCheck(rep, LoadCheck(rating, l?.weight, _rigging, hooksWeight), l);
      }
      final low = minBoomAngle();
      if (low != null && _pose.angle < low - 1e-9) {
        final clause = _spec.loadCharts!.rules.clause('min_boom_angle');
        rep.issues.add(Issue('collision',
            '臂角 ${fixed(_pose.angle, 2)}° 低於最低作業角度 ${g(low)}°（$clause：即使空載也可能翻車）'));
      }
      final ah = auxHookLimit();
      if (ah != null && ah.net != null && l != null && l.weight > ah.net! + 1e-9) {
        final clause = _spec.loadCharts!.rules.clause('aux_hook');
        rep.issues.add(Issue(
            'collision',
            '吊物 ${fixed(l.weight, 2)} t 超過副吊鉤上限 ${fixed(ah.net!, 2)} t（$clause：主臂用副吊鉤作業，'
                '最多 ${g(ah.limit)} t）',
            l.id));
        rep.status[l.id] = 'collision';
        final label = rep.labels[l.id] ?? '';
        rep.labels[l.id] = label.isNotEmpty ? '$label｜超過副吊鉤上限' : '超過副吊鉤上限';
      }
    }
    return _safety!;
  }

  Map<String, double> objectClearances() => safety().clearances;

  String clearanceStatus(String objId) => safety().status[objId] ?? 'none';

  (double, SceneObject?, String) worstClearance() => safety().worst;

  // ================================================================ 尖端下彎量
  double get deflection => _deflection;

  void _setValue(String key, double? value) {
    final current = switch (key) { 'deflection' => _deflection, 'outrigger' => _outrigger, _ => _rigging };
    if (value == current) return;
    switch (key) {
      case 'deflection':
        _deflection = value!;
      case 'outrigger':
        _outrigger = value;
        _updateResult();
      default:
        _rigging = value!;
    }
    _emit();
  }

  void _pushValue(String key, double? old, double? value, String text) {
    undoStack.push(UndoCommand(text, redo: () => _setValue(key, value), undo: () => _setValue(key, old)));
  }

  void setTipDeflection(double value) {
    if (!(0.0 <= value && value <= 5.0)) throw OutOfReachError('尖端下彎量須在 0–5 m');
    if (value != _deflection) _pushValue('deflection', _deflection, value, '修改尖端下彎量');
  }

  // ================================================================ 吊重表
  static double? defaultOutrigger(CraneSpec spec) => spec.loadCharts?.outriggers.first;

  double? get outrigger => _outrigger;

  void setOutrigger(double value) {
    final charts = _spec.loadCharts;
    if (charts == null) throw OutOfReachError('此型號沒有吊重表');
    if (!charts.outriggers.any((o) => (value - o).abs() < 1e-6)) {
      throw OutOfReachError('支撐座外伸須為 ${charts.outriggers.map((o) => '${g(o)} m').join('、')}');
    }
    if (value != _outrigger) _pushValue('outrigger', _outrigger, value, '切換支撐座外伸');
  }

  // ---------------------------------------------------------------- 吊鉤
  String get hookChoice => _pose.auxHook ? auxHook : mainHook;

  String get hook => _pose.jibEnabled ? auxHook : hookChoice;

  void setHook(String h) {
    if (!hookNames.containsKey(h)) throw OutOfReachError('不認得的吊鉤：$h');
    if (h == auxHook && !_spec.hasAuxHook) throw OutOfReachError('此型號沒有副吊鉤資料');
    if (_pose.jibEnabled && h != auxHook) throw OutOfReachError('副臂作業只能使用副吊鉤');
    _pushPose(_pose.copyWith(auxHook: h == auxHook), '改用${hookNames[h]}');
  }

  HookSetup get hookSetup => _spec.hookSetup(hook, _pose.jibEnabled);
  double get hookBlockHeight => hookSetup.blockHeight;
  double get minHoist => hookSetup.minHoist;
  double get hooksWeight => _spec.hooksWeight;
  double get riggingWeight => _rigging;

  void setRiggingWeight(double value) {
    if (!value.isFinite || !(0.0 <= value && value <= 50.0)) throw OutOfReachError('吊具重量須在 0–50 t');
    if (value != _rigging) _pushValue('rigging', _rigging, value, '修改吊具重量');
  }

  (double, double)? get _jibSel => _pose.jibEnabled ? (_pose.jibLength, _pose.jibOffset) : null;

  Rating? loadRating() {
    final charts = _spec.loadCharts;
    if (charts == null || _outrigger == null) return null;
    final angle = _pose.jibEnabled ? _pose.angle : null;
    return charts.rating(_outrigger!, _pose.length, _result.radius, _jibSel, angle);
  }

  double? minBoomAngle() {
    final charts = _spec.loadCharts;
    if (charts == null || _outrigger == null) return null;
    return charts.minBoomAngle(_outrigger!, _pose.length, _jibSel);
  }

  int? partsOfLine() {
    final charts = _spec.loadCharts;
    if (charts == null || _outrigger == null) return null;
    return charts.partsOfLine(_outrigger!, _pose.length, _result.radius, _jibSel);
  }

  List<Reminder> loadReminders() {
    final charts = _spec.loadCharts;
    if (charts == null || _outrigger == null) return const [];
    final ls = loads();
    return charts.reminders(_outrigger!, _pose.length, _result.radius,
        jibSel: _jibSel,
        boomAngle: _pose.angle,
        attachedWeight: hooksWeight + _rigging,
        loadWeight: ls.isEmpty ? null : ls.first.weight,
        auxHook: hook == auxHook && !_pose.jibEnabled);
  }

  AuxHookLimit? auxHookLimit() {
    final charts = _spec.loadCharts;
    if (charts == null || _outrigger == null || _pose.jibEnabled || hook != auxHook) return null;
    return charts.auxHookLimitFor(_outrigger!, _pose.length, _result.radius, hooksWeight + _rigging);
  }

  // ================================================================ 副臂依荷重表同步
  List<(double, double)> _jibRows(BoomPose p) {
    final charts = _spec.loadCharts;
    if (!p.jibEnabled || charts == null || _outrigger == null) return const [];
    return charts.jibRows(_outrigger!, p.length, (p.jibLength, p.jibOffset));
  }

  double _jibDroop(BoomPose p) {
    final rows = _jibRows(p);
    if (rows.isEmpty) return 0.0;
    final a = geo.clamp(p.angle, rows.first.$1, rows.last.$1);
    var radius = rows.last.$2;
    for (var i = 0; i < rows.length - 1; i++) {
      final (a0, r0) = rows[i];
      final (a1, r1) = rows[i + 1];
      if (a0 <= a && a <= a1) {
        radius = r0 + (r1 - r0) * (a - a0) / (a1 - a0);
        break;
      }
    }
    final rigid = geo.angleForRadiusNear(radius, p.copyWith(angle: a), _limits);
    return rigid == null ? 0.0 : a - rigid;
  }

  BoomPose _geometry(BoomPose p) {
    final d = _jibDroop(p);
    return d == 0.0 ? p : p.copyWith(angle: p.angle - d);
  }

  /// 圖面幾何姿態 → 姿態（副臂同步時臂角換成荷重表作業角度）；二分法。
  BoomPose? _fromGeometry(BoomPose geoPose, {bool clampIt = false}) {
    if (_jibRows(geoPose).isEmpty) return geoPose;
    final lim = _limits;
    var lo = lim.angleMin - 10.0, hi = lim.angleMax + 10.0;
    for (var i = 0; i < 60; i++) {
      final mid = (lo + hi) / 2;
      if (mid - _jibDroop(geoPose.copyWith(angle: mid)) < geoPose.angle) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    final angle = (lo + hi) / 2;
    if (!clampIt && !(lim.angleMin - 1e-6 <= angle && angle <= lim.angleMax + 1e-6)) return null;
    return geoPose.copyWith(angle: geo.clamp(angle, lim.angleMin, lim.angleMax));
  }

  void _updateResult() {
    _geoPose = _geometry(_pose);
    _result = geo.solve(_geoPose, _limits);
  }

  BoomPose get geometryPose => _geoPose;

  double jibDroop() => _pose.angle - _geoPose.angle;

  // ================================================================ 內部：姿態
  void _setPose(BoomPose p) {
    p = geo.clampPose(p, limits);
    if (p == _pose) return;
    _pose = p;
    _updateResult();
    _emit();
  }

  void _pushPose(BoomPose newPose, String text) {
    newPose = geo.clampPose(newPose, limits);
    if (newPose != _pose) {
      final old = _pose;
      undoStack.push(UndoCommand(text, redo: () => _setPose(newPose), undo: () => _setPose(old)));
    }
  }

  void _setSpec((CraneSpec, BoomPose, VehicleBody, double, double?, double) s) {
    final (spec, p, body, deflection, outrigger, rigging) = s;
    _spec = spec;
    _body = body;
    _deflection = deflection;
    _outrigger = outrigger;
    _rigging = rigging;
    _limits = effectiveLimits(spec, body);
    _pose = geo.clampPose(p, _limits);
    _updateResult();
    _emit(spec: true);
  }

  // ================================================================ 吊車
  void setSpec(CraneSpec spec) {
    final jib = _pose.jibEnabled && spec.jibAvailable;
    final newPose = geo.clampPose(spec.defaultPose.copyWith(jibEnabled: jib), spec.limits);
    final old = (_spec, _pose, _body, _deflection, _outrigger, _rigging);
    final nw = (spec, newPose, spec.body, spec.tipDeflection, defaultOutrigger(spec), 0.0);
    undoStack.push(UndoCommand('切換吊車：${spec.name}', redo: () => _setSpec(nw), undo: () => _setSpec(old)));
  }

  // ---------------------------------------------------------------- 車體尺寸
  void _setBody(VehicleBody b) {
    if (b != _body) {
      _body = b;
      _limits = effectiveLimits(_spec, b);
      _updateResult();
      _emit();
    }
  }

  void setBodyField(String key, double value) {
    final nw = _body.withField(key, value);
    final err = validateBody(nw, _spec.limits.pivotX);
    if (err != null) throw OutOfReachError(err);
    if (nw != _body) {
      final old = _body;
      undoStack.push(UndoCommand('修改${bodyLabels[key]}', redo: () => _setBody(nw), undo: () => _setBody(old)));
    }
  }

  void resetBody() {
    if (_spec.body != _body) {
      final old = _body, nw = _spec.body;
      undoStack.push(UndoCommand('車體尺寸還原預設', redo: () => _setBody(nw), undo: () => _setBody(old)));
    }
  }

  /// 開新專案：還原預設姿態與物件，清空復原紀錄。
  void reset() {
    _objs.clear();
    _order.clear();
    for (final o in defaultObjects()) {
      _insert(o);
    }
    _pose = _spec.defaultPose;
    _body = _spec.body;
    _deflection = _spec.tipDeflection;
    _outrigger = defaultOutrigger(_spec);
    _rigging = 0.0;
    _limits = effectiveLimits(_spec, _body);
    _updateResult();
    _poseBefore = null;
    _editBefore = null;
    undoStack.clear();
    _emit();
  }

  // ---------------------------------------------------------------- 參數輸入
  static void _checkLength(double value, double lo, double hi, String name) {
    if (!value.isFinite || value < lo - 1e-9 || value > hi + 1e-9) {
      if (hi.isInfinite) throw OutOfReachError('$name須大於 ${fixed(lo, 1)} m');
      throw OutOfReachError('$name須在 ${fixed(lo, 2)}–${fixed(hi, 2)} m');
    }
  }

  void setBoomLength(double value) {
    _checkLength(value, limits.boomMin, limits.boomMax, '臂長');
    _pushPose(_pose.copyWith(length: value), '修改臂長');
  }

  void setBoomAngle(double value) {
    final lim = limits;
    if (!(lim.angleMin - 1e-9 <= value && value <= lim.angleMax + 1e-9)) {
      throw OutOfReachError('臂角須在 ${fixed(lim.angleMin, 0)}°–${fixed(lim.angleMax, 0)}°');
    }
    _pushPose(_pose.copyWith(angle: value), '修改臂角');
  }

  void setRadius(double value) =>
      _pushPose(_solveInput(geo.poseWithRadius, value, '半徑 ${fixed(value, 2)} m '), '修改半徑');

  void setTipHeight(double value) =>
      _pushPose(_solveInput(geo.poseWithHeight, value, '高度 ${fixed(value, 2)} m '), '修改尖端高度');

  /// 吊掛滑輪中心到「吊鉤收到最高時的鉤底」的距離 (m)。
  double get hookDrop => hookSetup.drop;

  /// 鉤底離地高度：目前吊鉤收到最高時的鉤底（吊車電腦顯示的高度）。
  double get hookBottomHeight => _result.height - hookDrop;

  void setHookBottomHeight(double value) {
    final drop = hookDrop;
    final BoomPose p;
    try {
      p = _solveInput(geo.poseWithHeight, value + drop, '鉤底離地高度 ${fixed(value, 2)} m ');
    } on OutOfReachError catch (e) {
      throw OutOfReachError('鉤底離地高度 ${fixed(value, 2)} m（滑輪中心 ${fixed(value + drop, 2)} m）：$e');
    }
    _pushPose(p, '修改鉤底離地高度');
  }

  BoomPose _solveInput(BoomPose Function(double, BoomPose, BoomLimits) fn, double value, String what) {
    final p = _fromGeometry(fn(value, _geoPose, limits));
    if (p == null) {
      final lim = limits;
      throw OutOfReachError('$what需要臂角超出範圍 ${fixed(lim.angleMin, 0)}°–${fixed(lim.angleMax, 0)}°'
          '（副臂依荷重表含吊臂下彎）');
    }
    return p;
  }

  void setJibEnabled(bool on) {
    if (on && !_spec.jibAvailable) throw OutOfReachError('此型號沒有助臂');
    _pushPose(_pose.copyWith(jibEnabled: on), on ? '開啟助臂' : '關閉助臂');
  }

  void setJibLength(double value) {
    _checkLength(value, limits.jibMin, limits.jibMax, '助臂長度');
    final allowed = _spec.jibLengths;
    if (allowed.isNotEmpty) {
      final match = [for (final v in allowed) if ((v - value).abs() <= jibLengthTol) v];
      if (match.isEmpty) throw OutOfReachError('助臂長度只有 ${allowed.map((v) => fixed(v, 2)).join('、')} m');
      value = match.first;
    }
    _pushPose(_pose.copyWith(jibLength: value), '修改助臂長度');
  }

  double nextJibLength(double base, int steps) {
    final allowed = _spec.jibLengths;
    if (allowed.isEmpty) return pyRound(base + steps * 0.1, 2);
    return _nextListed(allowed, base, steps, jibLengthTol);
  }

  double nextJibOffset(double base, int steps) {
    final allowed = _spec.jibOffsets;
    if (allowed.isEmpty) return pyRound(base + steps * 1.0, 2);
    return _nextListed(allowed, base, steps, jibOffsetTol);
  }

  BoomPose _snapJib(BoomPose p) {
    if (_spec.jibLengths.isNotEmpty) p = p.copyWith(jibLength: _nearest(_spec.jibLengths, p.jibLength));
    if (_spec.jibOffsets.isNotEmpty) p = p.copyWith(jibOffset: _nearest(_spec.jibOffsets, p.jibOffset));
    return p;
  }

  void setJibOffset(double value) {
    final lim = limits;
    if (!(lim.jibOffsetMin - 1e-9 <= value && value <= lim.jibOffsetMax + 1e-9)) {
      throw OutOfReachError('助臂角度須在 ${fixed(lim.jibOffsetMin, 0)}°–${fixed(lim.jibOffsetMax, 0)}°');
    }
    final allowed = _spec.jibOffsets;
    if (allowed.isNotEmpty) {
      final match = [for (final v in allowed) if ((v - value).abs() <= jibOffsetTol) v];
      if (match.isEmpty) throw OutOfReachError('助臂角度只有 ${allowed.map((v) => '${g(v)}°').join('、')}');
      value = match.first;
    }
    _pushPose(_pose.copyWith(jibOffset: value), '修改助臂角度');
  }

  // ---------------------------------------------------------------- 拖曳（放開後才記一步復原）
  void beginPoseDrag() => _poseBefore = _pose;

  void endPoseDrag([String text = '拖曳吊臂']) {
    final before = _poseBefore;
    _poseBefore = null;
    if (before != null && before != _pose) {
      final after = _pose;
      undoStack.push(UndoCommand(text, redo: () => _setPose(after), undo: () => _setPose(before)));
    }
  }

  bool get dragging => _poseBefore != null;

  void _drag(BoomPose p) {
    if (_poseBefore == null) {
      _pushPose(p, '拖曳吊臂');
    } else {
      _setPose(p);
    }
  }

  /// 半徑離表列半徑 tol 公尺內時，改臂角讓半徑剛好等於表列值（臂長不變）。
  BoomPose _snapRadius(BoomPose p, double tol) {
    final charts = _spec.loadCharts;
    if (tol <= 0 || charts == null || _outrigger == null) return p;
    final jibSel = p.jibEnabled ? (p.jibLength, p.jibOffset) : null;
    final radii = charts.listedRadii(_outrigger!, p.length, jibSel);
    if (radii.isEmpty) return p;
    final gp = _geometry(p);
    final radius = geo.solve(gp, limits).radius;
    var target = radii.first;
    for (final r in radii.skip(1)) {
      if ((r - radius).abs() < (target - radius).abs()) target = r;
    }
    if ((target - radius).abs() > tol) return p;
    final angle = geo.angleForRadiusNear(target, gp, limits);
    final nw = angle == null ? null : _fromGeometry(gp.copyWith(angle: angle));
    return nw ?? p;
  }

  void dragMainTip(double x, double y, [double snap = 0.0]) {
    final nw = _fromGeometry(geo.poseFromMainTipDrag(pt(x, y), _geoPose, limits), clampIt: true)!;
    _drag(_snapRadius(nw, snap));
  }

  double boomGrabOffset(double x, double y) => _pose.angle - geo.pointerAngle(pt(x, y), limits);

  void dragBoomAngle(double x, double y, [double offsetDeg = 0.0, double snap = 0.0]) {
    final p = geo.poseFromBoomAngleDrag(pt(x, y), _pose, limits, offsetDeg);
    _drag(_snapRadius(p, snap));
  }

  void dragMainTipLength(double x, double y) {
    final nw = geo.poseFromTipLengthDrag(pt(x, y), _geoPose, limits);
    _drag(nw.copyWith(angle: _pose.angle));
  }

  void dragJibTip(double x, double y) {
    final nw = geo.poseFromJibTipDrag(pt(x, y), _geoPose, limits);
    _drag(_snapJib(nw.copyWith(angle: _pose.angle)));
  }

  // ---------------------------------------------------------------- 吊物：拖曳改吊掛長度
  (double, double) hoistDragRange(LoadObject l) {
    final lo = math.min(minHoist, l.hoist);
    final tip = riggingTip();
    final rect = l.rectAt(tip);
    final visible = [for (final o in objects()) if (o.visible) o];
    final grounds = visible.whereType<GroundObject>().toList();
    final (gl, _) = supportLevel(grounds, loadSupports(visible), rect[0].x, rect[1].x);
    var hi = tip.y - l.sling - l.height - gl;
    hi = [hi, l.hoist, lo].reduce(math.max);
    return (lo, hi);
  }

  // ================================================================ 內部：物件
  void _insert(SceneObject obj, [int? index]) {
    _objs[obj.id] = obj;
    if (!_order.contains(obj.id)) {
      if (index == null) {
        _order.add(obj.id);
      } else {
        _order.insert(index, obj.id);
      }
    }
  }

  Map<String, Map<String, Object?>?> _snapshot(Iterable<String> ids) =>
      {for (final i in ids) i: _objs[i]?.toJson()};

  void _restore(Map<String, Map<String, Object?>?> states, List<String> order) {
    for (final MapEntry(key: oid, value: d) in states.entries) {
      if (d == null) {
        _objs.remove(oid);
      } else {
        _objs[oid] = objectFromJson(d);
      }
    }
    _order = [for (final i in order) if (_objs.containsKey(i)) i];
    for (final oid in _objs.keys) {
      if (!_order.contains(oid)) _order.add(oid);
    }
    _emit();
  }

  UndoCommand _objectsCommand(Map<String, Map<String, Object?>?> before, Map<String, Map<String, Object?>?> after,
      List<String> orderBefore, List<String> orderAfter, String text,
      [int mergeKey = -1]) {
    var aft = after;
    var ordAft = orderAfter;
    return UndoCommand(text,
        id: mergeKey,
        redo: () => _restore(aft, ordAft),
        undo: () => _restore(before, orderBefore),
        mergeWith: (next) {
          final st = next as _ObjectsCmd;
          if (!deepEquals(st.after.keys.toSet().toList()..sort(), aft.keys.toSet().toList()..sort())) return false;
          aft = st.after;
          ordAft = st.orderAfter;
          return true;
        });
  }

  void _transaction(Iterable<String> ids, String label, void Function() body, [int mergeKey = -1]) {
    final idList = ids.toList();
    final before = _snapshot(idList);
    final orderBefore = List.of(_order);
    body();
    final after = _snapshot(idList);
    if (deepEquals(before, after) && deepEquals(orderBefore, _order)) return;
    final orderAfter = List.of(_order);
    final cmd = _objectsCommand(before, after, orderBefore, orderAfter, label, mergeKey);
    undoStack.push(_ObjectsCmd(cmd, after, orderAfter));
  }

  void _setFields(String oid, Map<String, Object?> fields) {
    final obj = _objs[oid];
    if (obj != null && fields.isNotEmpty) _objs[oid] = obj.copyWith(fields);
  }

  // ================================================================ 物件操作（可復原）
  String addObject(SceneObject obj, {String? label, int? index}) {
    if (obj is LoadObject && hasLoad()) throw OutOfReachError('圖上已經有吊物（只能有一個）');
    _transaction([obj.id], label ?? '新增${obj.label}', () => _insert(obj, index));
    return obj.id;
  }

  void removeObjects(Iterable<String> ids) {
    final list = [for (final i in ids) if (_objs.containsKey(i)) i];
    if (list.isEmpty) return;
    _transaction(list, '刪除 ${list.length} 個物件', () {
      for (final i in list) {
        _objs.remove(i);
      }
      _order = [for (final i in _order) if (_objs.containsKey(i)) i];
    });
  }

  void updateObject(String oid, Map<String, Object?> fields, [String label = '修改屬性']) {
    if (!_objs.containsKey(oid)) return;
    _transaction([oid], label, () => _setFields(oid, fields));
  }

  void updateObjects(Iterable<String> ids, Map<String, Object?> fields, [String label = '修改屬性']) {
    final list = [for (final i in ids) if (_objs.containsKey(i)) i];
    if (list.isEmpty) return;
    _transaction(list, label, () {
      for (final i in list) {
        _setFields(i, fields);
      }
    });
  }

  void translateObjects(Iterable<String> ids, double dx, double dy, {String label = '移動物件', bool merge = false}) {
    final list = [for (final i in ids) if (_objs.containsKey(i) && !_objs[i]!.locked) i];
    if (list.isEmpty || (dx == 0 && dy == 0)) return;
    _transaction(list, label, () {
      for (final i in list) {
        _setFields(i, _objs[i]!.translated(dx, dy));
      }
    }, merge ? nudgeId : -1);
  }

  void reorder(List<String> orderBottomToTop) {
    final order = [for (final i in orderBottomToTop) if (_objs.containsKey(i)) i];
    order.addAll([for (final i in _order) if (!order.contains(i)) i]);
    if (deepEquals(order, _order)) return;
    _transaction(const [], '調整圖層順序', () => _order = order);
  }

  /// where: up / down / top / bottom
  void moveLayer(String oid, String where) {
    if (!_order.contains(oid)) return;
    final order = List.of(_order);
    final i = order.indexOf(oid);
    order.removeAt(i);
    final j = switch (where) { 'up' => i + 1, 'down' => math.max(0, i - 1), 'top' => order.length, _ => 0 };
    order.insert(math.min(j, order.length), oid);
    reorder(order);
  }

  // ---------------------------------------------------------------- 即時編輯（拖曳控制點、移動）
  void beginEdit(Iterable<String> ids) => _editBefore = (_snapshot(ids.toList()), List.of(_order));

  void setObjectLive(String oid, Map<String, Object?> fields) {
    _setFields(oid, fields);
    _emit();
  }

  void endEdit(String text) {
    final eb = _editBefore;
    if (eb == null) return;
    _editBefore = null;
    final (before, orderBefore) = eb;
    final after = _snapshot(before.keys);
    if (!deepEquals(before, after) || !deepEquals(orderBefore, _order)) {
      final orderAfter = List.of(_order);
      undoStack.push(_ObjectsCmd(_objectsCommand(before, after, orderBefore, orderAfter, text), after, orderAfter));
    }
  }

  bool get editing => _editBefore != null;

  // ---------------------------------------------------------------- 剪貼簿
  List<Map<String, Object?>> exportObjects(Iterable<String> ids) {
    final set = ids.toSet();
    return [for (final i in _order) if (set.contains(i)) _objs[i]!.toJson()];
  }

  List<String> pasteObjects(List<Map<String, Object?>> dicts, [double dx = 1.0, double dy = 0.0]) {
    final newObjs = <SceneObject>[];
    var loadTaken = hasLoad();
    for (final d in dicts) {
      if (d['kind'] == 'load') {
        if (loadTaken) continue;
        loadTaken = true;
      }
      var o = objectFromJson({...d, 'id': newId()});
      if (o.movable) o = o.copyWith(o.translated(dx, dy));
      newObjs.add(o);
    }
    if (newObjs.isEmpty) return const [];
    final ids = [for (final o in newObjs) o.id];
    _transaction(ids, '貼上 ${ids.length} 個物件', () {
      for (final o in newObjs) {
        _insert(o);
      }
    });
    return ids;
  }

  // ---------------------------------------------------------------- 專案存檔
  Map<String, Object?> toProject() => {
        'format': 'crane-sim-project',
        'version': 1,
        'crane': _spec.id,
        'pose': _pose.toJson(),
        'body': _body.toJson(),
        'deflection': _deflection,
        'outrigger': _outrigger,
        'rigging': _rigging,
        'objects': [for (final o in objects()) o.toJson()],
      };

  /// 開啟專案：吊車型號要和目前相同（由呼叫端先切換）；清空復原紀錄。
  void loadProject(Map<String, Object?> d) {
    final objs = [for (final o in (d['objects'] as List?) ?? const []) objectFromJson(o as Map<String, Object?>)];
    _objs.clear();
    _order.clear();
    for (final o in objs) {
      _insert(o);
    }
    _body = d['body'] == null ? _spec.body : VehicleBody.fromJson(d['body'] as Map<String, dynamic>);
    _limits = effectiveLimits(_spec, _body);
    _pose = d['pose'] == null ? _spec.defaultPose : geo.clampPose(BoomPose.fromJson(d['pose'] as Map<String, dynamic>), _limits);
    _deflection = (d['deflection'] as num?)?.toDouble() ?? _spec.tipDeflection;
    final out = (d['outrigger'] as num?)?.toDouble();
    final outs = _spec.loadCharts?.outriggers ?? const <double>[];
    _outrigger = out != null && outs.any((o) => (o - out).abs() < 1e-6) ? out : defaultOutrigger(_spec);
    _rigging = (d['rigging'] as num?)?.toDouble() ?? 0.0;
    _updateResult();
    _poseBefore = null;
    _editBefore = null;
    undoStack.clear();
    _emit(spec: true);
  }
}

/// 物件指令：記住 after 給合併判斷用。
class _ObjectsCmd extends UndoCommand {
  final Map<String, Map<String, Object?>?> after;
  final List<String> orderAfter;

  _ObjectsCmd(UndoCommand inner, this.after, this.orderAfter)
      : super(inner.text, redo: inner.redo, undo: inner.undo, id: inner.id, mergeWith: inner.mergeWith);
}
