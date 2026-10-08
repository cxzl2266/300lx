/// 吊臂幾何計算核心（移植自 Python 版 core/geometry.py，公式與訊息相同）。
///
/// 座標系：單位公尺，X 向右為距迴轉中心的水平距離，Y 向上為高度。角度對外一律用「度」。
///
/// 主臂（d = 臂尖偏移；ΔL = 臂長修正，下面的 L 都是臂軸長度 L + ΔL）：
///     R = x0 + L·cosθ + d·sinθ
///     H = y0 + L·sinθ − d·cosθ
/// 助臂（φ 為相對主臂向下的偏角）：Rj = R + J·cos(θ − φ)、Hj = H + J·sin(θ − φ)
/// 主臂用副吊鉤（單滑輪 p、q，鋼索 e）：Ra = R + p·cosθ + q·sinθ + e、Ha = H + p·sinθ − q·cosθ
library;

import 'dart:math' as math;

import 'pyformat.dart';

typedef Pt = ({double x, double y});

Pt pt(double x, double y) => (x: x, y: y);

const double minLength = 0.10; // 臂長 / 助臂長度只要求大於此值

const double _degToRad = math.pi / 180.0;
const double _radToDeg = 180.0 / math.pi;

double radians(double deg) => deg * _degToRad;
double degrees(double rad) => rad * _radToDeg;

double hypot(double x, double y) => math.sqrt(x * x + y * y);
double dist(Pt a, Pt b) => hypot(a.x - b.x, a.y - b.y);

class OutOfReachError implements Exception {
  final String message;
  OutOfReachError(this.message);

  @override
  String toString() => message;
}

/// 一台吊車的幾何規格（來自吊車規格檔）。
class BoomLimits {
  final double pivotX;
  final double pivotY;
  final double boomMin;
  final double boomMax;
  final double angleMin;
  final double angleMax;
  final double jibMin;
  final double jibMax;
  final double jibOffsetMin;
  final double jibOffsetMax;
  final double tipOffset; // 臂尖偏移 d
  final double auxAlong; // 單滑輪 p
  final double auxBelow; // 單滑輪 q
  final double auxRope; // 副吊鉤鋼索 e
  final double lengthOffset; // 臂長修正 ΔL

  const BoomLimits({
    this.pivotX = -2.20,
    this.pivotY = 3.44,
    this.boomMin = 8.0,
    this.boomMax = 32.0,
    this.angleMin = 0.0,
    this.angleMax = 80.0,
    this.jibMin = 3.0,
    this.jibMax = 10.0,
    this.jibOffsetMin = 0.0,
    this.jibOffsetMax = 60.0,
    this.tipOffset = 0.0,
    this.auxAlong = 0.0,
    this.auxBelow = 0.0,
    this.auxRope = 0.0,
    this.lengthOffset = 0.0,
  });

  Pt get pivot => (x: pivotX, y: pivotY);

  /// 顯示臂長 → 臂軸長度（幾何、繪圖用）。
  double axisLength(double length) => length + lengthOffset;

  BoomLimits copyWith({
    double? pivotX,
    double? pivotY,
    double? boomMin,
    double? boomMax,
    double? angleMin,
    double? angleMax,
    double? jibMin,
    double? jibMax,
    double? jibOffsetMin,
    double? jibOffsetMax,
    double? tipOffset,
    double? auxAlong,
    double? auxBelow,
    double? auxRope,
    double? lengthOffset,
  }) =>
      BoomLimits(
        pivotX: pivotX ?? this.pivotX,
        pivotY: pivotY ?? this.pivotY,
        boomMin: boomMin ?? this.boomMin,
        boomMax: boomMax ?? this.boomMax,
        angleMin: angleMin ?? this.angleMin,
        angleMax: angleMax ?? this.angleMax,
        jibMin: jibMin ?? this.jibMin,
        jibMax: jibMax ?? this.jibMax,
        jibOffsetMin: jibOffsetMin ?? this.jibOffsetMin,
        jibOffsetMax: jibOffsetMax ?? this.jibOffsetMax,
        tipOffset: tipOffset ?? this.tipOffset,
        auxAlong: auxAlong ?? this.auxAlong,
        auxBelow: auxBelow ?? this.auxBelow,
        auxRope: auxRope ?? this.auxRope,
        lengthOffset: lengthOffset ?? this.lengthOffset,
      );
}

/// 吊臂姿態。
class BoomPose {
  final double length; // 主臂長（顯示臂長）
  final double angle; // 主臂仰角 θ
  final bool jibEnabled;
  final double jibLength;
  final double jibOffset; // 助臂偏角 φ
  final bool auxHook; // 主臂作業改用副吊鉤

  const BoomPose({
    this.length = 8.0,
    this.angle = 60.0,
    this.jibEnabled = false,
    this.jibLength = 8.0,
    this.jibOffset = 0.0,
    this.auxHook = false,
  });

  BoomPose copyWith({
    double? length,
    double? angle,
    bool? jibEnabled,
    double? jibLength,
    double? jibOffset,
    bool? auxHook,
  }) =>
      BoomPose(
        length: length ?? this.length,
        angle: angle ?? this.angle,
        jibEnabled: jibEnabled ?? this.jibEnabled,
        jibLength: jibLength ?? this.jibLength,
        jibOffset: jibOffset ?? this.jibOffset,
        auxHook: auxHook ?? this.auxHook,
      );

  Map<String, Object> toJson() => {
        'length': length,
        'angle': angle,
        'jib_enabled': jibEnabled,
        'jib_length': jibLength,
        'jib_offset': jibOffset,
        'aux_hook': auxHook,
      };

  factory BoomPose.fromJson(Map<String, dynamic> d) => BoomPose(
        length: (d['length'] as num).toDouble(),
        angle: (d['angle'] as num).toDouble(),
        jibEnabled: d['jib_enabled'] as bool,
        jibLength: (d['jib_length'] as num).toDouble(),
        jibOffset: (d['jib_offset'] as num).toDouble(),
        auxHook: d['aux_hook'] as bool,
      );

  @override
  bool operator ==(Object other) =>
      other is BoomPose &&
      other.length == length &&
      other.angle == angle &&
      other.jibEnabled == jibEnabled &&
      other.jibLength == jibLength &&
      other.jibOffset == jibOffset &&
      other.auxHook == auxHook;

  @override
  int get hashCode => Object.hash(length, angle, jibEnabled, jibLength, jibOffset, auxHook);

  @override
  String toString() => 'BoomPose($length, $angle, jib=$jibEnabled $jibLength/$jibOffset, aux=$auxHook)';
}

class TipResult {
  final Pt pivot;
  final Pt mainTip; // 臂尖滑輪
  final Pt? jibTip;
  final Pt? head; // 臂頭（臂軸末端）；null = 與臂尖相同
  final Pt? auxTip; // 主臂用副吊鉤的吊掛點

  const TipResult({required this.pivot, required this.mainTip, this.jibTip, this.head, this.auxTip});

  /// 面板顯示的尖端：助臂模式為助臂尖端，主臂用副吊鉤為單滑輪，否則為主臂尖端。
  Pt get workingTip => jibTip ?? auxTip ?? mainTip;

  double get radius => workingTip.x;

  double get height => workingTip.y;
}

// ---------------------------------------------------------------- 正算

double clamp(double value, double lo, double hi) => math.max(lo, math.min(hi, value));

/// 臂頭：鉸點沿臂角方向 L 公尺（臂軸末端）。
Pt boomHead(Pt pivot, double length, double angleDeg) {
  final t = radians(angleDeg);
  return (x: pivot.x + length * math.cos(t), y: pivot.y + length * math.sin(t));
}

/// 臂尖滑輪：臂頭再往臂軸下方偏移 tipOffset。
Pt mainTip(Pt pivot, double length, double angleDeg, [double tipOffset = 0.0]) {
  final t = radians(angleDeg);
  final h = boomHead(pivot, length, angleDeg);
  return (x: h.x + tipOffset * math.sin(t), y: h.y - tipOffset * math.cos(t));
}

Pt jibTip(Pt tip, double angleDeg, double jibLength, double jibOffsetDeg) {
  final t = radians(angleDeg - jibOffsetDeg);
  return (x: tip.x + jibLength * math.cos(t), y: tip.y + jibLength * math.sin(t));
}

/// 單滑輪中心：臂尖滑輪沿臂身往外 auxAlong、垂直臂身往下 auxBelow。
Pt auxSheave(Pt tip, double angleDeg, BoomLimits limits) {
  final t = radians(angleDeg);
  return (
    x: tip.x + limits.auxAlong * math.cos(t) + limits.auxBelow * math.sin(t),
    y: tip.y + limits.auxAlong * math.sin(t) - limits.auxBelow * math.cos(t),
  );
}

/// 主臂用副吊鉤的吊掛點：鋼索從單滑輪外側往外 auxRope 垂下；高度取滑輪中心。
Pt auxTip(Pt tip, double angleDeg, BoomLimits limits) {
  final s = auxSheave(tip, angleDeg, limits);
  return (x: s.x + limits.auxRope, y: s.y);
}

TipResult solve(BoomPose pose, BoomLimits limits) {
  final axis = limits.axisLength(pose.length);
  final mt = mainTip(limits.pivot, axis, pose.angle, limits.tipOffset);
  Pt? jt;
  Pt? at;
  if (pose.jibEnabled) {
    jt = jibTip(mt, pose.angle, pose.jibLength, pose.jibOffset);
  } else if (pose.auxHook) {
    at = auxTip(mt, pose.angle, limits);
  }
  final head = limits.tipOffset != 0 ? boomHead(limits.pivot, axis, pose.angle) : null;
  return TipResult(pivot: limits.pivot, mainTip: mt, jibTip: jt, head: head, auxTip: at);
}

// ---------------------------------------------------------------- 反算

/// (C, δ 弧度, e)：主臂（含偏移）+ 助臂（或單滑輪）視為一支長 C、角度 θ−δ 的等效臂。
(double, double, double) _effectiveArm(BoomPose pose, BoomLimits limits) {
  var a = limits.axisLength(pose.length);
  var b = limits.tipOffset;
  var e = 0.0;
  if (pose.jibEnabled) {
    final phi = radians(pose.jibOffset);
    a += pose.jibLength * math.cos(phi);
    b += pose.jibLength * math.sin(phi);
  } else if (pose.auxHook) {
    a += limits.auxAlong;
    b += limits.auxBelow;
    e = limits.auxRope;
  }
  return (hypot(a, b), math.atan2(b, a), e);
}

double _checkAngle(double angleDeg, BoomLimits limits, String what) {
  const eps = 1e-9;
  if (angleDeg < limits.angleMin - eps || angleDeg > limits.angleMax + eps) {
    throw OutOfReachError('$what需要臂角 ${fixed(angleDeg, 2)}°，超出範圍 '
        '${fixed(limits.angleMin, 0)}°–${fixed(limits.angleMax, 0)}°');
  }
  return clamp(angleDeg, limits.angleMin, limits.angleMax);
}

/// 保持臂長（與助臂設定）不變，求達到指定半徑所需的臂角。
double angleForRadius(double radius, BoomPose pose, BoomLimits limits) {
  if (!radius.isFinite) throw OutOfReachError('半徑須為有效數字');
  final (c, delta, e) = _effectiveArm(pose, limits);
  final k = (radius - limits.pivotX - e) / c;
  if (k.abs() > 1.0) {
    final lo = limits.pivotX + e - c;
    final hi = limits.pivotX + e + c;
    throw OutOfReachError('半徑 ${fixed(radius, 2)} m 超出目前臂長可達範圍'
        '（${fixed(math.max(lo, 0.0), 2)}–${fixed(hi, 2)} m）');
  }
  final angle = degrees(delta + math.acos(k));
  return _checkAngle(angle, limits, '半徑 ${fixed(radius, 2)} m ');
}

/// 達到指定半徑、且最接近目前臂角的臂角；做不到為 null。
double? angleForRadiusNear(double radius, BoomPose pose, BoomLimits limits) {
  final (c, delta, e) = _effectiveArm(pose, limits);
  final k = (radius - limits.pivotX - e) / c;
  if (k.abs() > 1.0) return null;
  final base = math.acos(k);
  final cands = [degrees(delta + base), degrees(delta - base)];
  final ok = cands.where((a) => limits.angleMin - 1e-9 <= a && a <= limits.angleMax + 1e-9).toList();
  if (ok.isEmpty) return null;
  var best = ok.first;
  for (final a in ok.skip(1)) {
    if ((a - pose.angle).abs() < (best - pose.angle).abs()) best = a;
  }
  return clamp(best, limits.angleMin, limits.angleMax);
}

/// 保持臂長（與助臂設定）不變，求達到指定尖端高度所需的臂角。
double angleForHeight(double height, BoomPose pose, BoomLimits limits) {
  if (!height.isFinite) throw OutOfReachError('高度須為有效數字');
  final (c, delta, _) = _effectiveArm(pose, limits);
  final k = (height - limits.pivotY) / c;
  if (k.abs() > 1.0) {
    throw OutOfReachError('高度 ${fixed(height, 2)} m 超出目前臂長可達範圍（最高 ${fixed(limits.pivotY + c, 2)} m）');
  }
  final base = math.asin(k);
  for (final cand in [delta + base, delta + math.pi - base]) {
    final deg = degrees(cand);
    if (limits.angleMin - 1e-9 <= deg && deg <= limits.angleMax + 1e-9) {
      return clamp(deg, limits.angleMin, limits.angleMax);
    }
  }
  return _checkAngle(degrees(delta + base), limits, '高度 ${fixed(height, 2)} m ');
}

BoomPose poseWithRadius(double radius, BoomPose pose, BoomLimits limits) =>
    pose.copyWith(angle: angleForRadius(radius, pose, limits));

BoomPose poseWithHeight(double height, BoomPose pose, BoomLimits limits) =>
    pose.copyWith(angle: angleForHeight(height, pose, limits));

// ---------------------------------------------------------------- 拖曳

/// 拖曳主臂尖端：同時改變臂長與臂角，並夾在規格範圍內。
BoomPose poseFromMainTipDrag(Pt point, BoomPose pose, BoomLimits limits) {
  final dx = point.x - limits.pivotX;
  final dy = point.y - limits.pivotY;
  final d0 = hypot(dx, dy);
  final d = limits.tipOffset;
  final axis = math.sqrt(math.max(d0 * d0 - d * d, 0.0));
  final length = clamp(axis - limits.lengthOffset, limits.boomMin, limits.boomMax);
  var deg = degrees(math.atan2(dy, dx) + math.atan2(d, limits.axisLength(length)));
  if (deg < -90.0) deg += 360.0; // 拖到鉸點左下方：視為「往後倒」
  final angle = clamp(deg, limits.angleMin, limits.angleMax);
  return pose.copyWith(length: length, angle: angle);
}

/// 游標相對鉸點的方向角（度）。拖到鉸點左下方時視為「往後倒」（> 90°）。
double pointerAngle(Pt point, BoomLimits limits) {
  var deg = degrees(math.atan2(point.y - limits.pivotY, point.x - limits.pivotX));
  if (deg < -90.0) deg += 360.0;
  return deg;
}

/// 拖曳主臂本體：只改臂角，臂長不變。
BoomPose poseFromBoomAngleDrag(Pt point, BoomPose pose, BoomLimits limits, [double offsetDeg = 0.0]) {
  if (hypot(point.x - limits.pivotX, point.y - limits.pivotY) < 1e-6) return pose;
  final angle = clamp(pointerAngle(point, limits) + offsetDeg, limits.angleMin, limits.angleMax);
  return pose.copyWith(angle: angle);
}

/// 拖曳主臂尖端紅點：只改臂長（沿目前臂角方向投影），臂角不變。
BoomPose poseFromTipLengthDrag(Pt point, BoomPose pose, BoomLimits limits) {
  final t = radians(pose.angle);
  final proj = (point.x - limits.pivotX) * math.cos(t) + (point.y - limits.pivotY) * math.sin(t);
  return pose.copyWith(length: clamp(proj - limits.lengthOffset, limits.boomMin, limits.boomMax));
}

/// 拖曳助臂尖端：以主臂尖端為圓心，改變助臂長度與偏角。
BoomPose poseFromJibTipDrag(Pt point, BoomPose pose, BoomLimits limits) {
  final mt = mainTip(limits.pivot, limits.axisLength(pose.length), pose.angle, limits.tipOffset);
  final dx = point.x - mt.x;
  final dy = point.y - mt.y;
  final jibLen = clamp(hypot(dx, dy), limits.jibMin, limits.jibMax);
  var offset = pose.angle - degrees(math.atan2(dy, dx));
  offset = _pyMod(offset + 180.0, 360.0) - 180.0;
  offset = clamp(offset, limits.jibOffsetMin, limits.jibOffsetMax);
  return pose.copyWith(jibLength: jibLen, jibOffset: offset);
}

/// Python 的 % ：結果與除數同號。
double _pyMod(double a, double b) {
  final r = a % b; // Dart 的 % 對正除數已回傳 0 ≤ r < b
  return r;
}

BoomPose clampPose(BoomPose pose, BoomLimits limits) => pose.copyWith(
      length: clamp(pose.length, limits.boomMin, limits.boomMax),
      angle: clamp(pose.angle, limits.angleMin, limits.angleMax),
      jibLength: clamp(pose.jibLength, limits.jibMin, limits.jibMax),
      jibOffset: clamp(pose.jibOffset, limits.jibOffsetMin, limits.jibOffsetMax),
    );

// ---------------------------------------------------------------- 吊臂下彎（手動修正）

/// 懸臂樑端點受力的撓曲曲線：δ(s) = d · r² · (3 − r) / 2，r = s / 總長。
double deflectionAt(double ratio, double deflection) {
  final r = math.min(math.max(ratio, 0.0), 1.0);
  return deflection * r * r * (3.0 - r) / 2.0;
}

/// 把吊臂折線往下彎，尖端下降 deflection 公尺；每段取 samples 個點。
List<Pt> deflectedPolyline(List<Pt> points, double deflection, [int samples = 6]) {
  if (deflection <= 0 || points.length < 2) return List.of(points);
  final segLen = [for (var i = 0; i < points.length - 1; i++) dist(points[i], points[i + 1])];
  final total = segLen.fold(0.0, (a, b) => a + b);
  if (total <= 0) return List.of(points);
  final out = <Pt>[points[0]];
  var walked = 0.0;
  for (var i = 0; i < segLen.length; i++) {
    final p0 = points[i];
    final p1 = points[i + 1];
    final len = segLen[i];
    for (var k = 1; k <= samples; k++) {
      final t = k / samples;
      final s = walked + len * t;
      out.add((
        x: p0.x + (p1.x - p0.x) * t,
        y: p0.y + (p1.y - p0.y) * t - deflectionAt(s / total, deflection),
      ));
    }
    walked += len;
  }
  return out;
}

// ---------------------------------------------------------------- 伸縮節（繪圖用）

/// 各節沿吊臂方向的 (起點, 終點)，第 0 節為基本節。
List<(double, double)> telescopicSections(double length, double minLength, int count) {
  count = math.max(0, count);
  if (count == 0 || length <= minLength) return [(0.0, length)];
  final seg = math.max(minLength, length / (count * 0.85 + 1));
  final step = (length - seg) / count;
  return [for (var k = 0; k <= count; k++) (k * step, k * step + seg)];
}
