/// 圖面的操作狀態與邏輯（移植自桌面版 ui/canvas_view.py，改成觸控操作）。
///
/// 座標：場景單位 = 公尺，Y 向上；螢幕 = (ox + x·s, oy − y·s)。
/// - 單指：拖曳紅點 / 主臂 / 物件 / 控制點；拖曳空白處平移；點一下選取
/// - 雙指：縮放與平移（任何模式都可以）
/// - 建立、量測、比例校正模式：單指用來畫，雙指平移縮放
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../../core/collision.dart' show pointInPolygon, pointSegmentDistance;
import '../../core/geometry.dart' as geo;
import '../../core/geometry.dart' show OutOfReachError, Pt, pt;
import '../../models/crane_spec.dart' show overhoistWarning;
import '../../models/objects.dart';
import '../../models/safety.dart' as sf;
import '../../models/simulation.dart';
import 'text_metrics.dart';

const double leftStrip = 38;
const double bottomStrip = 24;
const double minScale = 0.3, maxScale = 400.0;
const double keySnapPx = 14; // 吸附到特徵點的距離 (px)
const double touchSlop = 7; // 移動超過這麼多 px 才算拖曳
const double handleHitPx = 20; // 控制點可點範圍半徑 (px)
const double tipHitPx = 24; // 尖端紅點可點範圍半徑 (px)
const double lineHitPx = 12; // 線條可點範圍 (px)
const double boomGrabPx = 26; // 臂身太細時至少保留的可點寬度 (px)
const double boomRoot = 0.45; // 臂根往鉸點後方延伸的長度 (m)
const double radiusSnapPx = 10;
const double radiusSnapMax = 0.15;

const Set<String> twoPointKinds = {'rect', 'ground', 'wire', 'dimension'};
const Map<String, String> createHints = {
  'rect': '拖曳拉出矩形（點一下建立 4×4 m）',
  'polygon': '逐點點選頂點，按「完成」結束',
  'wire': '拖曳畫出電線 / 線段',
  'ground': '拖曳：左右決定範圍、放開處高度決定高程',
  'dimension': '拖曳量出尺寸標註',
  'text': '點選文字位置',
  'truck': '點一下放置貨櫃型聯結車（點的位置＝車輛左端，自動放在該處地面上）',
};

/// (類型, 選單文字)
const List<(String, String)> objectMenu = [
  ('rect', '矩形障礙物（建物、牌架、高架橋）'),
  ('polygon', '多邊形（斜屋頂、階梯建物、邊坡）'),
  ('load', '吊物（掛在尖端下方）'),
  ('truck', '貨櫃型聯結車（停放車輛，可放置吊物）'),
  ('wire', '電線 / 線段'),
  ('ground', '地面高程（坑洞、樓板）'),
  ('text', '文字註記'),
  ('dimension', '尺寸標註'),
  ('image', '背景圖（匯入立面圖）…'),
];

double _niceStepFor(double pxPerM, double minPx) {
  for (final step in const [0.1, 0.2, 0.5, 1.0, 2.0, 5.0, 10.0, 20.0, 50.0, 100.0, 200.0, 500.0]) {
    if (step * pxPerM >= minPx) return step;
  }
  return 1000;
}

double niceStep(double pxPerM, double minPx) => _niceStepFor(pxPerM, minPx);

double dist(Pt a, Pt b) => math.sqrt((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y));

/// 量測結果。
class Measurement {
  final Pt a, b;
  Measurement(this.a, this.b);
  double get dx => (b.x - a.x).abs();
  double get dy => (b.y - a.y).abs();
  double get distance => math.sqrt(dx * dx + dy * dy);
  double get angle => (dx == 0 && dy == 0) ? 0.0 : geo.degrees(math.atan2(dy, dx));
}

/// 單指操作的種類。
enum _Kind { none, pan, handle, mainTip, jibTip, boom, object, load, create, measure, calibrate, polygonTap, tapOnly }

class CanvasController extends ChangeNotifier {
  final SimulationModel model;

  CanvasController(this.model) : _lastSpec = model.spec {
    model.addListener(_onModel);
  }

  @override
  void dispose() {
    model.removeListener(_onModel);
    super.dispose();
  }

  Object _lastSpec;

  // ================================================================ 視圖
  double scale = 20.0; // 每公尺像素
  double ox = 0, oy = 0;
  Size size = Size.zero;
  bool _fitted = false;

  bool showCrosshair = true;
  bool showBodyDims = true;
  double snapStep = 0.5; // 格線吸附間距；0 = 不吸附格線
  bool snapOn = true; // 吸附（特徵點、格線、荷重表半徑）總開關
  bool freeTipDrag = false; // 紅點拖曳：false = 只改臂長；true = 同時改臂長與臂角
  bool multiSelect = false;

  Offset toScreen(Pt p) => Offset(ox + p.x * scale, oy - p.y * scale);
  Pt toWorld(Offset o) => pt((o.dx - ox) / scale, (oy - o.dy) / scale);

  /// n 像素換算成公尺。
  double px(double n) => n / scale;

  /// 可視範圍（公尺）：(左, 下, 右, 上)
  (double, double, double, double) visible() {
    final a = toWorld(Offset.zero), b = toWorld(Offset(size.width, size.height));
    return (a.x, b.y, b.x, a.y);
  }

  /// 圖面大小（由 LayoutBuilder 在繪製前設定；不通知，避免在 build 中觸發重建）。
  /// 寬度改變（旋轉螢幕、換版面）時重新縮放到全圖；只有高度改變（鍵盤、拖曳面板）時保持畫面中心。
  void setSize(Size s) {
    if (s == size) return;
    final refit = !_fitted || (s.width - size.width).abs() > 1;
    final old = size;
    size = s;
    if (refit) {
      resetView(notify: false);
    } else {
      ox += (s.width - old.width) / 2;
      oy += (s.height - old.height) / 2;
    }
  }

  void resetView({bool notify = true}) {
    if (size.width <= 0 || size.height <= 0) return;
    final m = model;
    final lim = m.limits;
    final specLim = m.spec.limits; // 長度不限制後，視圖以「規格參考長度」與目前長度較大者為準
    var reach = math.max(specLim.boomMax, m.pose.length);
    if (m.pose.jibEnabled) reach += math.max(specLim.jibMax, m.pose.jibLength);
    final top = math.max(lim.pivotY + reach, 12.0) + 2;
    final right = math.max(24.0, lim.pivotX + reach);
    final left = math.min(-6.8, m.bodyLayout().rearX - 0.8);
    final extra = showBodyDims ? 60.0 : 0.0; // 顯示車體尺寸時，地面下方保留約 60 px 給尺寸線
    final leftPx = showBodyDims ? 70.0 : 0.0;
    fitRect(left, -0.6, right, top, bottomPx: extra, leftPx: leftPx, notify: notify);
    _fitted = true;
  }

  /// 讓 [x0, x1] × [y0, y1] 填滿可視區；bottomPx / leftPx 為下方、左方額外保留的像素。
  void fitRect(double x0, double y0, double x1, double y1,
      {double bottomPx = 0, double leftPx = 0, bool notify = true}) {
    final vw = math.max(50.0, size.width - leftStrip - leftPx - 8);
    final vh = math.max(50.0, size.height - bottomStrip - bottomPx - 8);
    var s = math.min(vw / (x1 - x0), vh / (y1 - y0));
    s = s.clamp(minScale, maxScale);
    scale = s;
    final cx = (x0 + x1) / 2, cy = (y0 + y1) / 2;
    final scx = (size.width + leftStrip + leftPx) / 2, scy = (size.height - bottomStrip - bottomPx) / 2;
    ox = scx - cx * s;
    oy = scy + cy * s;
    if (notify) notifyListeners();
  }

  void panBy(Offset d) {
    ox += d.dx;
    oy += d.dy;
    notifyListeners();
  }

  /// 以螢幕上的 focal 為中心縮放。
  void zoomAt(Offset focal, double factor) {
    final ns = (scale * factor).clamp(minScale, maxScale);
    final f = ns / scale;
    if (f == 1.0) return;
    ox = focal.dx - (focal.dx - ox) * f;
    oy = focal.dy - (focal.dy - oy) * f;
    scale = ns;
    notifyListeners();
  }

  void setOption(void Function() change) {
    change();
    notifyListeners();
  }

  // ================================================================ 選取
  final List<String> selection = [];

  List<String> selectedIds() => List.of(selection);

  void selectIds(Iterable<String> ids, {bool center = false}) {
    final want = ids.toSet();
    selection
      ..clear()
      ..addAll([
        for (final o in model.objects())
          if (want.contains(o.id) && o.visible) o.id
      ]);
    if (center && selection.length == 1) {
      final o = model.get(selection.first)!;
      final (x0, y0, x1, y1) = _objectBounds(o);
      final c = pt((x0 + x1) / 2, (y0 + y1) / 2);
      final (vl, vb, vr, vt) = visible();
      if (!(vl <= c.x && c.x <= vr && vb <= c.y && c.y <= vt)) {
        final s = toScreen(c);
        ox += size.width / 2 - s.dx;
        oy += size.height / 2 - s.dy;
      }
    }
    notifyListeners();
  }

  void _toggleSelect(String oid) {
    if (selection.contains(oid)) {
      selection.remove(oid);
    } else {
      selection.add(oid);
    }
    notifyListeners();
  }

  void _onModel() {
    // 被刪除或隱藏的物件取消選取
    final before = selection.length;
    selection.removeWhere((i) => model.get(i) == null || !model.get(i)!.visible);
    if (!identical(model.spec, _lastSpec)) {
      _lastSpec = model.spec;
      resetView();
    }
    if (selection.length != before) notifyListeners();
  }

  (double, double, double, double) _objectBounds(SceneObject o) {
    if (o is TextObject) return textRect(o);
    if (o is LoadObject) {
      final pts = model.loadOutline(o);
      final tip = model.riggingTip();
      return (pts[0].x, pts[0].y, pts[2].x, tip.y);
    }
    return o.bounds();
  }

  // ================================================================ 模式
  String mode = 'select'; // select / create / measure / calibrate
  String createKind = '';
  String calibTarget = '';
  String hint = '';
  List<Pt> previewPts = []; // 建立中的點（兩點類型：[起點, 目前點]；多邊形：已點的頂點）
  Measurement? measurement;
  Pt? cursor; // 目前手指 / 滑鼠位置（場景座標，未吸附）

  /// 顯示訊息（例如錯誤）；由介面設定。
  void Function(String message)? onMessage;

  /// 建立文字註記時詢問內容；由介面設定。
  Future<String?> Function()? askText;

  /// 背景圖比例校正：點完兩點後由介面詢問實際距離。
  void Function(String oid, Pt a, Pt b)? onCalibrationPicked;

  void setMode(String m, {String kind = '', String target = ''}) {
    mode = m;
    createKind = kind;
    calibTarget = target;
    previewPts = [];
    if (m != 'measure') measurement = null;
    hint = switch (m) {
      'create' => createHints[kind] ?? '',
      'measure' => '量測：拖曳兩點，顯示距離、角度與水平 / 垂直距離',
      'calibrate' => '比例校正：在背景圖上點選已知距離的兩點',
      _ => '',
    };
    _gesture = _Kind.none;
    notifyListeners();
  }

  // ================================================================ 吸附
  List<Pt> _keyPoints(String? exclude) {
    final m = model;
    final r = m.result;
    final pts = <Pt>[pt(0.0, 0.0), r.pivot, r.mainTip];
    if (r.jibTip != null) pts.add(r.jibTip!);
    if (r.auxTip != null) pts.add(r.auxTip!);
    for (final o in m.objects()) {
      if (!o.visible || o.id == exclude) continue;
      if (o is LoadObject) {
        pts.addAll(m.loadOutline(o));
        pts.add(o.hookAt(m.riggingTip()));
      } else {
        pts.addAll(o.keyPoints());
      }
    }
    return pts;
  }

  Pt snapPoint(Pt p, {String? exclude, bool keys = true, bool grid = true}) {
    if (!snapOn) return p;
    if (keys) {
      Pt? best;
      var bestD = px(keySnapPx);
      for (final k in _keyPoints(exclude)) {
        final d = dist(k, p);
        if (d < bestD) {
          best = k;
          bestD = d;
        }
      }
      if (best != null) return best;
    }
    if (grid && snapStep > 0) {
      final s = snapStep;
      return pt((p.x / s).round() * s, (p.y / s).round() * s);
    }
    return p;
  }

  double _snapValue(double v) {
    if (!snapOn || snapStep <= 0) return v;
    return (v / snapStep).round() * snapStep;
  }

  double radiusSnap() => snapOn ? math.min(px(radiusSnapPx), radiusSnapMax) : 0.0;

  // ================================================================ 點選判斷
  int? _handleAt(Offset s) {
    if (selection.length != 1) return null;
    final o = model.get(selection.first);
    if (o == null || o.locked || !o.visible) return null;
    final hs = o.handles();
    for (var i = hs.length - 1; i >= 0; i--) {
      if ((toScreen(hs[i]) - s).distance <= handleHitPx) return i;
    }
    return null;
  }

  bool hitBoom(Pt p) {
    final m = model;
    final pose = m.geometryPose;
    final lim = m.limits;
    final t = geo.radians(pose.angle);
    final hw = math.max(m.spec.boomWidth, px(boomGrabPx)) / 2;
    final o = m.spec.boomBodyOffset;
    final axisLen = lim.axisLength(pose.length);
    final dx = p.x - lim.pivotX, dy = p.y - lim.pivotY;
    final along = dx * math.cos(t) + dy * math.sin(t);
    final perp = -dx * math.sin(t) + dy * math.cos(t);
    return -boomRoot <= along && along <= axisLen && (perp - o).abs() <= hw;
  }

  bool hitObject(SceneObject o, Pt p) {
    final tol = px(lineHitPx);
    switch (o) {
      case WireObject():
        return pointSegmentDistance(p, pt(o.x1, o.y1), pt(o.x2, o.y2)) <= tol;
      case DimensionObject():
        return pointSegmentDistance(p, pt(o.x1, o.y1), pt(o.x2, o.y2)) <= tol;
      case TextObject():
        final (x0, y0, x1, y1) = textRect(o);
        return x0 - tol <= p.x && p.x <= x1 + tol && y0 - tol <= p.y && p.y <= y1 + tol;
      case LoadObject():
        final tip = model.riggingTip();
        if (pointInPolygon(p, model.loadOutline(o))) return true;
        final hook = o.hookAt(tip);
        final (l, r) = o.attachPoints(tip);
        return pointSegmentDistance(p, tip, hook) <= tol ||
            pointSegmentDistance(p, l, hook) <= tol ||
            pointSegmentDistance(p, r, hook) <= tol;
      default:
        final outline = o.outline();
        if (outline.length < 3) return false;
        return pointInPolygon(p, outline);
    }
  }

  /// 由上到下第一個點到的物件（吊物在最上層）。
  SceneObject? objectAt(Pt p, {bool loadOnly = false, bool skipLoad = false}) {
    final objs = model.objects();
    for (final o in objs.reversed) {
      if (!o.visible) continue;
      final isLoad = o is LoadObject;
      if (loadOnly && !isLoad) continue;
      if (skipLoad && isLoad) continue;
      if (hitObject(o, p)) return o;
    }
    return null;
  }

  // ================================================================ 單指操作
  _Kind _gesture = _Kind.none;
  Offset _downScreen = Offset.zero;
  Offset _lastScreen = Offset.zero;
  Pt _downWorld = pt(0, 0);
  bool _moved = false;
  String? _targetId;
  int _handleIndex = -1;
  Offset _tipGrab = Offset.zero; // 紅點中心 − 手指位置（螢幕 px）
  double _grabOffset = 0.0;
  Map<String, Object?>? _drag; // 物件拖曳狀態（同桌面版）

  bool get gestureActive => _gesture != _Kind.none;
  bool get draggingBoom => _gesture == _Kind.boom && _moved;
  bool get draggingMainTip => _gesture == _Kind.mainTip;
  bool get draggingJibTip => _gesture == _Kind.jibTip;

  /// 手指 / 滑鼠移動（未按下）：更新游標位置（預覽聯結車、吸附十字）。
  void hover(Offset s) {
    cursor = toWorld(s);
    if (mode != 'select') notifyListeners();
  }

  void pointerDown(Offset s) {
    _downScreen = s;
    _lastScreen = s;
    final p = toWorld(s);
    _downWorld = p;
    cursor = p;
    _moved = false;
    _targetId = null;
    _gesture = _Kind.none;

    switch (mode) {
      case 'create':
        if (twoPointKinds.contains(createKind)) {
          _gesture = _Kind.create;
          final q = snapPoint(p);
          previewPts = [q, q];
        } else if (createKind == 'polygon') {
          _gesture = _Kind.polygonTap;
        } else {
          _gesture = _Kind.tapOnly; // 文字、聯結車：點一下放置
        }
        notifyListeners();
        return;
      case 'measure':
        _gesture = _Kind.measure;
        final q = snapPoint(p);
        previewPts = [q, q];
        measurement = null;
        notifyListeners();
        return;
      case 'calibrate':
        _gesture = _Kind.calibrate;
        return;
    }

    // 選取模式：控制點 > 尖端紅點 > 吊物 > 主臂 > 其他物件 > 平移
    final h = _handleAt(s);
    if (h != null) {
      _gesture = _Kind.handle;
      _targetId = selection.first;
      _handleIndex = h;
      return;
    }
    final r = model.result;
    if (r.jibTip != null && (toScreen(r.jibTip!) - s).distance <= tipHitPx) {
      _gesture = _Kind.jibTip;
      _tipGrab = toScreen(r.jibTip!) - s;
      return;
    }
    if ((toScreen(r.mainTip) - s).distance <= tipHitPx) {
      _gesture = _Kind.mainTip;
      _tipGrab = toScreen(r.mainTip) - s;
      return;
    }
    final load = objectAt(p, loadOnly: true);
    if (load != null) {
      _gesture = _Kind.load;
      _targetId = load.id;
      return;
    }
    if (hitBoom(p)) {
      _gesture = _Kind.boom;
      return;
    }
    final o = objectAt(p, skipLoad: true);
    if (o != null) {
      _gesture = _Kind.object;
      _targetId = o.id;
      return;
    }
    _gesture = _Kind.pan;
  }

  void pointerMove(Offset s) {
    if (_gesture == _Kind.none) return;
    final delta = s - _lastScreen;
    _lastScreen = s;
    cursor = toWorld(s);
    if (!_moved) {
      if ((s - _downScreen).distance < touchSlop) {
        if (mode != 'select') notifyListeners();
        return;
      }
      _moved = true;
      _beginDrag();
    }
    final p = toWorld(s);
    switch (_gesture) {
      case _Kind.pan:
        panBy(delta);
      case _Kind.handle:
        _handleDrag(p);
      case _Kind.mainTip:
        final q = toWorld(s + _tipGrab);
        _guard(() {
          if (freeTipDrag) {
            model.dragMainTip(q.x, q.y, radiusSnap()); // 自由拖曳：臂長 + 臂角
          } else {
            model.dragMainTipLength(q.x, q.y);
          }
        });
      case _Kind.jibTip:
        final q = toWorld(s + _tipGrab);
        _guard(() => model.dragJibTip(q.x, q.y));
      case _Kind.boom:
        _guard(() => model.dragBoomAngle(p.x, p.y, _grabOffset, radiusSnap()));
      case _Kind.object:
      case _Kind.load:
        _objectDrag(p);
      case _Kind.create:
      case _Kind.measure:
        previewPts[1] = snapPoint(p);
        if (_gesture == _Kind.measure) measurement = Measurement(previewPts[0], previewPts[1]);
        notifyListeners();
      default:
        if (mode != 'select') notifyListeners();
    }
  }

  void _beginDrag() {
    switch (_gesture) {
      case _Kind.handle:
        _beginHandleDrag(_targetId!, _handleIndex);
      case _Kind.mainTip:
      case _Kind.jibTip:
        model.beginPoseDrag();
      case _Kind.boom:
        _grabOffset = model.boomGrabOffset(_downWorld.x, _downWorld.y);
        model.beginPoseDrag();
        notifyListeners();
      case _Kind.object:
      case _Kind.load:
        final oid = _targetId!;
        if (!selection.contains(oid)) {
          if (multiSelect) {
            selection.add(oid);
          } else {
            selection
              ..clear()
              ..add(oid);
          }
        }
        _beginObjectDrag(oid, _downWorld);
        notifyListeners();
      default:
        break;
    }
  }

  void pointerUp(Offset s) {
    final g = _gesture;
    _gesture = _Kind.none;
    if (g == _Kind.none) return;
    final p = toWorld(s);
    if (!_moved) {
      _tap(g, p);
      return;
    }
    switch (g) {
      case _Kind.handle:
        _endHandleDrag();
      case _Kind.mainTip:
        model.endPoseDrag('拖曳臂長');
      case _Kind.jibTip:
        model.endPoseDrag('拖曳助臂');
      case _Kind.boom:
        model.endPoseDrag('拖曳主臂角度');
        notifyListeners();
      case _Kind.object:
      case _Kind.load:
        _endObjectDrag();
      case _Kind.create:
        final a = previewPts[0], b = previewPts[1];
        previewPts = [];
        _createTwoPoint(a, b);
      case _Kind.measure:
        final a = previewPts[0], b = previewPts[1];
        previewPts = [];
        measurement = dist(a, b) > 1e-6 ? Measurement(a, b) : null;
        notifyListeners();
      default:
        notifyListeners();
    }
  }

  /// 第二隻手指放下（改為縮放 / 平移）：取消尚未開始的單指操作，已開始的照常結束。
  void cancelGesture() {
    if (_gesture == _Kind.none) return;
    if (_moved) {
      pointerUp(_lastScreen);
      return;
    }
    _gesture = _Kind.none;
    if (mode == 'create' && twoPointKinds.contains(createKind) || mode == 'measure') previewPts = [];
    notifyListeners();
  }

  void _tap(_Kind g, Pt p) {
    switch (g) {
      case _Kind.pan:
        if (!multiSelect) {
          selection.clear();
          notifyListeners();
        }
      case _Kind.object:
      case _Kind.load:
        if (multiSelect) {
          _toggleSelect(_targetId!);
        } else {
          selectIds([_targetId!]);
        }
      case _Kind.boom:
      case _Kind.mainTip:
      case _Kind.jibTip:
      case _Kind.handle:
        break;
      case _Kind.create:
        final a = previewPts[0];
        previewPts = [];
        _createTwoPoint(a, a);
      case _Kind.polygonTap:
        final q = snapPoint(p);
        if (previewPts.isEmpty || dist(previewPts.last, q) > 1e-6) previewPts = [...previewPts, q];
        notifyListeners();
      case _Kind.tapOnly:
        if (createKind == 'truck') {
          var obj = _truckAt(snapPoint(p, keys: false));
          final n = _count<TruckObject>();
          if (n > 0) obj = obj.copyWith({'name': '${obj.label} ${n + 1}'}) as TruckObject;
          _finishCreate(obj);
        } else if (createKind == 'text') {
          final q = snapPoint(p, keys: false);
          final ask = askText;
          if (ask == null) return;
          ask().then((text) {
            if (text != null && text.trim().isNotEmpty) {
              final name = text.split('\n').first;
              _finishCreate(TextObject.fromJson({
                'x': q.x,
                'y': q.y,
                'text': text,
                'name': name.length > 20 ? name.substring(0, 20) : name,
              }));
            } else {
              setMode('select');
            }
          });
        }
      case _Kind.measure:
        previewPts = [];
        measurement = null;
        notifyListeners();
      case _Kind.calibrate:
        previewPts = [...previewPts, p];
        if (previewPts.length == 2) {
          final a = previewPts[0], b = previewPts[1];
          final target = calibTarget;
          setMode('select');
          onCalibrationPicked?.call(target, a, b);
        } else {
          notifyListeners();
        }
      default:
        break;
    }
  }

  void _guard(void Function() fn) {
    try {
      fn();
    } on OutOfReachError catch (e) {
      onMessage?.call(e.message);
    }
  }

  // ================================================================ 物件拖曳
  void _beginObjectDrag(String oid, Pt pos) {
    final o = model.get(oid);
    if (o == null) return;
    if (o is LoadObject) {
      // 拖曳吊物＝捲揚機收放鋼索：只上下改吊掛長度，左右不動
      if (o.locked) {
        _drag = null;
        return;
      }
      final (lo, hi) = model.hoistDragRange(o);
      _drag = {'type': 'load', 'oid': oid, 'start_y': pos.y, 'hoist': o.hoist, 'lo': lo, 'hi': hi, 'begun': false};
      return;
    }
    final ids = [
      ...[for (final i in selection) if (i != oid) i],
      oid
    ];
    final objs = <String, SceneObject>{};
    for (final i in ids) {
      final ob = model.get(i);
      if (ob != null && ob.movable && !ob.locked) objs[i] = ob;
    }
    if (!objs.containsKey(oid)) {
      _drag = null;
      return;
    }
    _drag = {'type': 'move', 'start': pos, 'orig': objs, 'ref': objs[oid]!.anchor(), 'begun': false};
  }

  void _objectDrag(Pt pos) {
    final d = _drag;
    if (d == null) return;
    if (d['type'] == 'load') {
      final lo = d['lo'] as double, hi = d['hi'] as double;
      var hoist = (d['hoist'] as double) - (pos.y - (d['start_y'] as double)); // 往下拖 → 吊掛變長
      if (snapOn) hoist = (hoist * 10).round() / 10; // 0.1 m 為單位
      hoist = math.min(math.max(hoist, lo), hi); // 往上停在過捲極限、往下停在著地
      if (d['begun'] != true) {
        if ((hoist - (d['hoist'] as double)).abs() < 1e-9) return;
        model.beginEdit([d['oid'] as String]);
        d['begun'] = true;
      }
      model.setObjectLive(d['oid'] as String, {'hoist': hoist});
      return;
    }
    if (d['type'] != 'move') return;
    final ref = d['ref'] as Pt, start = d['start'] as Pt;
    final nx = _snapValue(ref.x + pos.x - start.x);
    final ny = _snapValue(ref.y + pos.y - start.y);
    final dx = nx - ref.x, dy = ny - ref.y;
    final orig = d['orig'] as Map<String, SceneObject>;
    if (d['begun'] != true) {
      if (dx.abs() < 1e-9 && dy.abs() < 1e-9) return;
      model.beginEdit(orig.keys);
      d['begun'] = true;
    }
    for (final MapEntry(key: oid, value: ob) in orig.entries) {
      model.setObjectLive(oid, ob.translated(dx, dy));
    }
  }

  void _endObjectDrag() {
    final d = _drag;
    _drag = null;
    if (d == null) return;
    if (d['type'] == 'load') {
      if (d['begun'] == true) model.endEdit('拖曳吊物（吊掛長度）');
    } else if (d['type'] == 'move' && d['begun'] == true) {
      final n = (d['orig'] as Map).length;
      model.endEdit(n == 1 ? '移動物件' : '移動 $n 個物件');
    }
  }

  // ---------------------------------------------------------------- 控制點
  void _beginHandleDrag(String oid, int index) {
    final o = model.get(oid);
    if (o == null || o.locked) {
      _drag = null;
      return;
    }
    model.beginEdit([oid]);
    _drag = {'type': 'handle', 'oid': oid, 'index': index, 'orig': o};
  }

  void _handleDrag(Pt pos) {
    final d = _drag;
    if (d == null || d['type'] != 'handle') return;
    final oid = d['oid'] as String;
    final p = snapPoint(pos, exclude: oid);
    model.setObjectLive(oid, (d['orig'] as SceneObject).withHandle(d['index'] as int, p));
  }

  void _endHandleDrag() {
    final d = _drag;
    _drag = null;
    if (d != null && d['type'] == 'handle') model.endEdit('調整形狀');
  }

  // ================================================================ 建立物件
  void _finishCreate(SceneObject obj) {
    try {
      model.addObject(obj);
    } on OutOfReachError catch (e) {
      onMessage?.call(e.message);
      setMode('select');
      return;
    }
    setMode('select');
    selectIds([obj.id]);
  }

  int _count<T>() => model.objects().whereType<T>().length;

  void _createTwoPoint(Pt a, Pt b) {
    final k = createKind;
    final small = dist(a, b) < 0.05;
    SceneObject obj;
    if (k == 'rect') {
      final n = _count<RectObject>() + 1;
      if (small) {
        obj = RectObject(x: a.x, y: a.y, width: 4.0, height: 4.0, name: '障礙物 $n');
      } else {
        final x0 = math.min(a.x, b.x), x1 = math.max(a.x, b.x);
        final y0 = math.min(a.y, b.y), y1 = math.max(a.y, b.y);
        obj = RectObject(
            x: x0, y: y0, width: math.max(0.1, x1 - x0), height: math.max(0.1, y1 - y0), name: '障礙物 $n');
      }
    } else if (k == 'ground') {
      final x2 = small ? a.x + 4.0 : b.x;
      final elev = small ? -1.0 : b.y;
      obj = GroundObject(x1: a.x, x2: x2, elevation: elev);
    } else if (k == 'wire') {
      final e = small ? pt(a.x + 10.0, a.y) : b;
      obj = WireObject.fromJson({'x1': a.x, 'y1': a.y, 'x2': e.x, 'y2': e.y});
    } else if (k == 'dimension') {
      if (small) {
        notifyListeners();
        return;
      }
      obj = DimensionObject(x1: a.x, y1: a.y, x2: b.x, y2: b.y);
    } else {
      return;
    }
    _finishCreate(obj);
  }

  /// 多邊形：按「完成」。
  void finishPolygon() {
    final clean = <Pt>[];
    for (final p in previewPts) {
      if (clean.isEmpty || dist(clean.last, p) > 1e-6) clean.add(p);
    }
    if (clean.length < 3) {
      onMessage?.call('多邊形至少需要 3 個頂點');
      return;
    }
    final obj = PolygonObject.fromJson({
      'points': [
        for (final p in clean) [p.x, p.y]
      ],
      'name': '多邊形 ${_count<PolygonObject>() + 1}',
    });
    previewPts = [];
    _finishCreate(obj);
  }

  /// 多邊形：刪除上一點。
  void undoPolygonPoint() {
    if (previewPts.isEmpty) return;
    previewPts = previewPts.sublist(0, previewPts.length - 1);
    notifyListeners();
  }

  /// 在 p 放一台聯結車：左端在 p.x，輪胎放在該處地面（0 m 或地面高程物件）上。
  TruckObject truckAt(Pt p) => _truckAt(p);

  TruckObject _truckAt(Pt p) {
    final grounds = [
      for (final o in model.objects())
        if (o is GroundObject && o.visible) o
    ];
    return TruckObject(x: p.x, y: sf.groundLevel(grounds, p.x));
  }

  /// 把目前量測結果保留為尺寸標註物件。
  void keepMeasurement() {
    final m = measurement;
    if (m == null) return;
    model.addObject(DimensionObject(x1: m.a.x, y1: m.a.y, x2: m.b.x, y2: m.b.y), label: '保留量測為尺寸標註');
    measurement = null;
    notifyListeners();
  }

  /// 新增物件（工具列「物件」選單）；吊物、背景圖直接新增，其他進入建立模式。
  void addKind(String kind) {
    if (kind == 'load') {
      final existing = model.load();
      if (existing != null) {
        selectIds([existing.id]);
        onMessage?.call('已經有吊物了（只能有一個），可在物件頁修改尺寸與重量');
        return;
      }
      // 預設吊掛長度：比過捲提早警告位置再低 0.2 m（電腦版固定 2 m，主吊鉤會一放上去就顯示過捲）
      final hoist = math.max(2.0, ((model.minHoist + overhoistWarning + 0.2) * 10).ceil() / 10);
      final obj = LoadObject(hoist: hoist);
      model.addObject(obj);
      selectIds([obj.id]);
      return;
    }
    setMode('create', kind: kind);
  }

  /// 目前要畫的游標十字（吸附後）。
  Pt? snappedCursor() {
    final c = cursor;
    if (c == null) return null;
    if (mode == 'calibrate') return c;
    if (mode == 'create' && (createKind == 'truck' || createKind == 'text')) return snapPoint(c, keys: false);
    return snapPoint(c);
  }
}
