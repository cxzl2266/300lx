/// 面板共用小元件：段落標題、多行彩色說明、提示對話框。
library;

import 'package:flutter/material.dart';

import '../colors.dart' as k;

class SectionTitle extends StatelessWidget {
  final String text;
  final Widget? trailing;

  const SectionTitle(this.text, {super.key, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 14, bottom: 6),
      child: Row(children: [
        Container(width: 4, height: 16, color: k.sectionBlue),
        const SizedBox(width: 6),
        Expanded(
          child: Text(text,
              style: const TextStyle(fontWeight: FontWeight.w700, color: k.sectionBlue, fontSize: 15)),
        ),
        ?trailing,
      ]),
    );
  }
}

/// 一行說明：(文字, 顏色, 粗體)；文字裡用 **…** 標示粗體片段。
typedef Line = (String, Color);

class Lines extends StatelessWidget {
  final List<Line> lines;
  final double size;
  final TextAlign align;

  const Lines(this.lines, {super.key, this.size = 12.5, this.align = TextAlign.start});

  @override
  Widget build(BuildContext context) {
    if (lines.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: align == TextAlign.center ? CrossAxisAlignment.center : CrossAxisAlignment.start,
      children: [
        for (final (t, c) in lines)
          Padding(
            padding: const EdgeInsets.only(bottom: 3),
            child: Text.rich(_spans(t, c, size), textAlign: align),
          ),
      ],
    );
  }
}

TextSpan _spans(String text, Color color, double size) {
  final parts = text.split('**');
  return TextSpan(
    style: TextStyle(color: color, fontSize: size, height: 1.35),
    children: [
      for (var i = 0; i < parts.length; i++)
        TextSpan(text: parts[i], style: i.isOdd ? const TextStyle(fontWeight: FontWeight.w700) : null),
    ],
  );
}

Future<void> showInfo(BuildContext context, String title, String body) => showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(child: Text(body)),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('知道了'))],
      ),
    );

Future<bool> confirm(BuildContext context, String title, String body, {String ok = '確定'}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(ok)),
      ],
    ),
  );
  return r ?? false;
}

/// 輸入文字的對話框。
Future<String?> askString(BuildContext context, String title,
    {String label = '', String initial = '', bool multiline = false}) {
  final ctl = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: ctl,
        autofocus: true,
        minLines: multiline ? 3 : 1,
        maxLines: multiline ? 6 : 1,
        decoration: InputDecoration(labelText: label.isEmpty ? null : label),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.pop(ctx, ctl.text), child: const Text('確定')),
      ],
    ),
  );
}

/// 輸入數字的對話框（比例校正等）。
Future<double?> askNumber(BuildContext context, String title, String body, double initial) async {
  final ctl = TextEditingController(text: initial.toStringAsFixed(2));
  String? err;
  return showDialog<double>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: Text(title),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(body),
          const SizedBox(height: 8),
          TextField(
            controller: ctl,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(suffixText: 'm', errorText: err),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () {
              final v = double.tryParse(ctl.text.trim().replaceAll(',', '.'));
              if (v == null || !v.isFinite || v < 0.01 || v > 10000) {
                setState(() => err = '請輸入 0.01–10000 的數字');
                return;
              }
              Navigator.pop(ctx, v);
            },
            child: const Text('確定'),
          ),
        ],
      ),
    ),
  );
}
