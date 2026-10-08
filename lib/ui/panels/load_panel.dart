/// 「荷重」頁：吊重表（外伸、額定、使用率、吊鉤與吊具重）與安全檢查（移植自桌面版 param_panel.py）。
library;

import 'package:flutter/material.dart';

import '../../core/geometry.dart' show OutOfReachError;
import '../../core/pyformat.dart';
import '../../models/crane_spec.dart';
import '../../models/safety.dart' show SafetyReport;
import '../../models/simulation.dart';
import '../colors.dart' as k;
import '../widgets/common.dart';
import '../widgets/value_field.dart';

class LoadPanel extends StatelessWidget {
  final SimulationModel model;
  final void Function(String) onMessage;

  const LoadPanel({super.key, required this.model, required this.onMessage});

  @override
  Widget build(BuildContext context) {
    final m = model;
    final rep = m.safety();
    final rating = m.loadRating();
    final chk = rep.loadCheck;
    final hasLoad = chk != null && chk.loadWeight != null;

    final children = <Widget>[];
    if (rating != null) {
      final charts = m.spec.loadCharts!;
      children.addAll([
        const SectionTitle('吊重表'),
        Row(children: [
          const Text('支撐座外伸'),
          const SizedBox(width: 10),
          Expanded(
            child: DropdownButton<double>(
              isExpanded: true,
              value: charts.outriggers.contains(m.outrigger) ? m.outrigger : null,
              items: [
                for (final (i, v) in charts.outriggers.indexed)
                  DropdownMenuItem(value: v, child: Text('${g(v)} m${i == 0 ? '（全伸）' : ''}')),
              ],
              onChanged: (v) {
                if (v == null || v == m.outrigger) return;
                try {
                  m.setOutrigger(v);
                } on OutOfReachError catch (e) {
                  onMessage(e.message);
                }
              },
            ),
          ),
        ]),
        const SizedBox(height: 4),
        FieldGrid(children: [
          ValueField(
            title: '額定總荷重',
            unit: ' t',
            decimals: 2,
            compact: true,
            getter: () => rating.capacity ?? double.nan,
            look: () => rating.capacity == null ? (hasLoad ? FieldLook.alert : FieldLook.error) : FieldLook.ok,
            help: '依工作半徑查原廠荷重表（含吊鉤、吊具重量）。\n'
                '不內插也不外插：介於表列值之間取相鄰格較小值；原表空白＝無額定值。\n'
                '例外：臂長介於兩欄、較短臂伸不到時改取較長臂，並以較短臂最遠一列為上限；\n'
                '半徑小於表列最小半徑時用最小半徑那列。',
          ),
          ValueField(
            title: '使用率',
            unit: '%',
            decimals: 1,
            compact: true,
            getter: () => chk?.usage == null ? double.nan : chk!.usage! * 100,
            look: () {
              if (!hasLoad || chk.usage == null) return FieldLook.ok;
              return switch (chk.levelName) {
                'caution' => FieldLook.caution,
                'warning' => FieldLook.warn,
                'collision' => FieldLook.alert,
                _ => FieldLook.ok,
              };
            },
            help: '實際吊重 ÷ 額定總荷重：≥ 80% 黃、≥ 90% 橘、> 100% 紅',
          ),
          ValueField(
            title: '實際吊重',
            unit: ' t',
            decimals: 2,
            compact: true,
            getter: () => chk?.total ?? double.nan,
            help: '吊物重量（物件頁）＋ 主吊鉤重 ＋ 副吊鉤重 ＋ 吊具重',
          ),
          ValueField(
            title: '吊具重',
            unit: ' t',
            decimals: 2,
            compact: true,
            step: 0.05,
            getter: () => m.riggingWeight,
            setter: m.setRiggingWeight,
            help: '吊索、卸扣、吊梁等重量（每次吊掛自行輸入）；\n額定總荷重已包含吊鉤與吊具，要一併計入',
            onError: onMessage,
          ),
          ValueField(
            title: '主吊鉤重',
            unit: ' t',
            decimals: 2,
            compact: true,
            getter: () => m.spec.hookWeight ?? double.nan,
            help: _hookWeightTip,
          ),
          if (m.spec.hasAuxHook)
            ValueField(
              title: '副吊鉤重',
              unit: ' t',
              decimals: 2,
              compact: true,
              getter: () => m.spec.auxHookWeight ?? double.nan,
              help: _hookWeightTip,
            ),
        ]),
        const SizedBox(height: 8),
        Lines(_chartLines(m, hasLoad), size: 12),
      ]);
    }

    // 安全檢查
    final (clr, obj, _) = rep.worst;
    children.addAll([
      const SectionTitle('安全檢查'),
      FieldGrid(children: [
        ValueField(
          title: '最小淨空',
          unit: ' m',
          decimals: 2,
          compact: true,
          getter: () => m.worstClearance().$1,
          display: () {
            final (c, o, _) = m.worstClearance();
            if (o == null) return '—';
            if (c <= 0) return '碰撞';
            return null;
          },
          look: () => obj != null && clr <= 0 ? FieldLook.alert : FieldLook.ok,
          help: '主臂、助臂（各扣半寬）、鋼索、吊鉤、吊索與吊物到各障礙物的最短距離',
        ),
        ValueField(
          title: '尖端下彎量',
          unit: ' m',
          decimals: 2,
          compact: true,
          step: 0.05,
          getter: () => m.deflection,
          setter: m.setTipDeflection,
          help: '依原廠資料或經驗填入（0 = 不修正）。\n淨空與地面檢查會用下彎後的吊臂，吊物也掛在下彎後的尖端；'
              '「鉤底離地高度」仍是未下彎的數值。',
          onError: onMessage,
        ),
      ]),
      const SizedBox(height: 8),
      Text(
        obj == null
            ? '沒有參與碰撞檢查的障礙物'
            : (clr <= 0 ? '撞到：${obj.name}' : '最接近：${obj.name}（安全間距 ${fixed(obj.margin, 1)} m）'),
        textAlign: TextAlign.center,
        style: const TextStyle(color: k.textMuted),
      ),
      ..._loadGround(rep),
      if (m.deflection > 0 && rep.riggingTip != null)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            '下彎後鉤底離地高度 ${fixed(rep.riggingTip!.y - m.hookDrop, 2)} m（未下彎 ${fixed(m.hookBottomHeight, 2)} m）',
            textAlign: TextAlign.center,
            style: const TextStyle(color: k.dimColor),
          ),
        ),
      const SizedBox(height: 8),
      SafetyBanner(model: m),
      const SizedBox(height: 6),
      Lines(_otherIssues(rep), size: 12.5),
      const SizedBox(height: 16),
    ]);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
  }

  static const _hookWeightTip = '依吊車規格自動帶入。主、副吊鉤都掛在吊臂上，兩個都計入實際吊重\n（不論目前用哪一個吊鉤作業）';

  static List<Line> _chartLines(SimulationModel m, bool hasLoad) {
    final rating = m.loadRating()!;
    final lines = <Line>[(rating.chart, k.textHint)];
    if (rating.capacity == null) {
      lines.add(('**無適用額定荷重**：${rating.basis}', k.errorText));
    } else {
      lines.add((rating.basis, const Color(0xff3b4652)));
    }
    if (rating.note.isNotEmpty) lines.add(('⚠ ${rating.note}', k.noteBrown)); // 提醒（不影響額定值）
    final droop = m.jibDroop();
    if (droop != 0) {
      lines.add(('ⓘ 副臂依荷重表同步：臂角＝荷重表作業角度，半徑照荷重表（兩列之間內插）；圖面吊臂含下彎、'
              '下垂 ${fixed(droop, 2)}°（吊額定荷重時，輕載時實際吊臂較高）',
          k.infoBlue));
    }
    for (final rem in m.loadReminders()) {
      // 原廠荷重表說明：⚠ 與目前姿態相關、ⓘ 條件式說明
      lines.add(rem.level == 'warn' ? ('⚠ ${rem.text}', k.noteBrown) : ('ⓘ ${rem.text}', k.infoBlue));
    }
    if (!hasLoad) lines.add(('圖上沒有吊物，未計算使用率（物件 → 新增 → 吊物）', k.textHint));
    final spec = m.spec;
    final hooks = <(String, double?)>[(hookNames[mainHook]!, spec.hookWeight)];
    if (spec.hasAuxHook) hooks.add((hookNames[auxHook]!, spec.auxHookWeight));
    final known = [
      for (final (name, w) in hooks)
        if (w != null) '$name ${fixed(w, 2)} t'
    ];
    if (known.isNotEmpty) {
      lines.add(('吊鉤：${known.join(' ＋ ')} 都計入實際吊重（目前用${hookNames[m.hook]}作業）', k.textHint));
    }
    final missing = [
      for (final (name, w) in hooks)
        if (w == null) name
    ];
    if (missing.isNotEmpty) lines.add(('規格檔沒有${missing.join('、')}重量，未計入實際吊重', k.noteBrown));
    if (m.riggingWeight == 0) lines.add(('吊具重為 0：吊索、卸扣、吊梁等請依實際輸入', k.textHint));
    return lines;
  }

  static List<Widget> _loadGround(SafetyReport rep) {
    final lg = rep.loadGround;
    if (lg == null) return const [];
    final sup = rep.loadSupport;
    String t;
    Color c;
    if (sup != null) {
      // 吊物下方是聯結車：以車頂為準
      final sname = sup.name.isNotEmpty ? sup.name : sup.label;
      if (lg < -0.01) {
        (t, c) = ('吊物壓到$sname ${fixed(-lg, 2)} m', k.errorText);
      } else if (lg <= 0.05) {
        (t, c) = ('吊物放置在$sname上', k.textMuted);
      } else {
        (t, c) = ('吊物離$sname車頂 ${fixed(lg, 2)} m', k.text);
      }
    } else if (lg < -0.01) {
      (t, c) = ('吊物低於地面 ${fixed(-lg, 2)} m', k.errorText);
    } else if (lg <= 0.05) {
      (t, c) = ('吊物著地', k.textMuted);
    } else {
      (t, c) = ('吊物離地 ${fixed(lg, 2)} m', k.text);
    }
    return [
      Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(t, textAlign: TextAlign.center, style: TextStyle(color: c, fontWeight: FontWeight.w700)),
      )
    ];
  }

  static List<Line> _otherIssues(SafetyReport rep) {
    final top = rep.topIssue();
    final others = [
      for (final i in rep.issues)
        if (!identical(i, top) && (i.level == 'collision' || i.level == 'warning')) i
    ];
    final lines = <Line>[
      for (final i in others.take(6)) ('• ${i.message}', i.level == 'collision' ? k.errorText : const Color(0xffa34700))
    ];
    if (others.length > 6) lines.add(('…另有 ${others.length - 6} 項', k.textMuted));
    return lines;
  }
}

/// 安全檢查總結：顯示最嚴重的一項（紅＝碰撞或超載、橘＝注意、綠＝淨空足夠）。
class SafetyBanner extends StatelessWidget {
  final SimulationModel model;
  final bool compact;
  final VoidCallback? onTap;

  const SafetyBanner({super.key, required this.model, this.compact = false, this.onTap});

  static (String, Color, Color) summary(SimulationModel m) {
    final rep = m.safety();
    final level = rep.levelName;
    final top = rep.topIssue();
    if (level == 'collision') return (top!.message, k.alertRed, Colors.white);
    if (level == 'warning') return ('注意：${top!.message}', k.warnAmber, const Color(0xff3a2600));
    if (rep.checked == 0 && rep.loadGround == null) {
      return ('未檢查（沒有障礙物或吊物）', const Color(0xffeef1f4), k.textMuted);
    }
    return ('淨空足夠', k.okGreen, Colors.white);
  }

  @override
  Widget build(BuildContext context) {
    final (text, bg, fg) = summary(model);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 8, vertical: compact ? 4 : 8),
        constraints: BoxConstraints(minHeight: compact ? 0 : 36),
        alignment: Alignment.center,
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(8)),
        child: Text(text,
            textAlign: TextAlign.center,
            maxLines: compact ? 1 : 6,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: fg, fontWeight: FontWeight.w700, fontSize: compact ? 12.5 : 14)),
      ),
    );
  }
}
