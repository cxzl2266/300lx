/// 自我檢查頁：在這支手機的瀏覽器上，用和電腦版相同的標準答案逐筆比對。
///
/// 標準答案（selftest/golden.json，約 6.5 MB、壓縮後約 0.3 MB）只在按「開始檢查」時下載，不會預先存在手機。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../models/crane_spec.dart';
import '../platform/web_io.dart' as io;
import '../selftest/golden_check.dart';
import 'colors.dart' as k;

class SelfTestPage extends StatefulWidget {
  final Map<String, dynamic> specJson;

  const SelfTestPage({super.key, required this.specJson});

  @override
  State<SelfTestPage> createState() => _SelfTestPageState();
}

class _SelfTestPageState extends State<SelfTestPage> {
  final List<SectionResult> _results = [];
  String _status = '按「開始檢查」：下載標準答案（約 0.3 MB），在這支手機上重新計算並逐筆比對。';
  bool _running = false;
  String? _error;
  final _total = Stopwatch();

  Future<void> _run() async {
    setState(() {
      _running = true;
      _results.clear();
      _error = null;
      _status = '下載標準答案…';
    });
    _total
      ..reset()
      ..start();
    try {
      final golden = jsonDecode(await io.fetchText('selftest/golden.json')) as Map<String, dynamic>;
      final generic = jsonDecode(await io.fetchText('selftest/test_crane.json')) as Map<String, dynamic>;
      final data = GoldenData(golden, CraneSpec.fromJson(widget.specJson), CraneSpec.fromJson(generic));
      for (final s in sections) {
        setState(() => _status = '比對中：${s.$1}');
        await Future<void>.delayed(const Duration(milliseconds: 30)); // 讓畫面更新
        final r = runSection(s, data);
        setState(() => _results.add(r));
      }
      _total.stop();
      final checks = _results.fold<int>(0, (a, r) => a + r.checks);
      final fails = _results.fold<int>(0, (a, r) => a + r.fails.length);
      setState(() => _status = fails == 0
          ? '全部相同：共比對 $checks 項，和電腦版（Python）一致。'
          : '有 $fails 處不同（共比對 $checks 項），請把畫面截圖給開發者。');
    } catch (e) {
      _total.stop();
      setState(() {
        _error = '$e';
        _status = '無法完成檢查（需要網路連線下載標準答案）。';
      });
    }
    setState(() => _running = false);
  }

  @override
  Widget build(BuildContext context) {
    final allOk = _results.length == sections.length && _results.every((r) => r.ok);
    return Scaffold(
      appBar: AppBar(title: const Text('自我檢查')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        const Text(
          '用電腦版（Python，已驗證）算好的約 4.6 萬項標準答案，在這支手機上重新計算並逐筆比對：'
          '半徑、鉤底離地高度、額定荷重、提醒文字、碰撞淨空、安全檢查、復原／重做等。'
          '數值誤差須在 1e-9 以內，文字須完全相同。',
          style: TextStyle(color: k.textMuted),
        ),
        const SizedBox(height: 6),
        Text('計算環境：${kIsWeb ? '手機瀏覽器（JavaScript）' : 'Dart VM'}', style: const TextStyle(color: k.textHint)),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: _running ? null : _run,
          icon: _running
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.fact_check_outlined),
          label: Text(_running ? '檢查中…' : '開始檢查'),
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: allOk
                ? const Color(0xffe6f4ea)
                : (_results.any((r) => !r.ok) || _error != null ? const Color(0xfffff1f1) : const Color(0xffeef1f4)),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(_status,
              style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: allOk ? k.okGreen : (_results.any((r) => !r.ok) || _error != null ? k.errorText : k.text))),
        ),
        if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!)),
        const SizedBox(height: 8),
        for (final r in _results)
          Card(
            child: ListTile(
              leading: Icon(r.ok ? Icons.check_circle : Icons.error,
                  color: r.ok ? k.okGreen : k.errorText),
              title: Text(r.name),
              subtitle: Text(
                '${r.checks} 項，${r.ok ? '全部相同' : '${r.fails.length} 處不同'}（${(r.elapsed.inMilliseconds / 1000).toStringAsFixed(1)} 秒）'
                '${r.ok ? '' : '\n${r.fails.take(8).join('\n')}'}',
              ),
            ),
          ),
        if (!_running && _results.length == sections.length)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text('總共 ${(_total.elapsedMilliseconds / 1000).toStringAsFixed(1)} 秒',
                style: const TextStyle(color: k.textHint)),
          ),
      ]),
    );
  }
}
