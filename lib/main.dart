/// 吊車作業模擬（手機網頁版）：讀取吊車規格、還原上次的圖面、顯示主畫面。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'models/crane_spec.dart';
import 'models/simulation.dart';
import 'platform/web_io.dart' as io;
import 'ui/colors.dart' as k;
import 'ui/home_page.dart';
import 'ui/project_store.dart' as store;

const craneAsset = 'assets/cranes/kato_300lx.json';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(['Noto Sans TC'], await rootBundle.loadString('assets/fonts/OFL.txt'));
  });
  Widget home;
  try {
    final specJson = jsonDecode(await rootBundle.loadString(craneAsset)) as Map<String, dynamic>;
    final model = SimulationModel(CraneSpec.fromJson(specJson));
    _restore(model);
    home = HomePage(model: model, specJson: specJson);
  } catch (e) {
    home = Scaffold(body: Center(child: Padding(padding: const EdgeInsets.all(24), child: Text('無法讀取吊車資料：$e'))));
  }
  runApp(CraneApp(home: home));
}

/// 還原上次自動保存的圖面（吊車型號不同或內容有誤時略過）。
void _restore(SimulationModel model) {
  final data = store.loadAutosave();
  if (data == null || store.checkProject(data, model.spec.id) != null) return;
  try {
    model.loadProject(data);
  } catch (_) {
    model.reset();
  }
}

class CraneApp extends StatelessWidget {
  final Widget home;

  const CraneApp({super.key, required this.home});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: appName,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: k.sectionBlue,
        brightness: Brightness.light,
        fontFamily: k.appFont,
        scaffoldBackgroundColor: const Color(0xfff3f5f7),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.white,
          foregroundColor: k.text,
          surfaceTintColor: Colors.white,
          elevation: 1,
        ),
        visualDensity: VisualDensity.standard,
      ),
      home: home,
      builder: (context, child) => _SafeAreaFix(child: child!),
    );
  }
}

/// Flutter 網頁版拿不到 iPhone 的安全區域：改用 index.html 量到的值（AppBar、SafeArea 會自動留白）。
/// 開啟後幾秒內、以及畫面尺寸改變（旋轉）時重新量測。
class _SafeAreaFix extends StatefulWidget {
  final Widget child;

  const _SafeAreaFix({required this.child});

  @override
  State<_SafeAreaFix> createState() => _SafeAreaFixState();
}

class _SafeAreaFixState extends State<_SafeAreaFix> with WidgetsBindingObserver {
  (double, double, double, double) _inset = io.safeArea();
  final List<Timer> _timers = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    for (final ms in const [300, 1000, 2500]) {
      _timers.add(Timer(Duration(milliseconds: ms), _remeasure));
    }
  }

  @override
  void dispose() {
    for (final t in _timers) {
      t.cancel();
    }
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    _remeasure();
    _timers.add(Timer(const Duration(milliseconds: 400), _remeasure)); // 旋轉後安全區域稍後才更新
  }

  void _remeasure() {
    final v = io.safeArea();
    if (mounted && v != _inset) setState(() => _inset = v);
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final (t, r, b0, l) = _inset;
    final b = mq.viewInsets.bottom > 0 ? 0.0 : b0; // 鍵盤打開時底部不必留白
    if (t == 0 && r == 0 && b == 0 && l == 0) return widget.child;
    double mx(double a, double c) => a > c ? a : c;
    return MediaQuery(
      data: mq.copyWith(
        padding: EdgeInsets.fromLTRB(
            mx(l, mq.padding.left), mx(t, mq.padding.top), mx(r, mq.padding.right), mx(b, mq.padding.bottom)),
        viewPadding: EdgeInsets.fromLTRB(l, t, r, b0),
      ),
      child: widget.child,
    );
  }
}
