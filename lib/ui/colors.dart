/// 顏色（和桌面版相同）。
library;

import 'package:flutter/painting.dart';

const appFont = 'NotoSansTC';

/// "#rrggbb" / "#aarrggbb" → Color；格式不對時用灰色。
Color hex(String s) {
  var h = s.trim();
  if (h.startsWith('#')) h = h.substring(1);
  if (h.length == 6) h = 'ff$h';
  final v = int.tryParse(h, radix: 16);
  return v == null ? const Color(0xff868e96) : Color(v);
}

String toHex(Color c) {
  String two(double v) => (v * 255).round().clamp(0, 255).toRadixString(16).padLeft(2, '0');
  return '#${two(c.r)}${two(c.g)}${two(c.b)}';
}

/// Qt QColor.darker(f)：亮度除以 f/100。
Color darker(Color c, int factor) {
  final h = HSVColor.fromColor(c);
  return h.withValue((h.value * 100 / factor).clamp(0.0, 1.0)).toColor();
}

/// Qt QColor.lightness()（0–255）。
int lightness(Color c) {
  final r = (c.r * 255).round(), g = (c.g * 255).round(), b = (c.b * 255).round();
  final mx = [r, g, b].reduce((a, b) => a > b ? a : b), mn = [r, g, b].reduce((a, b) => a < b ? a : b);
  return ((mx + mn) / 2).round();
}

// 圖面
const bg = Color(0xfff4f9fc);
const gridMinor = Color(0xffd6dde4);
const gridMajor = Color(0xffb3bcc6);
const axis = Color(0xff6b7682);
const cross = Color(0xffe8141b);
const preview = Color(0xff1c7ed6);
const measure = Color(0xff7048e8);
const labelBg = Color(0xe1f4f9fc);
const labelFg = Color(0xff39424c);

// 吊車
const orange = Color(0xfff29100);
const bodyGrey = Color(0xffb9b9b9);
const sectionGrey = Color(0xff9b9b9b);
const outline = Color(0xff3a3a3a);
const window = Color(0xffd4ecf8);
const tipRed = Color(0xffe8141b);
const dimColor = Color(0xff5f3dc4);

// 物件
const selectBlue = Color(0xff1c7ed6);
const collideFill = Color(0xffe0474c);
const collidePen = Color(0xff9b0000);
const warnPen = Color(0xfff08c00);
const hoistColor = Color(0xff343a40);
const slingColor = Color(0xffe8590c);

// 介面
const text = Color(0xff1d2530);
const textMuted = Color(0xff56616d);
const textHint = Color(0xff7a8590);
const sectionBlue = Color(0xff1467b0);
const fieldBorder = Color(0xff3a9ad9);
const okGreen = Color(0xff2e9e5b);
const warnAmber = Color(0xffffb020);
const cautionYellow = Color(0xfffff3bf);
const alertRed = Color(0xffe0474c);
const errorText = Color(0xffc0282e);
const noteBrown = Color(0xffa05a00);
const infoBlue = Color(0xff3b6ea5);
