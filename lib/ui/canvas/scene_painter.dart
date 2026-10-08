/// 圖面繪製（移植自桌面版 canvas_view.py、crane_item.py、object_items.py）。
///
/// 全部在螢幕座標畫：場景點用 c.toScreen() 換算；「固定像素」的線寬、標籤不隨縮放改變。
/// 繪製順序同桌面版：格線 → 物件 → 車體 → 吊臂 → 吊物 → 尖端紅點 → 控制點 → 十字線、工具、刻度。
library;

import 'dart:math' as math;

import 'package:flutter/painting.dart';
import 'package:flutter/foundation.dart' show Listenable;
import 'package:flutter/rendering.dart' show CustomPainter;

import '../../core/geometry.dart' as geo;
import '../../core/geometry.dart' show Pt, pt;
import '../../core/pyformat.dart';
import '../../core/vehicle.dart' show BodyLayout, RectXYWH;
import '../../models/objects.dart';
import '../../models/safety.dart' show SafetyReport;
import '../../models/simulation.dart';
import '../colors.dart' as k;
import 'canvas_controller.dart';
import 'scene_images.dart';
import 'text_metrics.dart';

// ====================================================================== 小工具
Paint _stroke(Color color, [double width = 1.0, StrokeCap cap = StrokeCap.butt]) => Paint()
  ..style = PaintingStyle.stroke
  ..color = color
  ..strokeWidth = width
  ..strokeCap = cap
  ..strokeJoin = StrokeJoin.round
  ..isAntiAlias = true;

Paint _fill(Color color) => Paint()
  ..style = PaintingStyle.fill
  ..color = color
  ..isAntiAlias = true;

Color _alpha(Color c, double opacity) => c.withValues(alpha: (c.a * opacity).clamp(0.0, 1.0));

Path _poly(List<Offset> pts, {bool close = true}) {
  final p = Path();
  if (pts.isEmpty) return p;
  p.moveTo(pts.first.dx, pts.first.dy);
  for (final q in pts.skip(1)) {
    p.lineTo(q.dx, q.dy);
  }
  if (close) p.close();
  return p;
}

/// 虛線（螢幕座標）；dash：[線, 空白, …] (px)。
void _dashLine(Canvas cv, Offset a, Offset b, Paint paint, [List<double> dash = const [5, 3]]) {
  final d = b - a;
  final len = d.distance;
  if (len < 1e-6) return;
  final u = d / len;
  var pos = 0.0;
  var i = 0;
  while (pos < len) {
    final seg = dash[i % dash.length];
    final end = math.min(len, pos + seg);
    if (i.isEven) cv.drawLine(a + u * pos, a + u * end, paint);
    pos = end;
    i++;
  }
}

void _dashPoly(Canvas cv, List<Offset> pts, Paint paint, {bool close = false, List<double> dash = const [5, 3]}) {
  for (var i = 0; i < pts.length - 1; i++) {
    _dashLine(cv, pts[i], pts[i + 1], paint, dash);
  }
  if (close && pts.length > 2) _dashLine(cv, pts.last, pts.first, paint, dash);
}

const _dot = [1.5, 3.0];

// ---------------------------------------------------------------- 標籤
final Map<String, TextPainter> _labelCache = {};

TextPainter _labelPainter(String text, Color color, double px, bool bold) {
  final key = '$text|${color.toARGB32()}|$px|$bold';
  final hit = _labelCache[key];
  if (hit != null) return hit;
  if (_labelCache.length > 3000) _labelCache.clear();
  final tp = TextPainter(
    text: TextSpan(
        text: text,
        style: TextStyle(
            fontFamily: k.appFont,
            fontSize: px,
            color: color,
            height: 1.2,
            fontWeight: bold ? FontWeight.w700 : FontWeight.w400)),
    textDirection: TextDirection.ltr,
  )..layout();
  return _labelCache[key] = tp;
}

/// 在螢幕座標 at 處畫固定像素大小的文字。align：tl / tc / c / bc / bl
void drawLabel(Canvas cv, Offset at, String text,
    {Color color = k.text,
    Color? bg,
    String align = 'tl',
    double dx = 0,
    double dy = 0,
    double px = 12,
    bool bold = false}) {
  if (text.isEmpty) return;
  final tp = _labelPainter(text, color, px, bold);
  final w = tp.width + 8, h = tp.height + 2;
  var x = at.dx + dx, y = at.dy + dy;
  if (align == 'tc' || align == 'c' || align == 'bc') x -= w / 2;
  if (align == 'c') {
    y -= h / 2;
  } else if (align == 'bc' || align == 'bl') {
    y -= h;
  }
  x = x.roundToDouble();
  y = y.roundToDouble();
  if (bg != null) {
    cv.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(x, y, w, h), const Radius.circular(3)), _fill(bg));
  }
  tp.paint(cv, Offset(x + 4, y + 1));
}

// ====================================================================== 繪製
class ScenePainter extends CustomPainter {
  final CanvasController c;
  final SceneImages images;

  ScenePainter(this.c, this.images, Listenable repaint) : super(repaint: repaint);

  SimulationModel get m => c.model;

  Offset P(Pt p) => c.toScreen(p);
  Offset xy(double x, double y) => c.toScreen(pt(x, y));
  double S(double meters) => meters * c.scale;

  @override
  bool shouldRepaint(covariant ScenePainter old) => true;

  @override
  void paint(Canvas cv, Size size) {
    cv.clipRect(Offset.zero & size);
    _background(cv, size);
    final rep = m.safety(); // 每次變動只算一次，所有物件共用
    final objs = m.objects();
    for (final o in objs) {
      if (!o.visible || o is LoadObject) continue;
      _object(cv, o, rep);
    }
    _body(cv);
    _boom(cv, rep);
    for (final o in objs) {
      if (o is LoadObject && o.visible) _object(cv, o, rep);
    }
    _tipHandles(cv);
    _objectHandles(cv);
    _foreground(cv, size);
  }

  // ================================================================ 背景格線
  void _background(Canvas cv, Size size) {
    cv.drawRect(Offset.zero & size, _fill(k.bg));
    final (l, b, r, t) = c.visible();
    final s = c.scale;
    final step = niceStep(s, 9);
    final major = step * 5;
    for (final (st, color) in [(step, k.gridMinor), (major, k.gridMajor)]) {
      final p = _stroke(color, 1);
      for (var i = (l / st).floor(); i * st <= r; i++) {
        final x = c.ox + i * st * s;
        cv.drawLine(Offset(x, 0), Offset(x, size.height), p);
      }
      for (var i = (b / st).floor(); i * st <= t; i++) {
        final y = c.oy - i * st * s;
        cv.drawLine(Offset(0, y), Offset(size.width, y), p);
      }
    }
    cv.drawLine(Offset(0, c.oy), Offset(size.width, c.oy), _stroke(k.axis, 1.5));
    _dashLine(cv, Offset(c.ox, 0), Offset(c.ox, size.height), _stroke(k.axis, 1));
  }

  // ================================================================ 車體
  Rect _rect(RectXYWH r) => Rect.fromPoints(xy(r.$1, r.$2), xy(r.$1 + r.$3, r.$2 + r.$4));

  void _body(Canvas cv) {
    final L = m.bodyLayout();
    final edge = _stroke(k.outline, 1);
    void rect(RectXYWH r, Color fill) {
      final rr = _rect(r);
      cv.drawRect(rr, _fill(fill));
      cv.drawRect(rr, edge);
    }

    void polygon(List<Pt> pts, Color fill) {
      final path = _poly([for (final p in pts) P(p)]);
      cv.drawPath(path, _fill(fill));
      cv.drawPath(path, edge);
    }

    for (final r in [...L.outriggerLegs, ...L.outriggerPads]) {
      rect(r, const Color(0xff8a8a8a));
    }
    for (final r in L.bumpers) {
      rect(r, const Color(0xffa9a9a9)); // 底盤延伸段（底盤以外到車頭 / 車尾）
    }
    rect(L.chassis, k.bodyGrey);
    for (final (cx, cy, r) in L.wheels) {
      final ctr = xy(cx, cy);
      cv.drawCircle(ctr, S(r), _fill(const Color(0xff555555)));
      cv.drawCircle(ctr, S(r), edge);
      cv.drawCircle(ctr, S(r * 0.38), _fill(const Color(0xffc9c9c9)));
      cv.drawCircle(ctr, S(r * 0.38), edge);
    }
    rect(L.turntable, const Color(0xff555555));
    polygon(L.upper, k.orange);
    polygon(L.bracket, k.orange);
    polygon(L.cab, k.orange);
    polygon(L.window, k.window);
    cv.drawRect(_rect(L.centerMark), _fill(k.tipRed)); // 迴轉中心標記
    if (c.showBodyDims) _bodyDims(cv, L);
  }

  /// 車體尺寸標註（固定像素間距，縮放時不會擠在一起）。
  void _bodyDims(Canvas cv, BodyLayout L) {
    final b = m.body;
    const col = k.dimColor;
    final pen = _stroke(col, 1);
    const tick = 4.0;
    const bg = Color(0xd7ffffff);
    final groundY = c.oy;

    void hdim(double x0, double x1, double yPx, String text) {
      final a = xy(x0, 0).dx, e = xy(x1, 0).dx;
      final y = groundY + yPx;
      for (final x in [a, e]) {
        _dashLine(cv, Offset(x, groundY), Offset(x, y), pen, _dot); // 延伸線：地面 → 尺寸線
      }
      cv.drawLine(Offset(a, y), Offset(e, y), pen);
      for (final x in [a, e]) {
        cv.drawLine(Offset(x, y - tick), Offset(x, y + tick), pen);
      }
      drawLabel(cv, Offset((a + e) / 2, y), text, color: col, bg: bg, align: 'c');
    }

    final ch = L.chassis;
    hdim(ch.$1, ch.$1 + ch.$3, 22, '底盤總長 ${fixed(b.chassisLength, 2)} m');
    hdim(L.rearX, L.frontX, 46, '車總長 ${fixed(b.totalLength, 2)} m');

    // 車高：車尾外側的垂直尺寸線
    final x = xy(L.rearX, 0).dx - 26;
    final yTop = xy(0, b.height).dy;
    cv.drawLine(Offset(x, groundY), Offset(x, yTop), pen);
    for (final y in [groundY, yTop]) {
      cv.drawLine(Offset(x - tick, y), Offset(x + tick, y), pen);
    }
    final top = L.cab.reduce((p, q) => q.y > p.y ? q : p);
    _dashLine(cv, Offset(x, yTop), Offset(xy(top.x, 0).dx, yTop), pen, _dot);
    drawLabel(cv, Offset(x, (groundY + yTop) / 2), '車高 ${fixed(b.height, 2)} m',
        color: col, bg: bg, align: 'c', dx: -2);
    // 車寬：側視圖看不到，以文字顯示
    drawLabel(cv, Offset(xy(L.frontX, 0).dx, groundY + 46), '車寬 ${fixed(b.width, 2)} m',
        color: col, bg: bg, align: 'tl', dx: 10, dy: -9);
  }

  // ================================================================ 吊臂
  void _boom(Canvas cv, SafetyReport rep) {
    final spec = m.spec, pose = m.geometryPose, res = m.result; // 副臂依荷重表同步時畫下垂後的位置
    final lim = m.limits; // 已含車高造成的鉸點高度變化
    final edge = _stroke(k.outline, 1);
    final bw = spec.boomWidth;
    final o = spec.boomBodyOffset; // 臂身中心相對鉸點軸線（下方為負）
    final t = geo.radians(pose.angle);
    final ct = math.cos(t), st = math.sin(t);
    // 臂座標 (u 沿臂、v 垂直臂向上) → 螢幕
    Offset bp(double u, double v) => xy(lim.pivotX + u * ct - v * st, lim.pivotY + u * st + v * ct);
    Path brect(double u0, double v0, double u1, double v1) => _poly([bp(u0, v0), bp(u1, v0), bp(u1, v1), bp(u0, v1)]);

    // 起伏油壓缸：底座固定在上部機構，另一端接在基本節上
    final axisLen = lim.axisLength(pose.length); // 臂軸長度（顯示臂長 + 臂長修正）
    final baseLen = lim.axisLength(spec.limits.boomMin); // 最短臂長＝基本節長度（只用來畫圖）
    final attach = [3.2, baseLen * 0.45, axisLen * 0.45].reduce(math.min);
    final rodEnd = bp(attach, o);
    final cylBase = P(m.bodyLayout().cylinderBase);
    cv.drawLine(cylBase, rodEnd, _stroke(const Color(0xff4a4a4a), S(0.24), StrokeCap.round));
    cv.drawLine((cylBase + rodEnd) / 2, rodEnd, _stroke(const Color(0xffd8d8d8), S(0.10)));

    // 主臂各節：由最內節往外畫，外節蓋住內節重疊部分
    final secs = geo.telescopicSections(axisLen, baseLen, spec.telescopicSections);
    final n = secs.length;
    for (var i = n - 1; i >= 0; i--) {
      var (s0, e0) = secs[i];
      final w = bw * (1.0 - 0.11 * i);
      if (i == 0) s0 -= boomRoot; // 臂根
      final path = brect(s0, o - w / 2, e0, o + w / 2);
      cv.drawPath(path, _fill(i == 0 ? k.orange : k.sectionGrey));
      cv.drawPath(path, edge);
      if (i > 0) {
        // 節與節之間的套環
        final ring = brect(secs[i - 1].$2 - 0.18, o - w / 2 - 0.03, secs[i - 1].$2, o + w / 2 + 0.03);
        cv.drawPath(ring, _fill(const Color(0xff6f6f6f)));
        cv.drawPath(ring, edge);
      }
    }
    // 臂頭；有臂尖偏移時往臂軸下方延伸到臂尖滑輪（紅點位置）
    final wl = bw * (1.0 - 0.11 * (n - 1));
    final d = lim.tipOffset;
    if (d > 0) {
      final top = o + wl / 2 + 0.05;
      final head = brect(axisLen - 0.45, -d - 0.12, axisLen + 0.10, top);
      cv.drawPath(head, _fill(const Color(0xff5c5c5c)));
      cv.drawPath(head, edge);
      cv.drawCircle(bp(axisLen, -d), S(0.2), _fill(const Color(0xff8a8a8a))); // 臂尖滑輪
      cv.drawCircle(bp(axisLen, -d), S(0.2), edge);
    } else {
      final head = brect(axisLen - 0.35, o - wl / 2 - 0.05, axisLen, o + wl / 2 + 0.05);
      cv.drawPath(head, _fill(const Color(0xff5c5c5c)));
      cv.drawPath(head, edge);
    }
    // 單滑輪（主臂用副吊鉤）：臂尖滑輪外側的托架與滑輪，副吊鉤鋼索從滑輪外側垂下
    if (res.auxTip != null && spec.hasAuxSheave) {
      final a = bp(axisLen + lim.auxAlong, -d - lim.auxBelow);
      cv.drawLine(bp(axisLen, -d), a, _stroke(const Color(0xff5c5c5c), S(0.14), StrokeCap.round));
      final r = lim.auxRope > 0 ? lim.auxRope : 0.12;
      cv.drawCircle(a, S(r), _fill(const Color(0xff8a8a8a)));
      cv.drawCircle(a, S(r), edge);
    }
    // 拖曳臂身時：藍色外框
    if (c.draggingBoom) {
      cv.drawPath(brect(-boomRoot, o - bw / 2 - 0.08, axisLen, o + bw / 2 + 0.08), _stroke(k.selectBlue, 2));
    }
    // 鉸點銷
    cv.drawCircle(bp(0, 0), S(0.13), _fill(k.tipRed));
    cv.drawCircle(bp(0, 0), S(0.13), edge);

    // 助臂（格子桁架外觀）
    if (res.jibTip != null) {
      final jw = spec.jibWidth;
      final ja = geo.radians(pose.angle - pose.jibOffset);
      final jc = math.cos(ja), js = math.sin(ja);
      final base = res.mainTip;
      Offset jp(double u, double v) => xy(base.x + u * jc - v * js, base.y + u * js + v * jc);
      final body = _poly([jp(0, -jw / 2), jp(pose.jibLength, -jw / 2), jp(pose.jibLength, jw / 2), jp(0, jw / 2)]);
      cv.drawPath(body, _fill(const Color(0xffa7a7a7)));
      cv.drawPath(body, edge);
      final step = math.max(jw * 1.6, 0.35);
      final zig = <Offset>[jp(0, -jw / 2)];
      var x = 0.0;
      var up = true;
      while (x + step <= pose.jibLength) {
        x += step;
        zig.add(jp(x, up ? jw / 2 : -jw / 2));
        up = !up;
      }
      cv.drawPath(_poly(zig, close: false), _stroke(const Color(0xff555555), 1));
    }

    // 有設定尖端下彎量時，以紫色虛線畫出下彎後的吊臂中心線
    final pts = rep.deflectedBoom;
    if (pts.isNotEmpty) {
      const color = k.measure;
      _dashPoly(cv, [for (final p in pts) P(p)], _stroke(color, 1.6));
      final end = P(pts.last);
      cv.drawCircle(end, 3, _fill(color));
      drawLabel(cv, end, '下彎後（−${fixed(m.deflection, 2)} m）',
          color: color, bg: const Color(0xd2ffffff), align: 'tl', dx: 8, dy: 4);
    }
  }

  void _tipHandles(Canvas cv) {
    final r = m.result;
    void dot(Pt p, bool active) {
      final s = P(p);
      if (active) cv.drawCircle(s, 22, _fill(const Color(0x33e8141b)));
      cv.drawCircle(s, 9, _fill(k.tipRed));
      cv.drawCircle(s, 9, _stroke(const Color(0xff5a0000), 1.2));
    }

    dot(r.mainTip, c.draggingMainTip);
    if (r.jibTip != null) dot(r.jibTip!, c.draggingJibTip);
  }

  void _objectHandles(Canvas cv) {
    if (c.selection.length != 1) return;
    final o = m.get(c.selection.first);
    if (o == null || !o.visible || o.locked) return;
    for (final h in o.handles()) {
      final r = Rect.fromCenter(center: P(h), width: 12, height: 12);
      cv.drawRect(r, _fill(const Color(0xffffffff)));
      cv.drawRect(r, _stroke(k.selectBlue, 1.5));
    }
  }

  // ================================================================ 物件
  (Paint, Color) _penAndFill(SceneObject o, String status) {
    var fill = k.hex(o.fill);
    var pen = _stroke(k.hex(o.stroke), 1.2);
    if (status == 'collision') {
      fill = k.collideFill;
      pen = _stroke(k.collidePen, 3);
    } else if (status == 'warning') {
      pen = _stroke(k.warnPen, 3);
    }
    return (pen, fill);
  }

  void _object(Canvas cv, SceneObject o, SafetyReport rep) {
    final status = rep.status[o.id] ?? 'none';
    final label = rep.labels[o.id] ?? '';
    final selected = c.selection.contains(o.id);
    switch (o) {
      case RectObject():
      case PolygonObject():
        _area(cv, o, status);
      case GroundObject():
        _ground(cv, o, status);
      case WireObject():
        _wire(cv, o, status);
      case LoadObject():
        _load(cv, o, status, label, selected);
      case TextObject():
        _text(cv, o);
      case DimensionObject():
        _dimension(cv, o);
      case ImageObject():
        _image(cv, o);
      case TruckObject():
        _truck(cv, o, status);
    }
    if (selected) {
      final pen = _stroke(k.selectBlue, 1.5);
      if (o is TextObject) {
        final (x0, y0, x1, y1) = textRect(o);
        _dashPoly(cv, [xy(x0, y0), xy(x1, y0), xy(x1, y1), xy(x0, y1)], pen, close: true);
      } else if (o is! WireObject && o is! DimensionObject) {
        final pts = o is LoadObject ? m.loadOutline(o) : o.outline();
        _dashPoly(cv, [for (final p in pts) P(p)], pen, close: true);
      }
    }
    _statusLabel(cv, o, status, label);
  }

  /// 障礙物 / 電線 / 聯結車的名稱與淨空。
  void _statusLabel(Canvas cv, SceneObject o, String status, String ct) {
    if (o is TruckObject) {
      // 車頂常放吊物，標籤改放在車底下，才不會和吊物的文字重疊
      final color = switch (status) { 'collision' => k.collidePen, 'warning' => const Color(0xffa34700), _ => k.text };
      final text = [o.name, ct].where((t) => t.isNotEmpty).join(' ');
      final x0 = o.outline().map((p) => p.x).reduce(math.min);
      drawLabel(cv, xy(x0, o.y), text, color: color, bg: const Color(0xcdffffff), align: 'tl', dy: 3);
    } else if (o is RectObject || o is PolygonObject) {
      final pts = o.outline();
      final tl = xy(pts.map((p) => p.x).reduce(math.min), pts.map((p) => p.y).reduce(math.max));
      final color = switch (status) { 'collision' => k.collidePen, 'warning' => const Color(0xffa34700), _ => k.text };
      final text = [o.name, ct].where((t) => t.isNotEmpty).join(' ');
      drawLabel(cv, tl, text, color: color, bg: const Color(0xcdffffff), align: 'bl', dy: -2);
    } else if (o is WireObject) {
      final color = switch (status) { 'collision' => k.collidePen, 'warning' => k.warnPen, _ => k.hex(o.stroke) };
      var text = '${o.name}（安全距離 ${fixed(o.margin, 1)} m）';
      if (ct.isNotEmpty) text += ' $ct';
      drawLabel(cv, xy((o.x1 + o.x2) / 2, (o.y1 + o.y2) / 2), text,
          color: color, bg: const Color(0xd2ffffff), align: 'bc', dy: -6);
    }
  }

  void _area(Canvas cv, SceneObject o, String status) {
    final (pen, fill) = _penAndFill(o, status);
    final path = _poly([for (final p in o.outline()) P(p)]);
    cv.drawPath(path, _fill(_alpha(fill, o.opacity)));
    cv.drawPath(path, pen);
  }

  void _ground(Canvas cv, GroundObject o, String status) {
    final (pen, fill) = _penAndFill(o, status);
    final path = _poly([for (final p in o.outline()) P(p)]);
    cv.drawPath(path, _fill(_alpha(fill, o.opacity)));
    // 斜線
    cv.save();
    cv.clipPath(path);
    final b = path.getBounds();
    final hatch = _stroke(_alpha(k.hex(o.stroke), o.opacity), 1);
    for (var x = b.left - b.height; x < b.right; x += 8) {
      cv.drawLine(Offset(x, b.bottom), Offset(x + b.height, b.top), hatch);
    }
    cv.restore();
    final a = math.min(o.x1, o.x2), e = math.max(o.x1, o.x2);
    cv.drawLine(xy(a, o.elevation), xy(e, o.elevation), pen);
    cv.drawLine(xy(a, 0), xy(a, o.elevation), pen);
    cv.drawLine(xy(e, 0), xy(e, o.elevation), pen);
    drawLabel(cv, xy((a + e) / 2, math.max(0.0, o.elevation)), '${o.name} ${signedFixed(o.elevation, 2)} m',
        color: const Color(0xff5a3a1a), bg: const Color(0xbeffffff), align: 'bc', dy: -3);
  }

  void _wire(Canvas cv, WireObject o, String status) {
    final a = xy(o.x1, o.y1), b = xy(o.x2, o.y2);
    var band = k.hex(o.fill);
    if (status == 'collision') band = k.collideFill;
    band = band.withValues(alpha: 70 / 255 * o.opacity);
    if (o.margin > 0) {
      // 安全距離帶（公尺寬，兩端圓頭）
      cv.drawLine(a, b, _stroke(band, S(2 * o.margin), StrokeCap.round));
    }
    final color = switch (status) { 'collision' => k.collidePen, 'warning' => k.warnPen, _ => k.hex(o.stroke) };
    cv.drawLine(a, b, _stroke(color, 2.5));
    for (final q in [a, b]) {
      cv.drawCircle(q, 3, _fill(color));
    }
  }

  void _load(Canvas cv, LoadObject o, String status, String label, bool selected) {
    final tip = m.riggingTip();
    final hook = o.hookAt(tip);
    final (left, right) = o.attachPoints(tip);
    final pts = m.loadOutline(o);
    final hk = m.hookSetup; // 目前使用的吊鉤（主吊鉤／副吊鉤）
    final bh = hk.blockHeight;
    final block = o.blockRect(tip, bh);
    final warnColor = switch (status) { 'collision' => k.collidePen, 'warning' => k.warnPen, _ => null };
    final over = hk.overhoistState(o.hoist); // 'over' 超過過捲極限、'near' 接近過捲
    final overColor = switch (over) { 'over' => k.collidePen, 'near' => k.warnPen, _ => null };

    // 1. 吊掛：臂端 → 吊鉤組頂部（鋼索）；接近／超過過捲時用警示色
    cv.drawLine(P(tip), xy(hook.x, block[2].y),
        overColor == null ? _stroke(k.hoistColor, 1.5) : _stroke(overColor, 2.5));
    // 2. 吊索：掛鉤 → 吊物頂部左右吊點
    final slingColor = status == 'collision' ? k.collidePen : k.slingColor;
    final sp = _stroke(slingColor, 2.2);
    cv.drawLine(P(hook), P(left), sp);
    cv.drawLine(P(hook), P(right), sp);
    // 3. 吊物本體
    final (pen, fill) = _penAndFill(o, status);
    final body = _poly([for (final p in pts) P(p)]);
    cv.drawPath(body, _fill(_alpha(fill, o.opacity)));
    cv.drawPath(body, warnColor != null ? pen : _stroke(k.hex(o.stroke), 1.2));
    for (final q in [left, right]) {
      cv.drawCircle(P(q), 2.5, _fill(slingColor)); // 吊點
    }
    // 4. 吊鉤組（依目前吊鉤的規格尺寸；太小時改畫固定像素圖示）
    _hookBlock(cv, hook, bh, overColor);
    // 5. 吊鉤頂的過捲極限（紅線）與提早警告位置（橘線）：選取或接近過捲時標出
    if (selected || over.isNotEmpty) {
      final half = math.max(S(LoadObject.blockSize(bh).$1 * 0.75), 9.0);
      for (final (gap, color) in [(hk.overhoist + hk.warning, k.warnPen), (hk.overhoist, k.collidePen)]) {
        final y = xy(0, tip.y - gap).dy;
        final x = P(tip).dx;
        cv.drawLine(Offset(x - half, y), Offset(x + half, y), _stroke(color, 2));
      }
    }
    final cx = (pts[0].x + pts[1].x) / 2, cy = (pts[0].y + pts[2].y) / 2;
    drawLabel(cv, xy(cx, cy), '${o.name} ${fixed(o.weight, 1)} t', color: const Color(0xff3a2600), align: 'c');
    drawLabel(cv, xy(pts[1].x, pts[0].y), label,
        color: warnColor ?? textMutedLoad,
        bg: const Color(0xc8ffffff),
        align: 'bl',
        dx: 4,
        bold: warnColor != null);
    // 選取時標出吊掛、吊索長度
    if (selected) {
      const bg = Color(0xd2ffffff);
      drawLabel(cv, xy(tip.x, (tip.y + block[2].y) / 2),
          '吊掛 ${fixed(o.hoist, 2)} m｜鉤頂距滑輪 ${fixed(hk.topGap(o.hoist), 2)} m',
          color: k.hoistColor, bg: bg, align: 'tl', dx: 10, dy: -8);
      drawLabel(cv, xy((hook.x + right.x) / 2, (hook.y + right.y) / 2), '吊索 ${fixed(o.sling, 2)} m',
          color: k.slingColor, bg: bg, align: 'c', dx: 44);
    }
  }

  static const textMutedLoad = Color(0xff56616d);

  /// 吊鉤組：上方滑車 + 下方 J 形鉤，鉤底＝掛鉤點（吊索交會處）。
  void _hookBlock(Canvas cv, Pt hook, double bh, Color? alert) {
    final (w, h) = LoadObject.blockSize(bh);
    if (S(h) < 14) {
      _hookIcon(cv, P(hook)); // 縮得太小時，用固定像素的圖示
      return;
    }
    final hx = hook.x, hy = hook.y;
    final edge = alert ?? const Color(0xff212529);
    // 滑車（吊鉤座）：吊鉤組上 65%
    final body = Rect.fromPoints(xy(hx - w / 2, hy + 0.35 * h), xy(hx + w / 2, hy + h));
    final r = Radius.circular(S(math.min(w, h) * 0.12));
    cv.drawRRect(RRect.fromRectAndRadius(body, r), _fill(const Color(0xff495057)));
    cv.drawRRect(RRect.fromRectAndRadius(body, r), _stroke(edge, alert == null ? 1.5 : 2.5));
    final pulley = xy(hx, hy + 0.72 * h);
    cv.drawCircle(pulley, S(w * 0.22), _fill(const Color(0xffadb5bd)));
    cv.drawCircle(pulley, S(w * 0.22), _stroke(edge, alert == null ? 1.5 : 2.5));
    // 鉤身與 J 形鉤：下 35%
    final rr = 0.12 * h;
    final path = Path();
    final p0 = xy(hx, hy + 0.35 * h);
    path.moveTo(p0.dx, p0.dy); // 鉤身從滑車底部往下
    final p1 = xy(hx + rr, hy + 0.28 * h);
    path.lineTo(p1.dx, p1.dy);
    final p2 = xy(hx + rr, hy + rr);
    path.lineTo(p2.dx, p2.dy);
    for (var a = 0.0; a >= -250.0; a -= 10.0) {
      // 由右側往下繞過鉤底（掛鉤點）再往上
      final q = xy(hx + rr * math.cos(geo.radians(a)), hy + rr + rr * math.sin(geo.radians(a)));
      path.lineTo(q.dx, q.dy);
    }
    cv.drawPath(path, _stroke(const Color(0xff212529), math.max(S(0.05 * h), 2), StrokeCap.round));
  }

  /// 縮小時的掛鉤圖示（像素大小，不隨縮放改變）。
  void _hookIcon(Canvas cv, Offset at) {
    final x = at.dx, y = at.dy;
    final block = RRect.fromRectAndRadius(Rect.fromLTWH(x - 6, y - 17, 12, 9), const Radius.circular(2));
    cv.drawRRect(block, _fill(const Color(0xff495057)));
    cv.drawRRect(block, _stroke(const Color(0xff212529), 1));
    final path = Path()
      ..moveTo(x, y - 8)
      ..lineTo(x, y - 3);
    for (var a = 90.0; a <= 360.0; a += 15.0) {
      final t = geo.radians(a);
      path.lineTo(x + 4 * math.cos(t), y - 1 - 4 * math.sin(t));
    }
    cv.drawPath(path, _stroke(const Color(0xff212529), 2.2, StrokeCap.round));
  }

  void _text(Canvas cv, TextObject o) {
    final fontSize = S(o.size);
    if (fontSize < 1) return;
    final tp = TextPainter(
      text: TextSpan(text: o.text, style: textObjectStyle(fontSize, _alpha(k.hex(o.stroke), o.opacity))),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(cv, xy(o.x, o.y));
  }

  void _dimension(Canvas cv, DimensionObject o) {
    final color = k.hex(o.stroke);
    final a = xy(o.x1, o.y1), b = xy(o.x2, o.y2);
    final dash = _stroke(color, 1);
    final solid = _stroke(color, 1.5);
    (Offset, Offset) line;
    if (o.mode == 'horizontal') {
      final c2 = xy(o.x2, o.y1);
      _dashLine(cv, c2, b, dash);
      line = (a, c2);
    } else if (o.mode == 'vertical') {
      final c2 = xy(o.x1, o.y2);
      _dashLine(cv, c2, b, dash);
      line = (a, c2);
    } else {
      line = (a, b);
    }
    cv.drawLine(line.$1, line.$2, solid);
    for (final q in [line.$1, line.$2]) {
      cv.drawCircle(q, 3, _fill(color));
    }
    var text = '${fixed(o.value(), 2)} m';
    if (o.mode != 'aligned') text = '${dimModes[o.mode]!.substring(0, 2)} $text';
    drawLabel(cv, (line.$1 + line.$2) / 2, text,
        color: color, bg: const Color(0xdcffffff), align: 'bc', dy: -4, bold: true);
  }

  void _image(Canvas cv, ImageObject o) {
    final r = Rect.fromPoints(xy(o.x, o.y + o.height), xy(o.x + o.width, o.y));
    final img = images.get(o.path);
    if (img == null) {
      _dashPoly(cv, [r.topLeft, r.topRight, r.bottomRight, r.bottomLeft], _stroke(const Color(0xff868e96), 1),
          close: true);
      cv.drawRect(r, _fill(const Color(0x0c000000)));
      final msg = images.failed(o.path) ? (o.path.isEmpty ? '未指定圖檔' : '無法讀取圖檔') : '讀取中…';
      drawLabel(cv, r.center, msg, color: const Color(0xff868e96), align: 'c');
      return;
    }
    final paint = Paint()
      ..filterQuality = FilterQuality.medium
      ..color = Color.fromRGBO(0, 0, 0, o.opacity.clamp(0.0, 1.0));
    cv.drawImageRect(img, Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()), r, paint);
  }

  // ---------------------------------------------------------------- 聯結車
  Rect _boxRect(TruckBox b) => Rect.fromPoints(xy(b.x0, b.y1), xy(b.x1, b.y0));

  void _truck(Canvas cv, TruckObject o, String status) {
    final collide = status == 'collision';
    final edgeColor = _alpha(k.hex(o.stroke), o.opacity);
    final edge = _stroke(edgeColor, 1.0);
    Color op(Color c) => _alpha(c, o.opacity);
    final steel = op(const Color(0xff343a40));
    final cabFill = op(collide ? k.collideFill : k.hex(o.fill));
    final boxFill = collide ? k.collideFill : k.hex(o.containerFill);
    final parts = <String, List<TruckBox>>{};
    for (final b in o.boxes()) {
      parts.putIfAbsent(b.part, () => []).add(b);
    }
    void rect(Rect r, Color fill) {
      cv.drawRect(r, _fill(fill));
      cv.drawRect(r, edge);
    }

    if (o.view == 'side') {
      for (final b in parts['frame'] ?? const <TruckBox>[]) {
        rect(_boxRect(b), op(const Color(0xff495057)));
      }
      for (final b in parts['deck'] ?? const <TruckBox>[]) {
        rect(_boxRect(b), steel);
      }
      final leg = o.landingLeg();
      if (leg != null) {
        final (lx, ytop, ybot) = leg;
        cv.drawRect(Rect.fromPoints(xy(lx - 0.07, ytop), xy(lx + 0.07, ybot)), _fill(steel));
        cv.drawRect(Rect.fromPoints(xy(lx - 0.2, ybot + 0.02), xy(lx + 0.2, ybot - 0.06)), _fill(steel));
      }
      for (final b in parts['container'] ?? const <TruckBox>[]) {
        _containerSide(cv, b, boxFill, edge, o.opacity);
      }
      for (final b in parts['cab'] ?? const <TruckBox>[]) {
        _cabSide(cv, o, b, cabFill, edge);
      }
      for (final (cx, cy, r) in o.wheels()) {
        final ctr = xy(cx, cy);
        cv.drawCircle(ctr, S(r), _fill(op(const Color(0xff212529))));
        cv.drawCircle(ctr, S(r), edge);
        cv.drawCircle(ctr, S(r * 0.45), _fill(op(const Color(0xffadb5bd))));
        cv.drawCircle(ctr, S(r * 0.45), edge);
      }
    } else {
      // 車尾方向：車頭在後方，只畫出露出來的部分
      final front = Path();
      for (final b in [...?parts['container'], ...?parts['deck']]) {
        front.addRect(_boxRect(b));
      }
      for (final b in parts['cab'] ?? const <TruckBox>[]) {
        final cab = Path()..addRRect(RRect.fromRectAndRadius(_boxRect(b), Radius.circular(S(0.15))));
        final vis = Path.combine(PathOperation.difference, cab, front);
        cv.drawPath(vis, _fill(cabFill));
        cv.drawPath(vis, edge);
      }
      for (final b in parts['deck'] ?? const <TruckBox>[]) {
        rect(_boxRect(b), steel);
        for (final x in [b.x0 + 0.1, b.x1 - 0.35]) {
          cv.drawRect(Rect.fromPoints(xy(x, b.y0 + 0.2), xy(x + 0.25, b.y0 + 0.06)),
              _fill(op(const Color(0xffe03131)))); // 尾燈
        }
        rect(Rect.fromPoints(xy(b.x0 + 0.3, o.y + 0.54), xy(b.x1 - 0.3, o.y + 0.38)),
            op(const Color(0xff868e96))); // 防撞桿
      }
      for (final b in parts['tire'] ?? const <TruckBox>[]) {
        final r = RRect.fromRectAndRadius(_boxRect(b), Radius.circular(S(0.08)));
        cv.drawRRect(r, _fill(op(const Color(0xff212529))));
        cv.drawRRect(r, edge);
        final mid = (b.x0 + b.x1) / 2;
        cv.drawLine(xy(mid, b.y0 + 0.05), xy(mid, b.y1 - 0.05), _stroke(op(const Color(0xff495057)), 1));
      }
      for (final b in parts['container'] ?? const <TruckBox>[]) {
        _containerRear(cv, b, boxFill, edge, o.opacity);
      }
    }

    if (status == 'collision' || status == 'warning') {
      cv.drawPath(_poly([for (final p in o.outline()) P(p)]), _stroke(collide ? k.collidePen : k.warnPen, 3));
    }
    for (final b in parts['container'] ?? const <TruckBox>[]) {
      final text = o.container.replaceAll('ft', ' 呎') + (o.containerType == 'high' ? '高櫃' : '');
      if (S(b.x1 - b.x0) > 12 * text.length + 8) {
        // 貨櫃畫得太小時不寫字
        drawLabel(cv, _boxRect(b).center, text, color: const Color(0xffffffff), align: 'c', bold: true);
      }
    }
  }

  void _containerSide(Canvas cv, TruckBox b, Color fill, Paint edge, double opacity) {
    final r = _boxRect(b);
    cv.drawRect(r, _fill(_alpha(fill, opacity)));
    cv.drawRect(r, edge);
    final rib = _stroke(_alpha(k.darker(fill, 125), opacity), 1);
    final widthM = b.x1 - b.x0;
    final n = math.max(2, widthM ~/ 0.6);
    final step = widthM / n;
    for (var i = 1; i < n; i++) {
      final x = b.x0 + i * step;
      cv.drawLine(xy(x, b.y1 - 0.12), xy(x, b.y0 + 0.12), rib);
    }
    final beam = _stroke(_alpha(k.darker(fill, 160), opacity), 1.5); // 上下邊框樑
    cv.drawLine(xy(b.x0, b.y1 - 0.1), xy(b.x1, b.y1 - 0.1), beam);
    cv.drawLine(xy(b.x0, b.y0 + 0.1), xy(b.x1, b.y0 + 0.1), beam);
  }

  void _containerRear(Canvas cv, TruckBox b, Color fill, Paint edge, double opacity) {
    final r = _boxRect(b);
    cv.drawRect(r, _fill(_alpha(fill, opacity)));
    cv.drawRect(r, edge);
    final cx = (b.x0 + b.x1) / 2;
    cv.drawLine(xy(cx, b.y1 - 0.1), xy(cx, b.y0 + 0.1), _stroke(_alpha(k.darker(fill, 170), opacity), 1.5)); // 門縫
    final bolt = _stroke(_alpha(const Color(0xffdee2e6), opacity), 1.2);
    for (final f in const [0.2, 0.38, 0.62, 0.8]) {
      final x = b.x0 + (b.x1 - b.x0) * f; // 門栓
      cv.drawLine(xy(x, b.y1 - 0.25), xy(x, b.y0 + 0.25), bolt);
    }
  }

  /// 駕駛室側面：前端擋風玻璃斜面、車門窗、前保險桿。
  void _cabSide(Canvas cv, TruckObject o, TruckBox b, Color fill, Paint edge) {
    final d = o.facing == 'left' ? 1.0 : -1.0; // 由車頭往車尾的方向
    final f = o.facing == 'left' ? b.x0 : b.x1; // 車頭前端
    final back = o.facing == 'left' ? b.x1 : b.x0;
    final y0 = b.y0, y1 = b.y1;
    final h = y1 - y0;
    final slope = math.min(0.35, h * 0.2);
    final body = _poly([xy(f, y0), xy(f, y1 - slope * 1.3), xy(f + d * slope, y1), xy(back, y1), xy(back, y0)]);
    cv.drawPath(body, _fill(fill));
    cv.drawPath(body, edge);
    final cl = (back - f).abs();
    final wb = y1 - math.min(1.15, h * 0.45), wt = y1 - math.min(0.2, h * 0.08);
    final win = _poly([
      xy(f + d * 0.12, wb),
      xy(f + d * 0.12, y1 - slope * 1.3 - 0.05),
      xy(f + d * (slope + 0.05), wt),
      xy(f + d * cl * 0.6, wt),
      xy(f + d * cl * 0.6, wb),
    ]);
    cv.drawPath(win, _fill(_alpha(const Color(0xffd0e4f5), o.opacity)));
    cv.drawPath(win, edge);
    final a = math.min(f - d * 0.05, f + d * 0.4), e = math.max(f - d * 0.05, f + d * 0.4);
    final bumper = Rect.fromPoints(xy(a, o.y + 0.7), xy(e, o.y + 0.35)); // 前保險桿
    cv.drawRect(bumper, _fill(_alpha(const Color(0xff495057), o.opacity)));
    cv.drawRect(bumper, edge);
  }

  // ================================================================ 前景
  void _foreground(Canvas cv, Size size) {
    final r = m.result;
    final tip = P(r.workingTip);
    if (c.showCrosshair) {
      final thin = _stroke(k.cross, 1);
      cv.drawLine(Offset(0, tip.dy), Offset(size.width, tip.dy), thin);
      cv.drawLine(Offset(tip.dx, 0), Offset(tip.dx, size.height), thin);
      final bar = _stroke(k.cross.withValues(alpha: 170 / 255), 6);
      final o = xy(0, 0);
      cv.drawLine(o, Offset(tip.dx, o.dy), bar);
      cv.drawLine(o, Offset(o.dx, tip.dy), bar);
    }
    _toolOverlay(cv);
    _axisLabels(cv, size);
  }

  void _toolOverlay(Canvas cv) {
    final pts = c.previewPts;
    final kind = c.createKind;
    const fillBlue = Color(0x281c7ed6);
    const white = Color(0xdcffffff);
    if (c.mode == 'create' && pts.isNotEmpty) {
      final pen = _stroke(k.preview, 1.5);
      final a = pts.first, b = pts.last;
      if (kind == 'rect') {
        final r = Rect.fromPoints(P(a), P(b));
        cv.drawRect(r, _fill(fillBlue));
        _dashPoly(cv, [r.topLeft, r.topRight, r.bottomRight, r.bottomLeft], pen, close: true);
        drawLabel(cv, P(b), '${fixed((b.x - a.x).abs(), 2)} × ${fixed((b.y - a.y).abs(), 2)} m',
            color: k.preview, bg: white, align: 'bl', dx: 8, dy: -4);
      } else if (kind == 'ground') {
        final r = Rect.fromPoints(xy(a.x, 0), xy(b.x, b.y));
        cv.drawRect(r, _fill(fillBlue));
        _dashPoly(cv, [r.topLeft, r.topRight, r.bottomRight, r.bottomLeft], pen, close: true);
        drawLabel(cv, P(b), '高程 ${signedFixed(b.y, 2)} m', color: k.preview, bg: white, align: 'bl', dx: 8, dy: -4);
      } else if (kind == 'wire' || kind == 'dimension') {
        _dashLine(cv, P(a), P(b), pen);
        drawLabel(cv, P(b), '${fixed(dist(a, b), 2)} m', color: k.preview, bg: white, align: 'bl', dx: 8, dy: -4);
      } else if (kind == 'polygon') {
        final sp = [for (final p in pts) P(p)];
        if (sp.length >= 3) cv.drawPath(_poly(sp), _fill(fillBlue));
        _dashPoly(cv, sp, pen, close: sp.length >= 3);
        for (final q in sp) {
          cv.drawCircle(q, 4, _fill(k.preview));
        }
        drawLabel(cv, sp.last, '${pts.length} 點', color: k.preview, bg: white, align: 'bl', dx: 8, dy: -4);
      }
    }
    if (c.mode == 'measure') {
      final seg = pts.length == 2 ? (pts[0], pts[1]) : (c.measurement == null ? null : (c.measurement!.a, c.measurement!.b));
      if (seg != null) {
        final a = P(seg.$1), b = P(seg.$2);
        final corner = xy(seg.$2.x, seg.$1.y);
        final dotPen = _stroke(k.measure, 1);
        _dashLine(cv, a, corner, dotPen, _dot);
        _dashLine(cv, corner, b, dotPen, _dot);
        cv.drawLine(a, b, _stroke(k.measure, 2));
        for (final q in [a, b]) {
          cv.drawCircle(q, 3.5, _fill(k.measure));
        }
        final mm = Measurement(seg.$1, seg.$2);
        drawLabel(cv, (a + b) / 2,
            'L ${fixed(mm.distance, 2)} m  ∠ ${fixed(mm.angle, 1)}°  ΔX ${fixed(mm.dx, 2)}  ΔY ${fixed(mm.dy, 2)}',
            color: const Color(0xffffffff), bg: k.measure, align: 'bc', dy: -6, bold: true);
      }
    }
    if (c.mode == 'calibrate') {
      for (final q in pts) {
        cv.drawCircle(P(q), 5, _stroke(const Color(0xffe8590c), 2));
      }
    }
    // 聯結車：游標處預覽車輛外形
    final cur = c.cursor;
    if (c.mode == 'create' && kind == 'truck' && cur != null) {
      final ghost = c.truckAt(c.snapPoint(cur, keys: false));
      final path = _poly([for (final p in ghost.outline()) P(p)]);
      cv.drawPath(path, _fill(fillBlue));
      _dashPoly(cv, [for (final p in ghost.outline()) P(p)], _stroke(k.preview, 1.5), close: true);
      drawLabel(cv, xy(ghost.x, ghost.y + ghost.topHeight), '${ghost.label}（全長 ${fixed(ghost.totalLength, 1)} m）',
          color: k.preview, bg: white, align: 'bl', dy: -4);
    }
    // 吸附游標
    if (c.mode != 'select' && cur != null) {
      final q = c.snappedCursor();
      if (q != null) {
        final s = P(q);
        final pen = _stroke(k.preview, 1);
        cv.drawLine(s - const Offset(8, 0), s + const Offset(8, 0), pen);
        cv.drawLine(s - const Offset(0, 8), s + const Offset(0, 8), pen);
        if (c.gestureActive) {
          drawLabel(cv, s, 'X ${fixed(q.x, 2)}  Y ${fixed(q.y, 2)}',
              color: k.preview, bg: white, align: 'bl', dx: 10, dy: -28);
        }
      }
    }
  }

  void _axisLabels(Canvas cv, Size size) {
    final w = size.width, h = size.height;
    cv.drawRect(Rect.fromLTWH(0, 0, leftStrip, h), _fill(k.labelBg));
    cv.drawRect(Rect.fromLTWH(0, h - bottomStrip, w, bottomStrip), _fill(k.labelBg));
    final line = _stroke(k.gridMajor, 1);
    cv.drawLine(const Offset(leftStrip, 0), Offset(leftStrip, h - bottomStrip), line);
    cv.drawLine(Offset(leftStrip, h - bottomStrip), Offset(w, h - bottomStrip), line);

    final (l, b, r, t) = c.visible();
    final s = c.scale;
    final step = niceStep(s, 20);
    final dec = step < 1 ? 1 : 0;
    for (var i = (b / step).ceil(); i <= (t / step).floor(); i++) {
      final y = i * step + 0.0;
      final vy = c.oy - y * s;
      if (vy < h - bottomStrip - 4) {
        final tp = _labelPainter(fixed(y, dec), k.labelFg, 10, false);
        tp.paint(cv, Offset(leftStrip - 5 - tp.width, vy - tp.height / 2));
      }
    }
    final stepX = niceStep(s, 30);
    final decX = stepX < 1 ? 1 : 0;
    for (var i = (l / stepX).ceil(); i <= (r / stepX).floor(); i++) {
      final x = i * stepX + 0.0;
      final vx = c.ox + x * s;
      if (vx > leftStrip + 8) {
        final tp = _labelPainter(fixed(x, decX), k.labelFg, 10, false);
        tp.paint(cv, Offset(vx - tp.width / 2, h - bottomStrip + (bottomStrip - tp.height) / 2));
      }
    }
    final tp = _labelPainter('m', const Color(0xff7a8590), 10, false);
    tp.paint(cv, Offset((leftStrip - tp.width) / 2, h - bottomStrip + (bottomStrip - tp.height) / 2));
  }
}
