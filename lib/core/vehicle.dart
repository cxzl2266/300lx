/// 吊車車體尺寸與側視圖外型（移植自 Python 版 core/vehicle.py）。
///
/// 座標：迴轉中心 X = 0，車頭朝 +X，地面 Y = 0。
library;

import 'dart:math' as math;

import 'geometry.dart';
import 'pyformat.dart';

/// (x, y, w, h)
typedef RectXYWH = (double, double, double, double);

/// (頂點, 是否封閉)
typedef Shape = (List<Pt>, bool);

const double _refHeight = 3.85; // 設計稿車高
const double _upperFront = -0.25;
const double _upperRear = -5.40;
const double _cabLength = 1.70;
const double _cabFrontGap = 0.25;
const double pivotMargin = 0.80; // 迴轉中心至車尾至少比臂根鉸點多這麼多

/// 欄位 → (下限, 上限)；順序與 Python 的 LIMITS 相同。
const Map<String, (double, double)> bodyLimits = {
  'total_length': (4.0, 25.0),
  'chassis_length': (3.0, 25.0),
  'height': (2.0, 8.0),
  'width': (1.5, 5.0),
  'front': (2.0, 24.5),
};

const Map<String, String> bodyLabels = {
  'total_length': '車總長',
  'chassis_length': '底盤總長',
  'height': '車高',
  'width': '車寬',
  'front': '迴轉中心至車頭',
};

class VehicleBody {
  final double totalLength;
  final double chassisLength;
  final double height;
  final double width;
  final double front;

  const VehicleBody({
    this.totalLength = 9.0,
    this.chassisLength = 8.7,
    this.height = 3.85,
    this.width = 2.5,
    this.front = 3.0,
  });

  /// 迴轉中心至車尾。
  double get rear => totalLength - front;

  double field(String key) => switch (key) {
        'total_length' => totalLength,
        'chassis_length' => chassisLength,
        'height' => height,
        'width' => width,
        'front' => front,
        _ => throw ArgumentError(key),
      };

  factory VehicleBody.fromJson(Map<String, dynamic>? d) {
    d ??= const {};
    const base = VehicleBody();
    double v(String k) => d![k] == null ? base.field(k) : (d[k] as num).toDouble();
    return VehicleBody(
      totalLength: v('total_length'),
      chassisLength: v('chassis_length'),
      height: v('height'),
      width: v('width'),
      front: v('front'),
    );
  }

  Map<String, double> toJson() => {for (final k in bodyLimits.keys) k: field(k)};

  VehicleBody withField(String key, double value) {
    if (!bodyLimits.containsKey(key)) throw ArgumentError(key);
    final m = toJson()..[key] = value;
    return VehicleBody.fromJson(m);
  }

  @override
  bool operator ==(Object other) =>
      other is VehicleBody &&
      other.totalLength == totalLength &&
      other.chassisLength == chassisLength &&
      other.height == height &&
      other.width == width &&
      other.front == front;

  @override
  int get hashCode => Object.hash(totalLength, chassisLength, height, width, front);
}

/// 回傳錯誤訊息；沒問題回傳 null。pivotX = 臂根鉸點 X（負值）。
String? validateBody(VehicleBody body, [double? pivotX]) {
  for (final MapEntry(key: key, value: (lo, hi)) in bodyLimits.entries) {
    final v = body.field(key);
    if (!(lo <= v && v <= hi)) return '${bodyLabels[key]}須在 ${fixed(lo, 1)}–${fixed(hi, 1)} m';
  }
  if (body.chassisLength > body.totalLength + 1e-9) {
    return '底盤總長（${fixed(body.chassisLength, 2)} m）不可大於車總長（${fixed(body.totalLength, 2)} m）';
  }
  final px = pivotX ?? 0.0;
  final need = math.min(px, 0.0).abs() + pivotMargin;
  if (body.rear < need - 1e-9) {
    if (pivotX == null) return '迴轉中心至車尾須至少 ${fixed(need, 2)} m';
    return '迴轉中心至車尾只有 ${fixed(body.rear, 2)} m，須至少 ${fixed(need, 2)} m'
        '（臂根鉸點在迴轉中心後方 ${fixed(pivotX.abs(), 2)} m，再加 ${fixed(pivotMargin, 1)} m），'
        '否則鉸點會懸空在車外。請加大車總長或減少迴轉中心至車頭';
  }
  return null;
}

List<Pt> _rectPts(RectXYWH r) {
  final (x, y, w, h) = r;
  return [pt(x, y), pt(x + w, y), pt(x + w, y + h), pt(x, y + h)];
}

List<Pt> _circlePts(double cx, double cy, double r, [int n = 12]) => [
      for (var i = 0; i < n; i++) pt(cx + r * math.cos(2 * math.pi * i / n), cy + r * math.sin(2 * math.pi * i / n))
    ];

/// 側視圖各部位（公尺）。
class BodyLayout {
  final double rearX, frontX;
  final RectXYWH chassis;
  final List<(double, double, double)> wheels; // (cx, cy, r)
  final List<RectXYWH> outriggerLegs, outriggerPads;
  final RectXYWH turntable;
  final List<Pt> upper, bracket, cab, window;
  final RectXYWH centerMark;
  final Pt cylinderBase;
  final List<RectXYWH> bumpers;

  BodyLayout({
    required this.rearX,
    required this.frontX,
    required this.chassis,
    required this.wheels,
    required this.outriggerLegs,
    required this.outriggerPads,
    required this.turntable,
    required this.upper,
    required this.bracket,
    required this.cab,
    required this.window,
    required this.centerMark,
    required this.cylinderBase,
    required this.bumpers,
  });

  (double, double, double, double) bounds() {
    final xs = <double>[rearX, frontX, ...[...upper, ...bracket, ...cab].map((p) => p.x)];
    xs.addAll(outriggerPads.map((r) => r.$1));
    xs.addAll(outriggerPads.map((r) => r.$1 + r.$3));
    final ys = <double>[0.0, ...[...upper, ...bracket, ...cab].map((p) => p.y)];
    return (xs.reduce(math.min), ys.reduce(math.min), xs.reduce(math.max), ys.reduce(math.max));
  }

  /// 車身碰撞檢查用的外形：(部位名稱, 形狀)。
  List<(String, Shape)> shapes() => [
        ('底盤', (_rectPts(chassis), true)),
        for (final r in bumpers) ('底盤', (_rectPts(r), true)),
        for (final (cx, cy, r) in wheels) ('車輪', (_circlePts(cx, cy, r), true)),
        for (final r in [...outriggerLegs, ...outriggerPads]) ('支撐腳', (_rectPts(r), true)),
        ('迴轉台', (_rectPts(turntable), true)),
        ('上部機構', (List.of(upper), true)),
        ('臂根托架', (List.of(bracket), true)),
        ('駕駛室', (List.of(cab), true)),
      ];
}

/// 由車體尺寸算出側視圖外型。pivot = 臂根鉸點（已含車高連動）。
BodyLayout layoutBody(VehicleBody body, Pt pivot) {
  final f = body.front, rr = body.rear;
  final sy = body.height / _refHeight;
  final rearX = -rr, frontX = f;

  final over = (body.totalLength - body.chassisLength) / 2;
  final c0 = rearX + over;
  final c1 = c0 + body.chassisLength;
  final lc = body.chassisLength;

  final r = math.min(math.max(0.52 * sy, 0.30), 0.80);
  final deckBottom = math.min(0.95 * sy, 2 * r - 0.09);
  final deckTop = deckBottom + 0.80 * sy;
  final chassis = (c0, deckBottom, lc, deckTop - deckBottom);

  final extH = (deckTop - deckBottom) * 0.75;
  final bumpers = <RectXYWH>[];
  if (c0 - rearX > 1e-6) bumpers.add((rearX, deckBottom, c0 - rearX, extH));
  if (frontX - c1 > 1e-6) bumpers.add((c1, deckBottom, frontX - c1, extH));

  final nAxle = lc < 7.0 ? 2 : (lc < 10.5 ? 3 : 4);
  final a0 = c0 + 0.16 * lc, a1 = c1 - 0.14 * lc;
  final wheels = [for (var i = 0; i < nAxle; i++) (a0 + (a1 - a0) * i / (nAxle - 1), r + 0.03, r)];

  const legW = 0.22;
  final legsX = [c0 + 0.05, c1 - 0.27];
  final legs = [for (final x in legsX) (x, 0.10, legW, deckBottom + 0.15 * sy - 0.10)];
  final pads = <RectXYWH>[];
  for (final x in legsX) {
    final a = math.max(rearX, x - 0.16), b = math.min(frontX, x + 0.38);
    pads.add((a, 0.0, b - a, 0.12));
  }

  final upperRear = math.max(_upperRear, rearX + 0.10);
  final k = (upperRear - _upperFront) / (_upperRear - _upperFront);
  double ux(double xDesign) => _upperFront + (xDesign - _upperFront) * k;

  final ttTop = deckTop + 0.14 * sy;
  final turntable = (ux(-4.6), deckTop, -0.1 - ux(-4.6), ttTop - deckTop);
  final hUpper = 1.31 * sy;
  final upperTop = ttTop + hUpper;
  final upper = [
    pt(ux(-5.4), ttTop),
    pt(ux(-5.4), ttTop + 0.66 * hUpper),
    pt(ux(-3.9), ttTop + 0.81 * hUpper),
    pt(ux(-3.3), upperTop),
    pt(ux(-1.2), upperTop),
    pt(_upperFront, ttTop + 0.39 * hUpper),
    pt(_upperFront, ttTop),
  ];
  final px = pivot.x, py = pivot.y;
  final bracket = [pt(px - 0.65, upperTop), pt(px, py + 0.28), pt(px + 0.65, upperTop)];

  final cabX1 = frontX - _cabFrontGap;
  final cabX0 = cabX1 - _cabLength;
  final cabTop = body.height;
  final cabH = cabTop - deckTop;
  final cab = [
    pt(cabX0, deckTop),
    pt(cabX0, cabTop),
    pt(cabX1 - 0.40, cabTop),
    pt(cabX1, deckTop + 0.40 * cabH),
    pt(cabX1, deckTop),
  ];
  final window = [
    pt(cabX0 + 0.25, deckTop + 0.47 * cabH),
    pt(cabX0 + 0.25, deckTop + 0.88 * cabH),
    pt(cabX1 - 0.55, deckTop + 0.88 * cabH),
    pt(cabX1 - 0.27, deckTop + 0.47 * cabH),
  ];
  final centerMark = (-0.06, deckTop - 0.2 * sy, 0.12, 0.45 * sy);
  final cylinderBase = pt(px + 1.2, ttTop + 0.16 * sy);

  return BodyLayout(
    rearX: rearX,
    frontX: frontX,
    chassis: chassis,
    wheels: wheels,
    outriggerLegs: legs,
    outriggerPads: pads,
    turntable: turntable,
    upper: upper,
    bracket: bracket,
    cab: cab,
    window: window,
    centerMark: centerMark,
    cylinderBase: cylinderBase,
    bumpers: bumpers,
  );
}
