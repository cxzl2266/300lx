/// 吊車規格（移植自 Python 版 models/crane.py）：從 assets/cranes/*.json 讀取。
library;

import '../core/geometry.dart';
import '../core/load_chart.dart';
import '../core/vehicle.dart';

const String mainHook = 'main';
const String auxHook = 'aux';
const Map<String, String> hookNames = {mainHook: '主吊鉤', auxHook: '副吊鉤'};
const double overhoistWarning = 0.30; // 吊鉤頂距滑輪小於「過捲極限 + 0.30 m」就警告（不限制操作）
const double overhoistEps = 1e-6;
const List<String> legacyHookKeys = ['min_hoist', 'jib_min_hoist', 'jib_block_height', 'jib_weight'];

/// 作業用的吊鉤：過捲極限、吊鉤高度。
class HookSetup {
  final String hook; // mainHook / auxHook
  final bool onJib;
  final String sheave; // 吊鉤掛的滑輪：主臂頂滑輪、單滑輪、副臂尖滑輪
  final double blockHeight; // 吊鉤頂至鉤底
  final double overhoist; // 吊鉤頂至滑輪中心的最短距離
  final double warning;
  final double? bottomDrop; // 滑輪中心至「吊鉤收到最高時的鉤底」；null = 過捲極限 + 吊鉤高度

  const HookSetup(this.hook, this.onJib, this.sheave, this.blockHeight, this.overhoist,
      {this.warning = overhoistWarning, this.bottomDrop});

  String get name => hookNames[hook]!;

  /// 吊掛長度的下限：吊鉤頂剛好到過捲極限。
  double get minHoist => overhoist + blockHeight;

  /// 鉤底離地高度 = 吊掛滑輪中心高度 − drop。
  double get drop => bottomDrop ?? minHoist;

  double topGap(double hoist) => hoist - blockHeight;

  /// 'over' / 'near' / ''。
  String overhoistState(double hoist) {
    final gap = topGap(hoist);
    if (gap < overhoist - overhoistEps) return 'over';
    if (gap < overhoist + warning - overhoistEps) return 'near';
    return '';
  }
}

class CraneSpec {
  final String id;
  final String name;
  final BoomLimits limits;
  final int telescopicSections;
  final double boomWidth;
  final double boomBodyOffset;
  final bool jibAvailable;
  final double jibDefaultLength;
  final double jibWidth;
  final BoomPose defaultPose;
  final VehicleBody body;
  final double hookBlockHeight;
  final double? auxHookBlockHeight;
  final double overhoist;
  final double? auxOverhoist;
  final double? jibOverhoist;
  final double tipDeflection;
  final double? bottomDrop;
  final double? auxBottomDrop;
  final double? jibBottomDrop;
  final bool pivotFixed;
  final bool limitBoomLength;
  final bool limitJibLength;
  final List<double> jibLengths;
  final List<double> jibOffsets;
  final double? hookWeight;
  final double? auxHookWeight;
  final LoadChartSet? loadCharts;
  final List<String> unverified;
  final List<List<String>> reference;
  final String note;

  const CraneSpec({
    required this.id,
    required this.name,
    required this.limits,
    this.telescopicSections = 4,
    this.boomWidth = 0.60,
    this.boomBodyOffset = 0.0,
    this.jibAvailable = true,
    this.jibDefaultLength = 8.0,
    this.jibWidth = 0.25,
    this.defaultPose = const BoomPose(),
    this.body = const VehicleBody(),
    this.hookBlockHeight = 1.0,
    this.auxHookBlockHeight,
    this.overhoist = 0.5,
    this.auxOverhoist,
    this.jibOverhoist,
    this.tipDeflection = 0.0,
    this.bottomDrop,
    this.auxBottomDrop,
    this.jibBottomDrop,
    this.pivotFixed = false,
    this.limitBoomLength = false,
    this.limitJibLength = false,
    this.jibLengths = const [],
    this.jibOffsets = const [],
    this.hookWeight,
    this.auxHookWeight,
    this.loadCharts,
    this.unverified = const [],
    this.reference = const [],
    this.note = '',
  });

  factory CraneSpec.fromJson(Map<String, dynamic> d, {String? fallbackId}) {
    final boom = (d['boom'] as Map<String, dynamic>?) ?? const {};
    final jib = (d['jib'] as Map<String, dynamic>?) ?? const {};
    final pivot = (d['pivot'] as Map<String, dynamic>?) ?? const {};
    double f(Map<String, dynamic> m, String k, double dflt) => m[k] == null ? dflt : (m[k] as num).toDouble();
    final limits = BoomLimits(
      pivotX: f(pivot, 'x', -2.20),
      pivotY: f(pivot, 'y', 3.44),
      boomMin: f(boom, 'min_length', 8.0),
      boomMax: f(boom, 'max_length', 32.0),
      angleMin: f(boom, 'min_angle', 0.0),
      angleMax: f(boom, 'max_angle', 80.0),
      jibMin: f(jib, 'min_length', 3.0),
      jibMax: f(jib, 'max_length', 10.0),
      jibOffsetMin: f(jib, 'min_offset', 0.0),
      jibOffsetMax: f(jib, 'max_offset', 60.0),
      tipOffset: f(boom, 'tip_offset', 0.0),
      auxAlong: f(boom, 'aux_sheave_along', 0.0),
      auxBelow: f(boom, 'aux_sheave_below', 0.0),
      auxRope: f(boom, 'aux_rope_offset', 0.0),
      lengthOffset: f(boom, 'length_offset', 0.0),
    );
    final dp = (d['default_pose'] as Map<String, dynamic>?) ?? const {};
    final jibDefault = f(jib, 'default_length', limits.jibMax);
    final pose = BoomPose(
      length: f(dp, 'length', limits.boomMin),
      angle: f(dp, 'angle', 60.0),
      jibEnabled: false,
      jibLength: jibDefault,
      jibOffset: f(jib, 'default_offset', limits.jibOffsetMin > 0.0 ? limits.jibOffsetMin : 0.0),
    );
    final hook = (d['hook'] as Map<String, dynamic>?) ?? const {};
    final legacy = legacyHookKeys.where(hook.containsKey).toList();
    if (legacy.isNotEmpty) {
      throw FormatException('hook 使用舊欄位 ${legacy.join('、')}（過捲極限已改為吊鉤頂至滑輪中心），'
          '請用 tools/import_crane.py 重新產生規格檔');
    }
    double? opt(String k) => hook[k] == null ? null : (hook[k] as num).toDouble();
    final charts = d['load_charts'] as Map<String, dynamic>?;
    return CraneSpec(
      id: (d['id'] ?? fallbackId ?? 'crane').toString(),
      name: (d['name'] ?? '未命名吊車').toString(),
      limits: limits,
      telescopicSections: (boom['telescopic_sections'] as num?)?.toInt() ?? 4,
      boomWidth: f(boom, 'width', 0.6),
      boomBodyOffset: f(boom, 'body_offset', 0.0),
      jibAvailable: (jib['available'] ?? true) == true,
      jibDefaultLength: jibDefault,
      jibWidth: f(jib, 'width', 0.25),
      defaultPose: pose,
      body: VehicleBody.fromJson(d['body'] as Map<String, dynamic>?),
      hookBlockHeight: f(hook, 'block_height', 1.0),
      auxHookBlockHeight: opt('aux_block_height'),
      overhoist: f(hook, 'overhoist', 0.5),
      auxOverhoist: opt('aux_overhoist'),
      jibOverhoist: opt('jib_overhoist'),
      tipDeflection: f(boom, 'tip_deflection', 0.0),
      bottomDrop: opt('bottom_drop'),
      auxBottomDrop: opt('aux_bottom_drop'),
      jibBottomDrop: opt('jib_bottom_drop'),
      pivotFixed: pivot['fixed'] == true,
      limitBoomLength: boom['limit_length'] == true,
      limitJibLength: jib['limit_length'] == true,
      jibLengths: [for (final v in (jib['lengths'] as List?) ?? const []) (v as num).toDouble()]..sort(),
      jibOffsets: [for (final v in (jib['offsets'] as List?) ?? const []) (v as num).toDouble()]..sort(),
      hookWeight: opt('weight'),
      auxHookWeight: opt('aux_weight'),
      loadCharts: charts != null && charts.isNotEmpty ? LoadChartSet.fromJson(charts) : null,
      unverified: [for (final u in (d['unverified'] as List?) ?? const []) '$u'],
      reference: [
        for (final row in (d['reference'] as List?) ?? const []) [for (final c in row as List) '$c']
      ],
      note: (d['note'] ?? '').toString(),
    );
  }

  /// 規格檔有副吊鉤資料：主臂作業時可以選主吊鉤或副吊鉤。
  bool get hasAuxHook => auxHookBlockHeight != null || auxOverhoist != null || auxHookWeight != null;

  /// 規格檔有單滑輪位置。
  bool get hasAuxSheave => limits.auxAlong != 0 || limits.auxBelow != 0 || limits.auxRope != 0;

  /// 吊鉤的過捲極限與高度。副臂作業只能用副吊鉤；空白的副吊鉤數值沿用主吊鉤。
  HookSetup hookSetup(String hook, bool onJib) {
    if (onJib || hook == auxHook) {
      final block = auxHookBlockHeight ?? hookBlockHeight;
      var over = auxOverhoist ?? overhoist;
      if (onJib && jibOverhoist != null) over = jibOverhoist!;
      final sheave = onJib ? '副臂尖滑輪' : (hasAuxSheave ? '單滑輪' : '主臂頂滑輪');
      final drop = onJib ? jibBottomDrop : auxBottomDrop;
      return HookSetup(auxHook, onJib, sheave, block, over, bottomDrop: drop);
    }
    return HookSetup(mainHook, false, '主臂頂滑輪', hookBlockHeight, overhoist, bottomDrop: bottomDrop);
  }

  /// 吊臂上所有吊鉤的重量合計 (t)。
  double get hooksWeight => [hookWeight, auxHookWeight].whereType<double>().fold(0.0, (a, b) => a + b);
}
