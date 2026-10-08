/// 文字物件的大小（公尺）：以 100 px 字型量測再等比例縮放（同桌面版）。
library;

import 'package:flutter/painting.dart';

import '../../models/objects.dart';
import '../colors.dart' as c;

const double textFontPx = 100.0;

final Map<String, Size> _cache = {};

TextStyle textObjectStyle(double fontSize, Color color) =>
    TextStyle(fontFamily: c.appFont, fontSize: fontSize, color: color, height: 1.25);

/// 文字以 100 px 字型排版時的大小（px）。
Size textSize100(String text) {
  final key = text.isEmpty ? ' ' : text;
  return _cache.putIfAbsent(key, () {
    final tp = TextPainter(
      text: TextSpan(text: key, style: textObjectStyle(textFontPx, const Color(0xff000000))),
      textDirection: TextDirection.ltr,
    )..layout();
    if (_cache.length > 500) _cache.clear();
    return tp.size;
  });
}

/// 文字物件外框（公尺）：(x0, y0, x1, y1)，左上角在 (o.x, o.y)，往下延伸。
(double, double, double, double) textRect(TextObject o) {
  final s = textSize100(o.text);
  final k = o.size / textFontPx;
  return (o.x, o.y - s.height * k, o.x + s.width * k, o.y);
}
