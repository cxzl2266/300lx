/// 「吊臂」頁：主臂（臂長、半徑、臂角、鉤底離地高度）、助臂、吊鉤（移植自桌面版 param_panel.py）。
library;

import 'package:flutter/material.dart';

import '../../core/geometry.dart' show OutOfReachError;
import '../../core/pyformat.dart';
import '../../models/crane_spec.dart';
import '../../models/simulation.dart';
import '../colors.dart' as k;
import '../widgets/common.dart';
import '../widgets/value_field.dart';

class BoomPanel extends StatelessWidget {
  final SimulationModel model;
  final void Function(String) onMessage;

  const BoomPanel({super.key, required this.model, required this.onMessage});

  @override
  Widget build(BuildContext context) {
    final m = model;
    final spec = m.spec;
    final lim = m.limits;
    final hk = m.hookSetup;

    final boomTxt =
        spec.limitBoomLength ? '臂長 ${fixed(lim.boomMin, 2)}–${fixed(lim.boomMax, 2)} m' : '臂長不限制';
    String jibTxt;
    if (spec.jibLengths.isNotEmpty) {
      jibTxt = '助臂 ${spec.jibLengths.map((v) => fixed(v, 2)).join('／')} m';
    } else if (spec.limitJibLength) {
      jibTxt = '助臂 ${fixed(lim.jibMin, 2)}–${fixed(lim.jibMax, 2)} m';
    } else {
      jibTxt = '助臂長度不限制';
    }
    if (spec.jibOffsets.isNotEmpty) jibTxt += '、角度 ${spec.jibOffsets.map((v) => '${g(v)}°').join('／')}';
    final rangeHint = '$boomTxt；$jibTxt；臂角 ${fixed(lim.angleMin, 0)}°–${fixed(lim.angleMax, 0)}°';

    final how = hk.bottomDrop != null
        ? '${hk.name}收到最高時的鉤底），吊車操作室電腦顯示的高度'
        : '${hk.name}收到最高時的鉤底：過捲極限 ${fixed(hk.overhoist, 3)} + 吊鉤高度 ${fixed(hk.blockHeight, 3)} m）';
    final computerInfo =
        '鉤底離地高度＝${hk.sheave}中心 ${fixed(m.result.height, 2)} m − ${fixed(m.hookDrop, 3)} m（$how';

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      GestureDetector(
        onTap: () => showInfo(context, '原廠規格摘要', _referenceTip(spec)),
        child: Row(children: [
          Expanded(child: Text('吊車型號：${spec.name}', style: const TextStyle(color: k.textMuted))),
          const Icon(Icons.info_outline, size: 16, color: k.textHint),
        ]),
      ),
      if (spec.unverified.isNotEmpty)
        GestureDetector(
          onTap: () => showInfo(context, '未經查核的規格', spec.unverified.map((u) => '• $u').join('\n')),
          child: Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('⚠ 有 ${spec.unverified.length} 項規格未經查核（點這裡看清單）',
                style: const TextStyle(color: k.noteBrown, fontSize: 12)),
          ),
        ),
      const SectionTitle('主臂'),
      FieldGrid(children: [
        ValueField(
            title: '臂長', unit: ' m', decimals: 2, getter: () => m.pose.length, setter: m.setBoomLength, onError: onMessage),
        ValueField(
            title: '半徑',
            unit: ' m',
            decimals: 2,
            getter: () => m.result.radius,
            setter: m.setRadius,
            help: '輸入半徑會保持臂長、反算臂角',
            onError: onMessage),
        ValueField(
            title: '臂角',
            unit: '°',
            decimals: 2,
            getter: () => m.pose.angle,
            setter: m.setBoomAngle,
            step: 0.5,
            onError: onMessage),
        ValueField(
            title: '鉤底離地高度',
            unit: ' m',
            decimals: 2,
            getter: () => m.hookBottomHeight,
            setter: m.setHookBottomHeight,
            help: '目前使用的吊鉤收到最高時，鉤底離地的高度（吊車操作室電腦顯示的「主臂尖端高度」；'
                '副吊鉤已用實車 8 組驗證）。\n輸入高度會保持臂長、反算臂角',
            onError: onMessage),
      ]),
      const SizedBox(height: 6),
      Lines([(computerInfo, const Color(0xff3b4652)), (rangeHint, k.textHint)], size: 12),

      // 助臂
      SectionTitle('助臂',
          trailing: Switch(
            value: m.pose.jibEnabled,
            onChanged: spec.jibAvailable ? (v) => _guard(() => m.setJibEnabled(v)) : null,
          )),
      if (!spec.jibAvailable) const Text('此型號沒有助臂', style: TextStyle(color: k.textHint, fontSize: 12)),
      if (m.pose.jibEnabled) ...[
        FieldGrid(children: [
          ValueField(
              title: '助臂長度',
              unit: ' m',
              decimals: 2,
              getter: () => m.pose.jibLength,
              setter: m.setJibLength,
              stepper: m.nextJibLength,
              onError: onMessage),
          ValueField(
              title: '助臂角度',
              unit: '°',
              decimals: 2,
              getter: () => m.pose.jibOffset,
              setter: m.setJibOffset,
              step: 1.0,
              stepper: m.nextJibOffset,
              help: '相對主臂向下的偏角，0° = 與主臂同一直線',
              onError: onMessage),
        ]),
        const SizedBox(height: 6),
        const Lines([('開啟助臂時，半徑與鉤底離地高度以副臂尖端的副吊鉤計算。', k.textHint)], size: 12),
      ],

      // 吊鉤
      if (spec.hasAuxHook) ...[
        const SectionTitle('吊鉤'),
        SegmentedButton<String>(
          segments: [
            ButtonSegment(value: mainHook, label: Text(hookNames[mainHook]!)),
            ButtonSegment(value: auxHook, label: Text(hookNames[auxHook]!)),
          ],
          selected: {m.hook},
          showSelectedIcon: false,
          onSelectionChanged: m.pose.jibEnabled ? null : (s) => _guard(() => m.setHook(s.first)),
        ),
        const SizedBox(height: 6),
      ] else
        const SectionTitle('吊鉤'),
      Lines(_hookLines(m), size: 12),
      const SizedBox(height: 16),
    ]);
  }

  void _guard(void Function() fn) {
    try {
      fn();
    } on OutOfReachError catch (e) {
      onMessage(e.message);
    }
  }

  static String _referenceTip(CraneSpec spec) {
    if (spec.reference.isEmpty) return spec.note.isEmpty ? '（無）' : spec.note;
    String cell(List<String> r, int i) => i < r.length ? r[i] : '';
    return [
      for (final r in spec.reference)
        '${'${cell(r, 1)}：${cell(r, 2)} ${cell(r, 3)}'.trimRight()}${cell(r, 4).isNotEmpty ? '（${cell(r, 4)}）' : ''}'
    ].join('\n');
  }

  static List<Line> _hookLines(SimulationModel m) {
    final hk = m.hookSetup;
    final lines = <Line>[];
    if (m.pose.jibEnabled) lines.add(('副臂作業只能使用副吊鉤（掛在副臂尖）', k.infoBlue));
    lines.add(('過捲極限 **${fixed(hk.overhoist, 3)} m**：${hk.name}頂至${hk.sheave}中心（原廠）', const Color(0xff3b4652)));
    lines.add(('圖面提早 ${fixed(hk.warning, 2)} m 警告：距離小於 ${fixed(hk.overhoist + hk.warning, 3)} m 顯示「接近過捲」'
            '（不限制拖曳）',
        k.textHint));
    lines.add(('${hk.name}高度 ${fixed(hk.blockHeight, 3)} m（吊鉤頂至鉤底）', k.textHint));
    if (m.hook == auxHook && !m.pose.jibEnabled) {
      final lim = m.limits;
      if (m.spec.hasAuxSheave) {
        lines.add(('副吊鉤掛在單滑輪：主臂頂滑輪沿臂身往外 ${fixed(lim.auxAlong, 3)} m、往下 ${fixed(lim.auxBelow, 3)} m，'
                '鋼索再往外 ${fixed(lim.auxRope, 3)} m 垂下；半徑、鉤底離地高度以單滑輪的副吊鉤計算',
            k.infoBlue));
      }
      if (m.auxHookLimit() == null) {
        lines.add(('⚠ 主臂改用副吊鉤：額定值仍依主臂荷重表；副吊鉤作業另有上限（鋼索股數、吊鉤容量等），請依原廠荷重表說明確認',
            k.noteBrown));
      } else {
        lines.add(('⚠ 副吊鉤作業的吊物上限見「荷重」頁的吊重表提醒', k.noteBrown));
      }
    }
    return lines;
  }
}
