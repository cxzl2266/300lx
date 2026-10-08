/// 「車體」頁：車體尺寸（只影響圖面與車身碰撞；車高可能連動臂根鉸點）。
library;

import 'package:flutter/material.dart';

import '../../core/pyformat.dart';
import '../../core/vehicle.dart' show bodyLabels;
import '../../models/simulation.dart';
import '../canvas/canvas_controller.dart';
import '../colors.dart' as k;
import '../widgets/common.dart';
import '../widgets/value_field.dart';

class BodyPanel extends StatelessWidget {
  final SimulationModel model;
  final CanvasController canvas;
  final void Function(String) onMessage;

  const BodyPanel({super.key, required this.model, required this.canvas, required this.onMessage});

  static const _tips = {
    'total_length': '車尾到車頭的總長',
    'chassis_length': '底盤大樑長度（置中於車總長內）',
    'height': '車體最高點（駕駛室頂，不含吊臂）',
    'width': '車寬（側視圖看不到，圖面以文字標示）',
    'front': '迴轉中心到車頭的距離，決定車身前後位置',
  };

  @override
  Widget build(BuildContext context) {
    final m = model;
    final lim = m.limits;
    const others = '車總長、底盤、車寬、迴轉中心至車頭只影響圖面外型。';
    final String pivotInfo, note;
    if (m.spec.pivotFixed) {
      pivotInfo = '臂根鉸點高度 ${fixed(lim.pivotY, 2)} m（原廠確定值，不隨車高變動）';
      note = '此型號的臂根鉸點為原廠確定值：修改車高只影響圖面外型與車身碰撞，鉸點與鉤底離地高度不變。$others';
    } else {
      final dh = m.body.height - m.spec.body.height;
      final change = dh.abs() < 1e-9
          ? ''
          : '（規格預設 ${fixed(m.spec.limits.pivotY, 2)} m，${signedFixed(dh, 2)} m）';
      pivotInfo = '臂根鉸點高度 ${fixed(lim.pivotY, 2)} m$change';
      note = '車高會連動臂根鉸點高度：車高增加多少，鉸點與鉤底離地高度就增加多少（半徑不變）。$others';
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SectionTitle('車體尺寸'),
      FieldGrid(children: [
        for (final key in _tips.keys)
          ValueField(
            title: bodyLabels[key]!,
            unit: ' m',
            decimals: 2,
            compact: true,
            getter: () => m.body.field(key),
            setter: (v) => m.setBodyField(key, v),
            help: _tips[key],
            onError: onMessage,
          ),
      ]),
      const SizedBox(height: 8),
      Row(children: [
        OutlinedButton.icon(
          onPressed: m.resetBody,
          icon: const Icon(Icons.restart_alt, size: 18),
          label: const Text('還原預設'),
        ),
        const Spacer(),
        const Text('圖面標示尺寸'),
        Switch(value: canvas.showBodyDims, onChanged: (v) => canvas.setOption(() => canvas.showBodyDims = v)),
      ]),
      const SizedBox(height: 6),
      Lines([(pivotInfo, k.sectionBlue), (note, k.textHint)], size: 12.5),
      const SizedBox(height: 16),
    ]);
  }
}
