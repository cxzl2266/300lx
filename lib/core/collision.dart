/// 吊臂與障礙物的淨空計算（移植自 Python 版 core/collision.py）。
library;

import 'dart:math' as math;

import 'geometry.dart';

/// 軸對齊矩形：left / bottom 為左下角。
class Rect {
  final double left, bottom, width, height;
  const Rect(this.left, this.bottom, this.width, this.height);

  double get right => left + width;
  double get top => bottom + height;

  List<Pt> corners() => [pt(left, bottom), pt(right, bottom), pt(right, top), pt(left, top)];

  bool contains(Pt p) => left <= p.x && p.x <= right && bottom <= p.y && p.y <= top;
}

double pointSegmentDistance(Pt p, Pt a, Pt b) {
  final dx = b.x - a.x, dy = b.y - a.y;
  final segLen2 = dx * dx + dy * dy;
  if (segLen2 == 0) return hypot(p.x - a.x, p.y - a.y);
  var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / segLen2;
  t = math.max(0.0, math.min(1.0, t));
  return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy));
}

double pointRectDistance(Pt p, Rect r) {
  final dx = math.max(math.max(r.left - p.x, 0.0), p.x - r.right);
  final dy = math.max(math.max(r.bottom - p.y, 0.0), p.y - r.top);
  return hypot(dx, dy);
}

double _cross(Pt o, Pt a, Pt b) => (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x);

bool _onSegment(Pt p, Pt a, Pt b) =>
    math.min(a.x, b.x) <= p.x &&
    p.x <= math.max(a.x, b.x) &&
    math.min(a.y, b.y) <= p.y &&
    p.y <= math.max(a.y, b.y);

bool segmentsIntersect(Pt p1, Pt p2, Pt q1, Pt q2) {
  final d1 = _cross(q1, q2, p1);
  final d2 = _cross(q1, q2, p2);
  final d3 = _cross(p1, p2, q1);
  final d4 = _cross(p1, p2, q2);
  if (((d1 > 0 && 0 > d2) || (d1 < 0 && 0 < d2)) && ((d3 > 0 && 0 > d4) || (d3 < 0 && 0 < d4))) return true;
  if (d1 == 0 && _onSegment(p1, q1, q2)) return true;
  if (d2 == 0 && _onSegment(p2, q1, q2)) return true;
  if (d3 == 0 && _onSegment(q1, p1, p2)) return true;
  if (d4 == 0 && _onSegment(q2, p1, p2)) return true;
  return false;
}

/// 線段到矩形的最短距離；相交或在內部時為 0。
double segmentRectDistance(Pt a, Pt b, Rect r) {
  if (r.contains(a) || r.contains(b)) return 0.0;
  final cs = r.corners();
  for (var i = 0; i < 4; i++) {
    if (segmentsIntersect(a, b, cs[i], cs[(i + 1) % 4])) return 0.0;
  }
  var best = math.min(pointRectDistance(a, r), pointRectDistance(b, r));
  for (final c in cs) {
    best = math.min(best, pointSegmentDistance(c, a, b));
  }
  return best;
}

/// 折線到矩形的淨空，已扣除吊臂半寬。
double polylineClearance(List<Pt> points, Rect r, [double halfWidth = 0.0]) {
  if (points.length < 2) return double.infinity;
  var d = double.infinity;
  for (var i = 0; i < points.length - 1; i++) {
    d = math.min(d, segmentRectDistance(points[i], points[i + 1], r));
  }
  return d - halfWidth;
}

// ---------------------------------------------------------------- 通用形狀：(頂點, 是否封閉)

/// 兩線段最短距離；相交時為 0。
double segmentDistance(Pt a, Pt b, Pt c, Pt d) {
  if (segmentsIntersect(a, b, c, d)) return 0.0;
  return [
    pointSegmentDistance(a, c, d),
    pointSegmentDistance(b, c, d),
    pointSegmentDistance(c, a, b),
    pointSegmentDistance(d, a, b),
  ].reduce(math.min);
}

/// 射線法；落在邊上也視為在內。
bool pointInPolygon(Pt p, List<Pt> poly) {
  final n = poly.length;
  if (n < 3) return false;
  for (var i = 0; i < n; i++) {
    if (pointSegmentDistance(p, poly[i], poly[(i + 1) % n]) < 1e-12) return true;
  }
  var inside = false;
  var j = n - 1;
  for (var i = 0; i < n; i++) {
    final pi = poly[i], pj = poly[j];
    if ((pi.y > p.y) != (pj.y > p.y)) {
      final xCross = pi.x + (p.y - pi.y) * (pj.x - pi.x) / (pj.y - pi.y);
      if (p.x < xCross) inside = !inside;
    }
    j = i;
  }
  return inside;
}

List<(Pt, Pt)> _edges(List<Pt> pts, bool closed) {
  if (pts.length == 1) return [(pts[0], pts[0])];
  final edges = [for (var i = 0; i < pts.length - 1; i++) (pts[i], pts[i + 1])];
  if (closed && pts.length >= 3) edges.add((pts.last, pts.first));
  return edges;
}

/// 外框 (minX, minY, maxX, maxY)。
typedef BBox = (double, double, double, double);

BBox bbox(List<Pt> pts) {
  var x0 = double.infinity, y0 = double.infinity, x1 = -double.infinity, y1 = -double.infinity;
  for (final p in pts) {
    x0 = math.min(x0, p.x);
    y0 = math.min(y0, p.y);
    x1 = math.max(x1, p.x);
    y1 = math.max(y1, p.y);
  }
  return (x0, y0, x1, y1);
}

/// 兩個外框的最短距離（重疊時為 0）；是真實距離的下限。
double bboxDistance(BBox a, BBox b) {
  final dx = math.max(math.max(b.$1 - a.$3, a.$1 - b.$3), 0.0);
  final dy = math.max(math.max(b.$2 - a.$4, a.$2 - b.$4), 0.0);
  return hypot(dx, dy);
}

/// 任意兩個形狀的最短距離；重疊（含包含關係）時為 0。
/// limit：只關心比 limit 更近的結果，實際距離 ≥ limit 時回傳某個 ≥ limit 的值。
double shapeDistance(List<Pt> a, bool aClosed, List<Pt> b, bool bClosed, [double limit = double.infinity]) {
  if (a.isEmpty || b.isEmpty) return double.infinity;
  return preparedDistance(Prepared(a, aClosed), Prepared(b, bClosed), limit);
}

/// 預先整理好的形狀（外框、各邊與各邊外框）。
class Prepared {
  final List<Pt> pts;
  final bool closed;
  final BBox box;
  final List<(Pt, Pt, BBox)> edges;

  Prepared(this.pts, this.closed)
      : box = bbox(pts),
        edges = [for (final (p, q) in _edges(pts, closed)) (p, q, bbox([p, q]))];
}

double preparedDistance(Prepared a, Prepared b, [double limit = double.infinity]) {
  final lower = bboxDistance(a.box, b.box);
  if (lower >= limit) return lower;
  if (lower == 0.0) {
    if (b.closed && a.pts.any((p) => pointInPolygon(p, b.pts))) return 0.0;
    if (a.closed && b.pts.any((p) => pointInPolygon(p, a.pts))) return 0.0;
  }
  var best = limit;
  final bb = b.box;
  for (final (p, q, bpq) in a.edges) {
    if (bboxDistance(bpq, bb) >= best) continue;
    for (final (r, s, brs) in b.edges) {
      if (bboxDistance(bpq, brs) >= best) continue;
      final d = segmentDistance(p, q, r, s);
      if (d < best) {
        best = d;
        if (best == 0.0) return 0.0;
      }
    }
  }
  return best;
}
