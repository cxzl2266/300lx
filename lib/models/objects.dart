/// 圖面物件資料模型（移植自 Python 版 models/objects.py；欄位名稱相同，專案檔可互通）。
///
/// 物件不可變：修改時用 copyWith({欄位: 新值})（等同 Python 的 replace(**changes)）。
library;

import 'dart:math' as math;

import '../core/geometry.dart';
import '../core/vehicle.dart' show Shape;

const double minSize = 0.10;

int _counter = 0;

String newId() {
  _counter += 1;
  final ms = DateTime.now().millisecondsSinceEpoch % 10000000;
  return 'o${ms.toString().padLeft(7, '0')}${(_counter % 10000).toString().padLeft(4, '0')}';
}

double _d(Map<String, Object?> m, String k, double dflt) => m[k] == null ? dflt : (m[k] as num).toDouble();
String _s(Map<String, Object?> m, String k, String dflt) => m[k] == null ? dflt : m[k].toString();
bool _b(Map<String, Object?> m, String k, bool dflt) => m[k] == null ? dflt : m[k] == true;

/// 每種物件共用的欄位。
class Base {
  final String id;
  final String name;
  final String fill;
  final String stroke;
  final double opacity;
  final bool locked;
  final bool visible;
  final bool collision;
  final double margin;

  const Base(this.id, this.name, this.fill, this.stroke, this.opacity, this.locked, this.visible, this.collision,
      this.margin);

  /// 依各類別的預設值讀取共用欄位。
  factory Base.read(Map<String, Object?> m,
      {String name = '',
      String fill = '#3aa3d2',
      String stroke = '#1f6f96',
      double opacity = 0.9,
      bool collision = false,
      double margin = 1.0}) {
    return Base(
      m['id'] == null ? newId() : m['id'].toString(),
      _s(m, 'name', name),
      _s(m, 'fill', fill),
      _s(m, 'stroke', stroke),
      _d(m, 'opacity', opacity),
      _b(m, 'locked', false),
      _b(m, 'visible', true),
      _b(m, 'collision', collision),
      _d(m, 'margin', margin),
    );
  }

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'fill': fill,
        'stroke': stroke,
        'opacity': opacity,
        'locked': locked,
        'visible': visible,
        'collision': collision,
        'margin': margin,
      };
}

abstract class SceneObject {
  final Base base;

  const SceneObject(this.base);

  String get kind;
  String get label;
  bool get collidable => false;
  bool get movable => true;
  bool get supportsLoad => false;

  String get id => base.id;
  String get name => base.name;
  String get fill => base.fill;
  String get stroke => base.stroke;
  double get opacity => base.opacity;
  bool get locked => base.locked;
  bool get visible => base.visible;
  bool get collision => base.collision;
  double get margin => base.margin;

  Map<String, Object?> fields();

  Map<String, Object?> toJson() => {...base.toJson(), ...fields(), 'kind': kind};

  /// 修改欄位後的新物件（等同 Python dataclasses.replace）。
  SceneObject copyWith(Map<String, Object?> changes) => objectFromJson({...toJson(), ...changes});

  List<Pt> handles() => const [];
  Map<String, Object?> withHandle(int index, Pt p) => const {};
  Map<String, Object?> translated(double dx, double dy) => const {};

  /// 吸附格線時的參考點。
  Pt anchor() {
    final h = handles();
    return h.isNotEmpty ? h.first : pt(0, 0);
  }

  /// 外框頂點（繪製與選取用）。
  List<Pt> outline() => handles();

  Shape? collisionShape() => null;

  List<Pt> keyPoints() => outline();

  (double, double, double, double) bounds() {
    var pts = outline();
    if (pts.isEmpty) pts = [anchor()];
    return (
      pts.map((p) => p.x).reduce(math.min),
      pts.map((p) => p.y).reduce(math.min),
      pts.map((p) => p.x).reduce(math.max),
      pts.map((p) => p.y).reduce(math.max),
    );
  }

  bool get activeCollision => collidable && collision && visible;
}

// ====================================================================== 矩形
class RectObject extends SceneObject {
  final double x, y, width, height;

  RectObject._(super.base, this.x, this.y, this.width, this.height);

  factory RectObject.fromJson(Map<String, Object?> m) => RectObject._(
      Base.read(m, name: '障礙物', collision: true), _d(m, 'x', 8.0), _d(m, 'y', 0.0), _d(m, 'width', 8.0),
      _d(m, 'height', 8.0));

  factory RectObject({String? id, String? name, double? x, double? y, double? width, double? height}) =>
      RectObject.fromJson({'id': id, 'name': name, 'x': x, 'y': y, 'width': width, 'height': height});

  @override
  String get kind => 'rect';
  @override
  String get label => '矩形障礙物';
  @override
  bool get collidable => true;

  @override
  Map<String, Object?> fields() => {'x': x, 'y': y, 'width': width, 'height': height};

  @override
  List<Pt> outline() {
    final x0 = x, y0 = y, x1 = x + width, y1 = y + height;
    return [pt(x0, y0), pt(x1, y0), pt(x1, y1), pt(x0, y1)];
  }

  @override
  List<Pt> handles() => outline();

  @override
  Map<String, Object?> withHandle(int index, Pt p) {
    final o = outline()[(index + 2) % 4]; // 對角固定
    final x0 = math.min(o.x, p.x), x1 = math.max(o.x, p.x);
    final y0 = math.min(o.y, p.y), y1 = math.max(o.y, p.y);
    return {'x': x0, 'y': y0, 'width': math.max(minSize, x1 - x0), 'height': math.max(minSize, y1 - y0)};
  }

  @override
  Map<String, Object?> translated(double dx, double dy) => {'x': x + dx, 'y': y + dy};

  @override
  Shape collisionShape() => (outline(), true);
}

// ====================================================================== 多邊形
class PolygonObject extends SceneObject {
  final List<List<double>> points;

  PolygonObject._(super.base, this.points);

  static const _defaultPoints = [
    [0.0, 0.0],
    [4.0, 0.0],
    [4.0, 3.0],
    [2.0, 5.0],
    [0.0, 3.0],
  ];

  factory PolygonObject.fromJson(Map<String, Object?> m) {
    final raw = (m['points'] as List?) ?? _defaultPoints;
    return PolygonObject._(
      Base.read(m, name: '多邊形', fill: '#8cc084', stroke: '#3f7a3e', collision: true),
      [
        for (final p in raw) [((p as List)[0] as num).toDouble(), (p[1] as num).toDouble()]
      ],
    );
  }

  factory PolygonObject({String? id, List<List<double>>? points}) =>
      PolygonObject.fromJson({'id': id, 'points': points});

  @override
  String get kind => 'polygon';
  @override
  String get label => '多邊形';
  @override
  bool get collidable => true;

  @override
  Map<String, Object?> fields() => {
        'points': [for (final p in points) List<double>.of(p)]
      };

  @override
  List<Pt> outline() => [for (final p in points) pt(p[0], p[1])];

  @override
  List<Pt> handles() => outline();

  @override
  Map<String, Object?> withHandle(int index, Pt p) {
    final pts = [for (final q in points) List<double>.of(q)];
    if (0 <= index && index < pts.length) pts[index] = [p.x, p.y];
    return {'points': pts};
  }

  @override
  Map<String, Object?> translated(double dx, double dy) => {
        'points': [
          for (final q in points) [q[0] + dx, q[1] + dy]
        ]
      };

  @override
  Shape collisionShape() => (outline(), true);
}

// ====================================================================== 吊物
/// 掛在工作尖端下方的吊物：臂端 ─(吊掛長度 hoist)─▶ 掛鉤 ─(吊索長度 sling)─▶ 吊物頂部。
class LoadObject extends SceneObject {
  static const double attachRatio = 0.2;
  static const double minHoistAbs = 0.5;

  final double width, height, weight, hoist, sling;

  LoadObject._(super.base, this.width, this.height, this.weight, this.hoist, this.sling);

  factory LoadObject.fromJson(Map<String, Object?> m) => LoadObject._(
      Base.read(m, name: '吊物', fill: '#f2c14e', stroke: '#8a6400'),
      _d(m, 'width', 2.0),
      _d(m, 'height', 1.5),
      _d(m, 'weight', 3.0),
      _d(m, 'hoist', 2.0),
      _d(m, 'sling', 1.5));

  factory LoadObject({String? id, double? width, double? height, double? weight, double? hoist, double? sling}) =>
      LoadObject.fromJson(
          {'id': id, 'width': width, 'height': height, 'weight': weight, 'hoist': hoist, 'sling': sling});

  @override
  String get kind => 'load';
  @override
  String get label => '吊物';
  @override
  bool get movable => false;

  @override
  Map<String, Object?> fields() =>
      {'width': width, 'height': height, 'weight': weight, 'hoist': hoist, 'sling': sling};

  Pt hookAt(Pt tip) => pt(tip.x, tip.y - hoist);

  List<Pt> rectAt(Pt tip) {
    final top = tip.y - hoist - sling;
    final x0 = tip.x - width / 2, x1 = tip.x + width / 2;
    final y0 = top - height;
    return [pt(x0, y0), pt(x1, y0), pt(x1, top), pt(x0, top)];
  }

  (Pt, Pt) attachPoints(Pt tip) {
    final rect = rectAt(tip);
    final top = rect[2].y;
    final a = width * attachRatio;
    return (pt(rect[0].x + a, top), pt(rect[1].x - a, top));
  }

  double slingLegLength() {
    final half = width * (0.5 - attachRatio);
    return math.sqrt(half * half + sling * sling);
  }

  double slingAngle() {
    final half = width * (0.5 - attachRatio);
    if (half <= 0) return 90.0;
    return degrees(math.atan2(sling, half));
  }

  static (double, double) blockSize(double blockHeight) => (math.max(0.4, blockHeight * 0.6), blockHeight);

  List<Pt> blockRect(Pt tip, double blockHeight) {
    final h = hookAt(tip);
    final (w, bh) = blockSize(blockHeight);
    return [pt(h.x - w / 2, h.y), pt(h.x + w / 2, h.y), pt(h.x + w / 2, h.y + bh), pt(h.x - w / 2, h.y + bh)];
  }

  /// 碰撞檢查用：鋼索、吊鉤組、兩支吊索、吊物本體。
  List<Shape> riggingShapes(Pt tip, [double blockHeight = 0.0]) {
    final hook = hookAt(tip);
    final (left, right) = attachPoints(tip);
    final topOfBlock = pt(hook.x, hook.y + math.max(0.0, blockHeight));
    return [
      ([tip, topOfBlock], false),
      if (blockHeight > 0) (blockRect(tip, blockHeight), true),
      ([left, hook, right], false),
      (rectAt(tip), true),
    ];
  }
}

// ====================================================================== 電線 / 線段
class WireObject extends SceneObject {
  final double x1, y1, x2, y2;

  WireObject._(super.base, this.x1, this.y1, this.x2, this.y2);

  factory WireObject.fromJson(Map<String, Object?> m) => WireObject._(
      Base.read(m, name: '架空電線', fill: '#ff6b6b', stroke: '#c92a2a', collision: true, margin: 3.0),
      _d(m, 'x1', 0.0),
      _d(m, 'y1', 12.0),
      _d(m, 'x2', 20.0),
      _d(m, 'y2', 12.0));

  factory WireObject({String? id}) => WireObject.fromJson({'id': id});

  @override
  String get kind => 'wire';
  @override
  String get label => '電線 / 線段';
  @override
  bool get collidable => true;

  @override
  Map<String, Object?> fields() => {'x1': x1, 'y1': y1, 'x2': x2, 'y2': y2};

  @override
  List<Pt> outline() => [pt(x1, y1), pt(x2, y2)];

  @override
  List<Pt> handles() => outline();

  @override
  Map<String, Object?> withHandle(int index, Pt p) => index == 0 ? {'x1': p.x, 'y1': p.y} : {'x2': p.x, 'y2': p.y};

  @override
  Map<String, Object?> translated(double dx, double dy) =>
      {'x1': x1 + dx, 'y1': y1 + dy, 'x2': x2 + dx, 'y2': y2 + dy};

  @override
  Shape collisionShape() => (outline(), false);
}

// ====================================================================== 地面高程
/// 一段地面高程：正值為墊高、負值為坑洞；一律納入「地面檢查」。
class GroundObject extends SceneObject {
  final double x1, x2, elevation;

  GroundObject._(super.base, this.x1, this.x2, this.elevation);

  factory GroundObject.fromJson(Map<String, Object?> m) => GroundObject._(
      Base.read(m, name: '地面高程', fill: '#c49a6c', stroke: '#7a5230', opacity: 0.8),
      _d(m, 'x1', 4.0),
      _d(m, 'x2', 10.0),
      _d(m, 'elevation', -2.0));

  factory GroundObject({String? id, double? x1, double? x2, double? elevation}) =>
      GroundObject.fromJson({'id': id, 'x1': x1, 'x2': x2, 'elevation': elevation});

  @override
  String get kind => 'ground';
  @override
  String get label => '地面高程';

  @override
  Map<String, Object?> fields() => {'x1': x1, 'x2': x2, 'elevation': elevation};

  @override
  List<Pt> outline() {
    final a = math.min(x1, x2), b = math.max(x1, x2);
    final y0 = math.min(0.0, elevation), y1 = math.max(0.0, elevation);
    return [pt(a, y0), pt(b, y0), pt(b, y1), pt(a, y1)];
  }

  @override
  List<Pt> handles() => [pt(x1, elevation), pt(x2, elevation)];

  @override
  Map<String, Object?> withHandle(int index, Pt p) => {index == 0 ? 'x1' : 'x2': p.x, 'elevation': p.y};

  @override
  Map<String, Object?> translated(double dx, double dy) => {'x1': x1 + dx, 'x2': x2 + dx, 'elevation': elevation + dy};

  bool covers(double x) => math.min(x1, x2) <= x && x <= math.max(x1, x2);
}

// ====================================================================== 文字註記
class TextObject extends SceneObject {
  final String text;
  final double x, y, size;

  TextObject._(super.base, this.text, this.x, this.y, this.size);

  factory TextObject.fromJson(Map<String, Object?> m) => TextObject._(
      Base.read(m, name: '文字', fill: '#ffffff', stroke: '#1d2530', opacity: 1.0),
      _s(m, 'text', '註記'),
      _d(m, 'x', 0.0),
      _d(m, 'y', 10.0),
      _d(m, 'size', 0.8));

  factory TextObject({String? id}) => TextObject.fromJson({'id': id});

  @override
  String get kind => 'text';
  @override
  String get label => '文字註記';

  @override
  Map<String, Object?> fields() => {'text': text, 'x': x, 'y': y, 'size': size};

  @override
  Pt anchor() => pt(x, y);

  @override
  List<Pt> outline() => [pt(x, y)];

  @override
  Map<String, Object?> translated(double dx, double dy) => {'x': x + dx, 'y': y + dy};
}

// ====================================================================== 尺寸標註
const Map<String, String> dimModes = {'aligned': '實際距離', 'horizontal': '水平距離', 'vertical': '垂直距離'};

class DimensionObject extends SceneObject {
  final double x1, y1, x2, y2;
  final String mode;

  DimensionObject._(super.base, this.x1, this.y1, this.x2, this.y2, this.mode);

  factory DimensionObject.fromJson(Map<String, Object?> m) => DimensionObject._(
      Base.read(m, name: '尺寸', stroke: '#1d2530', opacity: 1.0),
      _d(m, 'x1', 0.0),
      _d(m, 'y1', 0.0),
      _d(m, 'x2', 5.0),
      _d(m, 'y2', 0.0),
      _s(m, 'mode', 'aligned'));

  factory DimensionObject({String? id, double? x1, double? y1, double? x2, double? y2, String? mode}) =>
      DimensionObject.fromJson({'id': id, 'x1': x1, 'y1': y1, 'x2': x2, 'y2': y2, 'mode': mode});

  @override
  String get kind => 'dimension';
  @override
  String get label => '尺寸標註';

  @override
  Map<String, Object?> fields() => {'x1': x1, 'y1': y1, 'x2': x2, 'y2': y2, 'mode': mode};

  @override
  List<Pt> outline() => [pt(x1, y1), pt(x2, y2)];

  @override
  List<Pt> handles() => outline();

  @override
  Map<String, Object?> withHandle(int index, Pt p) => index == 0 ? {'x1': p.x, 'y1': p.y} : {'x2': p.x, 'y2': p.y};

  @override
  Map<String, Object?> translated(double dx, double dy) =>
      {'x1': x1 + dx, 'y1': y1 + dy, 'x2': x2 + dx, 'y2': y2 + dy};

  double value() {
    final dx = x2 - x1, dy = y2 - y1;
    if (mode == 'horizontal') return dx.abs();
    if (mode == 'vertical') return dy.abs();
    return math.sqrt(dx * dx + dy * dy);
  }
}

// ====================================================================== 背景圖
/// 匯入的施工立面圖；可用兩點比例校正。path：手機版存圖片的 data URL。
class ImageObject extends SceneObject {
  final String path;
  final double x, y, width, height;

  ImageObject._(super.base, this.path, this.x, this.y, this.width, this.height);

  factory ImageObject.fromJson(Map<String, Object?> m) => ImageObject._(
      Base.read(m, name: '背景圖', opacity: 0.5),
      _s(m, 'path', ''),
      _d(m, 'x', -6.0),
      _d(m, 'y', 0.0),
      _d(m, 'width', 30.0),
      _d(m, 'height', 20.0));

  factory ImageObject({String? id}) => ImageObject.fromJson({'id': id});

  @override
  String get kind => 'image';
  @override
  String get label => '背景圖';

  @override
  Map<String, Object?> fields() => {'path': path, 'x': x, 'y': y, 'width': width, 'height': height};

  @override
  List<Pt> outline() {
    final x0 = x, y0 = y, x1 = x + width, y1 = y + height;
    return [pt(x0, y0), pt(x1, y0), pt(x1, y1), pt(x0, y1)];
  }

  @override
  List<Pt> handles() => [pt(x + width, y + height)];

  @override
  Map<String, Object?> withHandle(int index, Pt p) {
    final aspect = width != 0 ? height / width : 1.0;
    final w = math.max(minSize, p.x - x);
    return {'width': w, 'height': w * aspect};
  }

  @override
  Map<String, Object?> translated(double dx, double dy) => {'x': x + dx, 'y': y + dy};

  /// 點選兩點、輸入實際距離後，以第一點為基準等比例縮放。
  Map<String, Object?> calibrated(Pt p1, Pt p2, double realDistance) {
    final measured = math.sqrt(math.pow(p2.x - p1.x, 2) + math.pow(p2.y - p1.y, 2));
    if (measured <= 0 || realDistance <= 0) return const {};
    final k = realDistance / measured;
    return {
      'x': p1.x + (x - p1.x) * k,
      'y': p1.y + (y - p1.y) * k,
      'width': width * k,
      'height': height * k,
    };
  }
}

// ====================================================================== 貨櫃型聯結車
const Map<String, String> truckViews = {'side': '側面（車身與吊臂平行）', 'rear': '車尾（車身與吊臂垂直）'};
const Map<String, String> truckFacings = {'left': '車頭朝左', 'right': '車頭朝右'};
const Map<String, (String, double)> containerSizes = {
  'none': ('無貨櫃（空車）', 0.0),
  '20ft': ('20 呎（長 6.06 m）', 6.058),
  '40ft': ('40 呎（長 12.19 m）', 12.192),
  '45ft': ('45 呎（長 13.72 m）', 13.716),
};
const Map<String, (String, double)> containerTypes = {
  'standard': ('標準櫃（高 2.59 m）', 2.591),
  'high': ('高櫃（高 2.90 m）', 2.896),
};
const double containerWidth = 2.438;

/// 聯結車的一個部位（軸對齊方框）。grounded：此部位下方到地面都算車身。
class TruckBox {
  final String part;
  final double x0, y0, x1, y1;
  final bool grounded;

  const TruckBox(this.part, this.x0, this.y0, this.x1, this.y1, [this.grounded = true]);
}

/// 停放的貨櫃型聯結車（曳引車 + 拖車 + 貨櫃）。x = 車輛左端距迴轉中心，y = 輪胎接地處高程。
class TruckObject extends SceneObject {
  static const double gap = 0.8;

  final String containerFill;
  final double x, y;
  final String view, facing;
  final double cabLength, cabHeight, trailerLength, deckHeight, width;
  final String container, containerType;

  TruckObject._(super.base, this.containerFill, this.x, this.y, this.view, this.facing, this.cabLength,
      this.cabHeight, this.trailerLength, this.deckHeight, this.width, this.container, this.containerType);

  factory TruckObject.fromJson(Map<String, Object?> m) {
    String pick(String k, String dflt, Iterable<String> ok) {
      final v = _s(m, k, dflt);
      return ok.contains(v) ? v : dflt;
    }

    return TruckObject._(
      Base.read(m, name: '貨櫃型聯結車', fill: '#3d7cc9', stroke: '#243447', opacity: 0.95, collision: true),
      _s(m, 'container_fill', '#c0504d'),
      _d(m, 'x', 8.0),
      _d(m, 'y', 0.0),
      pick('view', 'side', truckViews.keys),
      pick('facing', 'left', truckFacings.keys),
      _d(m, 'cab_length', 6.5),
      _d(m, 'cab_height', 3.3),
      _d(m, 'trailer_length', 12.5),
      _d(m, 'deck_height', 1.35),
      _d(m, 'width', 2.5),
      pick('container', '40ft', containerSizes.keys),
      pick('container_type', 'standard', containerTypes.keys),
    );
  }

  factory TruckObject({String? id, double? x, double? y}) => TruckObject.fromJson({'id': id, 'x': x, 'y': y});

  @override
  String get kind => 'truck';
  @override
  String get label => '貨櫃型聯結車';
  @override
  bool get collidable => true;
  @override
  bool get supportsLoad => true;

  @override
  Map<String, Object?> fields() => {
        'container_fill': containerFill,
        'x': x,
        'y': y,
        'view': view,
        'facing': facing,
        'cab_length': cabLength,
        'cab_height': cabHeight,
        'trailer_length': trailerLength,
        'deck_height': deckHeight,
        'width': width,
        'container': container,
        'container_type': containerType,
      };

  double get containerLength => containerSizes[container]!.$2;

  double get containerHeight => containerLength > 0 ? containerTypes[containerType]!.$2 : 0.0;

  double get cabinLength => math.min(2.4, 0.45 * cabLength);

  double get wheelRadius => math.max(0.2, math.min(0.52, (deckHeight - 0.3) / 2));

  double get totalLength => [cabLength, _trailerOffset() + trailerLength, _containerOffset() + containerLength]
      .reduce(math.max);

  double get topHeight => math.max(cabHeight, deckHeight + containerHeight);

  double extent() => view == 'side' ? totalLength : width;

  double _trailerOffset() => cabinLength + gap;

  double _containerOffset() {
    final cl = containerLength;
    final t0 = _trailerOffset();
    return cl <= trailerLength ? t0 + (trailerLength - cl) / 2 : t0;
  }

  List<TruckBox> boxes() {
    if (view == 'rear') {
      final x0 = x, w = width;
      final r2 = 2 * wheelRadius;
      final tire = math.min(0.6, w * 0.25);
      final cw = math.min(containerWidth, w);
      final out = [
        TruckBox('cab', x0 + 0.05, y + deckHeight - 0.3, x0 + w - 0.05, y + math.max(cabHeight, deckHeight - 0.3)),
        TruckBox('tire', x0, y, x0 + tire, y + r2),
        TruckBox('tire', x0 + w - tire, y, x0 + w, y + r2),
        TruckBox('deck', x0, y + deckHeight - 0.3, x0 + w, y + deckHeight),
      ];
      if (containerHeight > 0) {
        final cx = x0 + (w - cw) / 2;
        out.add(TruckBox('container', cx, y + deckHeight, cx + cw, y + deckHeight + containerHeight, false));
      }
      return out;
    }
    final cl = cabinLength;
    final frameTop = math.min(1.1, deckHeight - 0.15);
    final t0 = _trailerOffset();
    final rel = [
      TruckBox('frame', 0.1, 0.6, cabLength, math.max(0.75, frameTop)),
      TruckBox('deck', t0, deckHeight - 0.3, t0 + trailerLength, deckHeight),
      TruckBox('cab', 0.0, 0.5, cl, cabHeight),
    ];
    if (containerHeight > 0) {
      final c0 = _containerOffset();
      rel.add(TruckBox('container', c0, deckHeight, c0 + containerLength, deckHeight + containerHeight, false));
    }
    return [for (final b in rel) _place(b)];
  }

  /// 側面車輪 (中心 x, 中心 y, 半徑)；車尾方向時不畫圓輪。
  List<(double, double, double)> wheels() {
    if (view != 'side') return const [];
    final r = wheelRadius;
    const rr = 0.52;
    final front = math.min(1.4, cabinLength * 0.6);
    final xs = <(double, double)>[(front, rr)];
    final rear = cabLength - 0.9;
    xs.add((rear, rr));
    if (cabLength >= 5.5) xs.add((rear - 1.35, rr));
    final tEnd = _trailerOffset() + trailerLength;
    final n = trailerLength >= 10 ? 3 : (trailerLength >= 6 ? 2 : 1);
    for (var i = 0; i < n; i++) {
      xs.add((tEnd - 1.3 - 1.3 * i, r));
    }
    return [for (final (cx, rad) in xs) (_mx(cx), y + rad, rad)];
  }

  /// 拖車支撐腳 (x, 上端 y, 下端 y)。
  (double, double, double)? landingLeg() {
    if (view != 'side') return null;
    final t0 = _trailerOffset();
    final rel = math.min(math.max(t0 + 2.2, cabLength + 0.6), t0 + trailerLength * 0.45);
    return (_mx(rel), y + deckHeight - 0.3, y + 0.3);
  }

  double _mx(double relX) => facing == 'right' ? x + totalLength - relX : x + relX;

  TruckBox _place(TruckBox b) {
    final a = _mx(b.x0), c = _mx(b.x1);
    return TruckBox(b.part, math.min(a, c), y + b.y0, math.max(a, c), y + b.y1, b.grounded);
  }

  /// 由左到右的區段 (x0, x1, 底, 頂)。
  List<(double, double, double, double)> profile() {
    final bs = boxes();
    final xs = {for (final b in bs) ...[b.x0, b.x1]}.toList()..sort();
    final segs = <(double, double, double, double)>[];
    for (var i = 0; i < xs.length - 1; i++) {
      final a = xs[i], c = xs[i + 1];
      if (c - a < 1e-9) continue;
      final m = (a + c) / 2;
      final cover = [for (final b in bs) if (b.x0 <= m && m <= b.x1) b];
      if (cover.isEmpty) continue;
      final top = cover.map((b) => b.y1).reduce(math.max);
      final bottom = cover.any((b) => b.grounded) ? y : cover.map((b) => b.y0).reduce(math.min);
      segs.add((a, c, bottom, top));
    }
    return segs;
  }

  /// 可放置吊物的頂面 (x0, x1, 高程)。
  List<(double, double, double)> topSegments() => [for (final (a, c, _, top) in profile()) (a, c, top)];

  /// [a, b] 範圍內車頂最高處；不重疊時為 null。
  double? topMax(double a, double b) {
    final lo = math.min(a, b), hi = math.max(a, b);
    final tops = [for (final (x0, x1, t) in topSegments()) if (x0 < hi && x1 > lo) t];
    return tops.isEmpty ? null : tops.reduce(math.max);
  }

  @override
  List<Pt> outline() {
    final segs = profile();
    if (segs.isEmpty) return [pt(x, y)];
    final bottom = <Pt>[for (final (a, c, lo, _) in segs) ...[pt(a, lo), pt(c, lo)]];
    final top = <Pt>[for (final (a, c, _, hi) in segs.reversed) ...[pt(c, hi), pt(a, hi)]];
    final pts = <Pt>[];
    for (final p in [...bottom, ...top]) {
      if (pts.isEmpty || (p.x - pts.last.x).abs() > 1e-9 || (p.y - pts.last.y).abs() > 1e-9) pts.add(p);
    }
    final out = <Pt>[];
    final n = pts.length;
    for (var i = 0; i < n; i++) {
      final p = pts[i], q = pts[(i - 1 + n) % n], r = pts[(i + 1) % n];
      if (((p.x - q.x) * (r.y - q.y) - (p.y - q.y) * (r.x - q.x)).abs() > 1e-12) out.add(p);
    }
    return out;
  }

  @override
  Pt anchor() => pt(x, y);

  @override
  Map<String, Object?> translated(double dx, double dy) => {'x': x + dx, 'y': y + dy};

  @override
  Shape collisionShape() => (outline(), true);

  @override
  List<Pt> keyPoints() => [
        ...outline(),
        for (final b in boxes()) ...[pt(b.x0, b.y1), pt(b.x1, b.y1)]
      ];
}

// ====================================================================== 註冊表
const List<String> objectKinds = [
  'rect', 'polygon', 'load', 'wire', 'ground', 'text', 'dimension', 'image', 'truck' //
];

SceneObject objectFromJson(Map<String, Object?> d) => switch (d['kind']) {
      'rect' => RectObject.fromJson(d),
      'polygon' => PolygonObject.fromJson(d),
      'load' => LoadObject.fromJson(d),
      'wire' => WireObject.fromJson(d),
      'ground' => GroundObject.fromJson(d),
      'text' => TextObject.fromJson(d),
      'dimension' => DimensionObject.fromJson(d),
      'image' => ImageObject.fromJson(d),
      'truck' => TruckObject.fromJson(d),
      _ => throw FormatException('不認得的物件種類：${d['kind']}'),
    };
