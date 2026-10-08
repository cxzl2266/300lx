// 介面冒煙測試：手機直式與寬版面都畫得出來，每一頁、每種物件、拖曳、量測、復原都不會出錯。
import 'dart:convert';
import 'dart:io';

import 'package:crane_app/main.dart';
import 'package:crane_app/models/crane_spec.dart';
import 'package:crane_app/models/objects.dart';
import 'package:crane_app/models/simulation.dart';
import 'package:crane_app/ui/canvas/canvas_controller.dart';
import 'package:crane_app/ui/home_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _spec() =>
    jsonDecode(File('assets/cranes/kato_300lx.json').readAsStringSync()) as Map<String, dynamic>;

Future<(SimulationModel, CanvasController)> _pump(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final json = _spec();
  final model = SimulationModel(CraneSpec.fromJson(json));
  await tester.pumpWidget(CraneApp(home: HomePage(model: model, specJson: json)));
  await tester.pumpAndSettle();
  final state = tester.state(find.byType(HomePage));
  final canvas = (state as dynamic).canvas as CanvasController;
  return (model, canvas);
}

void main() {
  testWidgets('手機直式：四個分頁都能顯示', (tester) async {
    final (model, _) = await _pump(tester, const Size(390, 844));
    for (final tab in ['荷重', '物件', '車體', '吊臂']) {
      await tester.tap(find.text(tab).last);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: tab);
    }
    expect(find.text('臂長'), findsOneWidget);
    expect(model.objects(), isNotEmpty);
  });

  testWidgets('寬版面：圖面與面板並排', (tester) async {
    await _pump(tester, const Size(1280, 800));
    expect(find.text('吊臂'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('拖曳主臂、紅點、物件與量測', (tester) async {
    final (model, c) = await _pump(tester, const Size(390, 844));
    final r = model.result;
    // 拖曳主臂本體（改臂角）
    final mid = c.toScreen((x: (r.pivot.x + r.mainTip.x) / 2, y: (r.pivot.y + r.mainTip.y) / 2));
    final angle = model.pose.angle;
    c.pointerDown(mid);
    c.pointerMove(mid + const Offset(30, 30));
    c.pointerUp(mid + const Offset(30, 30));
    await tester.pump();
    expect(model.pose.angle, lessThan(angle));
    expect(model.undoStack.undoText, '拖曳主臂角度');
    // 拖曳臂端紅點（只改臂長）
    final len = model.pose.length;
    final tip = c.toScreen(model.result.mainTip);
    final dir = (tip - c.toScreen(model.result.pivot));
    final out = tip + dir / dir.distance * 40;
    c.pointerDown(tip);
    c.pointerMove(out);
    c.pointerUp(out);
    expect(model.pose.length, greaterThan(len));
    // 每種物件都建立一次
    for (final kind in ['rect', 'ground', 'wire', 'dimension']) {
      c.addKind(kind);
      final a = c.toScreen((x: 10.0, y: 2.0)), b = c.toScreen((x: 14.0, y: 5.0));
      c.pointerDown(a);
      c.pointerMove(b);
      c.pointerUp(b);
      expect(c.mode, 'select', reason: kind);
    }
    c.addKind('polygon');
    for (final p in [(x: 20.0, y: 0.0), (x: 24.0, y: 0.0), (x: 22.0, y: 4.0)]) {
      c.pointerDown(c.toScreen(p));
      c.pointerUp(c.toScreen(p));
    }
    c.finishPolygon();
    c.addKind('truck');
    c.pointerDown(c.toScreen((x: 26.0, y: 0.0)));
    c.pointerUp(c.toScreen((x: 26.0, y: 0.0)));
    c.addKind('load');
    expect(model.load(), isNotNull);
    expect(model.hookSetup.overhoistState(model.load()!.hoist), '', reason: '新吊物不應一放上去就過捲');
    final kinds = model.objects().map((o) => o.kind).toSet();
    expect(kinds, containsAll(['rect', 'ground', 'wire', 'dimension', 'polygon', 'truck', 'load']));
    // 量測
    c.setMode('measure');
    c.pointerDown(c.toScreen((x: 0.0, y: 0.0)));
    c.pointerMove(c.toScreen((x: 3.0, y: 4.0)));
    c.pointerUp(c.toScreen((x: 3.0, y: 4.0)));
    expect(c.measurement!.distance, closeTo(5.0, 1e-9));
    c.keepMeasurement();
    expect(model.objects().whereType<DimensionObject>().length, 2);
    // 每個分頁、選取每種物件都能顯示
    await tester.pumpAndSettle();
    for (final o in model.objects()) {
      c.selectIds([o.id]);
      await tester.tap(find.textContaining('物件').last);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: o.kind);
    }
    // 存檔、全部復原、讀回
    final saved = model.toProject();
    while (model.undoStack.canUndo) {
      model.undoStack.undo();
    }
    await tester.pumpAndSettle();
    model.loadProject(jsonDecode(jsonEncode(saved)) as Map<String, Object?>);
    expect(model.objects().length, (saved['objects'] as List).length);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
