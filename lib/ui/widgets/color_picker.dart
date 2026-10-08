/// 選擇顏色：常用色 + 自行輸入 #rrggbb。
library;

import 'package:flutter/material.dart';

import '../colors.dart' as k;

const List<String> _palette = [
  '#3aa3d2', '#1f6f96', '#1c7ed6', '#1467b0', '#5f3dc4', '#7048e8', //
  '#8cc084', '#3f7a3e', '#2b8a3e', '#2e9e5b', '#f2c14e', '#8a6400', //
  '#f29100', '#e8590c', '#c0504d', '#ff6b6b', '#e0474c', '#c92a2a', //
  '#c49a6c', '#7a5230', '#ffffff', '#adb5bd', '#868e96', '#495057', //
  '#343a40', '#1d2530', '#000000', '#3d7cc9', '#243447', '#d4ecf8',
];

Future<String?> pickColor(BuildContext context, String current) {
  final ctl = TextEditingController(text: current);
  return showDialog<String>(
    context: context,
    builder: (ctx) => StatefulBuilder(builder: (ctx, setState) {
      return AlertDialog(
        title: const Text('選擇顏色'),
        content: SizedBox(
          width: 300,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final c in _palette)
                GestureDetector(
                  onTap: () => Navigator.pop(ctx, c),
                  child: Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: k.hex(c),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                          color: c.toLowerCase() == current.toLowerCase() ? k.selectBlue : const Color(0xff868e96),
                          width: c.toLowerCase() == current.toLowerCase() ? 3 : 1),
                    ),
                  ),
                ),
            ]),
            const SizedBox(height: 12),
            Row(children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                    color: k.hex(ctl.text), border: Border.all(color: const Color(0xff868e96))),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: ctl,
                  decoration: const InputDecoration(labelText: '色碼（#rrggbb）'),
                  onChanged: (_) => setState(() {}),
                ),
              ),
            ]),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () {
              final t = ctl.text.trim();
              final ok = RegExp(r'^#?[0-9a-fA-F]{6}$').hasMatch(t);
              if (!ok) return;
              Navigator.pop(ctx, t.startsWith('#') ? t.toLowerCase() : '#${t.toLowerCase()}');
            },
            child: const Text('確定'),
          ),
        ],
      );
    }),
  );
}
