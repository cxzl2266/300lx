/// 「物件」頁：物件清單 + 選取物件的屬性（移植自桌面版 object_list.py、property_panel.py）。
library;

import 'package:flutter/material.dart';

import '../../core/geometry.dart' show OutOfReachError;
import '../../core/pyformat.dart';
import '../../models/crane_spec.dart' show overhoistWarning;
import '../../models/objects.dart';
import '../../models/simulation.dart';
import '../canvas/canvas_controller.dart';
import '../colors.dart' as k;
import '../widgets/color_picker.dart';
import '../widgets/common.dart';
import '../widgets/value_field.dart';

/// 各類型的數值欄位：(屬性, 標籤, 最小值, 說明)
final Map<String, List<(String, String, double?, String?)>> numericFields = {
  'rect': [
    ('x', '距離 (m)', null, null),
    ('y', '底部高程 (m)', null, null),
    ('width', '寬度 (m)', 0.1, null),
    ('height', '高度 (m)', 0.1, null),
  ],
  'load': [
    ('width', '寬度 (m)', 0.1, null),
    ('height', '高度 (m)', 0.1, null),
    ('weight', '重量 (t)', 0.0, null),
    ('hoist', '吊掛長度 (m)', LoadObject.minHoistAbs, _hoistTip),
    ('sling', '吊索長度 (m)', 0.0, '掛鉤到吊物頂部的垂直距離（吊索）'),
  ],
  'wire': [
    ('x1', '起點 X (m)', null, null),
    ('y1', '起點 Y (m)', null, null),
    ('x2', '終點 X (m)', null, null),
    ('y2', '終點 Y (m)', null, null),
  ],
  'ground': [
    ('x1', '起點 X (m)', null, null),
    ('x2', '終點 X (m)', null, null),
    ('elevation', '高程 (m)', null, null),
  ],
  'text': [
    ('x', 'X (m)', null, null),
    ('y', 'Y (m)', null, null),
    ('size', '字高 (m)', 0.05, null),
  ],
  'dimension': [
    ('x1', '起點 X (m)', null, null),
    ('y1', '起點 Y (m)', null, null),
    ('x2', '終點 X (m)', null, null),
    ('y2', '終點 Y (m)', null, null),
  ],
  'image': [
    ('x', '左下 X (m)', null, null),
    ('y', '左下 Y (m)', null, null),
    ('width', '寬度 (m)', 0.1, null),
    ('height', '高度 (m)', 0.1, null),
  ],
  'truck': [
    ('x', '左端距離 (m)', null, '車輛左端到迴轉中心的水平距離'),
    ('y', '地面高程 (m)', null, '輪胎接地處的高程（放在樓板或坑洞時修改）'),
    ('cab_length', '車頭長 (m)', 3.0, '曳引車（車頭）全長'),
    ('cab_height', '車頭高 (m)', 1.5, '車頭最高點離地高度'),
    ('trailer_length', '拖車長 (m)', 3.0, '拖車（板台）全長'),
    ('deck_height', '板台高 (m)', 0.8, '拖車板台離地高度＝貨櫃底部高度'),
    ('width', '車寬 (m)', 1.5, '車尾方向時圖面上的寬度'),
  ],
};

final String _hoistTip = '臂端（滑輪中心）到掛鉤（鉤底）的距離，含吊鉤高度。最少 ${g(LoadObject.minHoistAbs)} m；\n'
    '吊鉤頂距滑輪小於過捲極限 + ${fixed(overhoistWarning, 2)} m 顯示「接近過捲」，小於過捲極限顯示「超過過捲極限」';

const Set<String> fillKinds = {'rect', 'polygon', 'load', 'ground', 'wire', 'truck'};

/// 聯結車的下拉選單：(屬性, 標籤, 選項, 復原說明)
final List<(String, String, Map<String, String>, String)> truckCombos = [
  ('view', '擺放方向', truckViews, '修改擺放方向'),
  ('facing', '車頭朝向', truckFacings, '修改車頭朝向'),
  ('container', '貨櫃', {for (final e in containerSizes.entries) e.key: e.value.$1}, '修改貨櫃規格'),
  ('container_type', '櫃型', {for (final e in containerTypes.entries) e.key: e.value.$1}, '修改櫃型'),
];

class ObjectPanel extends StatelessWidget {
  final SimulationModel model;
  final CanvasController canvas;
  final void Function(String) onMessage;
  final VoidCallback onCopy, onCut, onPaste;
  final bool canPaste;
  final VoidCallback onAddImage;
  final void Function(String oid) onChooseImage;
  final void Function(String oid) onCalibrate;

  const ObjectPanel({
    super.key,
    required this.model,
    required this.canvas,
    required this.onMessage,
    required this.onCopy,
    required this.onCut,
    required this.onPaste,
    required this.canPaste,
    required this.onAddImage,
    required this.onChooseImage,
    required this.onCalibrate,
  });

  List<String> get ids => canvas.selection;

  @override
  Widget build(BuildContext context) {
    final sel = ids;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SizedBox(height: 8),
      Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
        PopupMenuButton<String>(
          tooltip: '新增物件',
          onSelected: (kind) => kind == 'image' ? onAddImage() : canvas.addKind(kind),
          itemBuilder: (_) => [for (final (kind, text) in objectMenu) PopupMenuItem(value: kind, child: Text(text))],
          child: const Chip(
            avatar: Icon(Icons.add, size: 18, color: Colors.white),
            label: Text('新增物件', style: TextStyle(color: Colors.white)),
            backgroundColor: k.sectionBlue,
          ),
        ),
        FilterChip(
          label: const Text('多選'),
          selected: canvas.multiSelect,
          onSelected: (v) => canvas.setOption(() => canvas.multiSelect = v),
        ),
        ActionChip(
          label: const Text('全選'),
          onPressed: () => canvas.selectIds([for (final o in model.objects()) if (o.visible) o.id]),
        ),
        if (canPaste) ActionChip(avatar: const Icon(Icons.content_paste, size: 16), label: const Text('貼上'), onPressed: onPaste),
      ]),
      if (sel.isNotEmpty) ...[
        const SizedBox(height: 6),
        Wrap(spacing: 8, runSpacing: 6, children: [
          ActionChip(avatar: const Icon(Icons.copy, size: 16), label: const Text('複製'), onPressed: onCopy),
          ActionChip(avatar: const Icon(Icons.content_cut, size: 16), label: const Text('剪下'), onPressed: onCut),
          ActionChip(
            avatar: const Icon(Icons.delete_outline, size: 16, color: k.errorText),
            label: const Text('刪除', style: TextStyle(color: k.errorText)),
            onPressed: () => model.removeObjects(sel),
          ),
          ActionChip(label: const Text('取消選取'), onPressed: () => canvas.selectIds(const [])),
        ]),
      ],
      const SectionTitle('物件清單'),
      _ObjectList(model: model, canvas: canvas),
      if (sel.length > 1) ..._multi(context),
      if (sel.length == 1 && model.get(sel.first) != null)
        _Properties(
          key: ValueKey('${sel.first}:${model.get(sel.first)!.kind}'),
          model: model,
          oid: sel.first,
          onMessage: onMessage,
          onChooseImage: onChooseImage,
          onCalibrate: onCalibrate,
        ),
      if (sel.isEmpty)
        const Padding(
          padding: EdgeInsets.only(top: 12),
          child: Text('尚未選取物件。在圖面點選物件，或點清單中的名稱；用「新增物件」加入障礙物、吊物等。',
              style: TextStyle(color: k.textHint)),
        ),
      const SizedBox(height: 16),
    ]);
  }

  List<Widget> _multi(BuildContext context) => [
        SectionTitle('已選取 ${ids.length} 個物件'),
        Wrap(spacing: 8, runSpacing: 6, children: [
          for (final (text, fields) in [
            ('全部鎖定', {'locked': true}),
            ('全部解鎖', {'locked': false}),
            ('全部顯示', {'visible': true}),
          ])
            OutlinedButton(onPressed: () => model.updateObjects(ids, fields, text), child: Text(text)),
        ]),
      ];
}

// ====================================================================== 物件清單
class _ObjectList extends StatelessWidget {
  final SimulationModel model;
  final CanvasController canvas;

  const _ObjectList({required this.model, required this.canvas});

  @override
  Widget build(BuildContext context) {
    final objs = model.objects().reversed.toList(); // 上方 = 最上層
    if (objs.isEmpty) return const Text('（沒有物件）', style: TextStyle(color: k.textHint));
    return Column(children: [
      for (final o in objs)
        Material(
          color: canvas.selection.contains(o.id) ? const Color(0xffdcebf9) : Colors.transparent,
          child: InkWell(
            onTap: () => canvas.multiSelect
                ? canvas.selectIds(canvas.selection.contains(o.id)
                    ? [for (final i in canvas.selection) if (i != o.id) i]
                    : [...canvas.selection, o.id])
                : canvas.selectIds([o.id], center: true),
            onLongPress: () async {
              final name = await askString(context, '重新命名', initial: o.name);
              if (name != null && name.trim().isNotEmpty && name.trim() != o.name) {
                model.updateObject(o.id, {'name': name.trim()}, '重新命名');
              }
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(children: [
                Checkbox(
                  value: o.visible,
                  visualDensity: VisualDensity.compact,
                  onChanged: (v) => model.updateObject(o.id, {'visible': v == true}, v == true ? '顯示' : '隱藏'),
                ),
                _Swatch(o),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    o.name.isEmpty ? o.label : o.name,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: o.locked ? const Color(0xff868e96) : k.text,
                      fontStyle: o.locked ? FontStyle.italic : FontStyle.normal,
                    ),
                  ),
                ),
                Text(o.label, style: const TextStyle(color: k.textHint, fontSize: 11)),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: o.locked ? '解鎖' : '鎖定',
                  icon: Icon(o.locked ? Icons.lock : Icons.lock_open, size: 18, color: k.textHint),
                  onPressed: () => model.updateObject(o.id, {'locked': !o.locked}, o.locked ? '解鎖' : '鎖定'),
                ),
              ]),
            ),
          ),
        ),
    ]);
  }
}

class _Swatch extends StatelessWidget {
  final SceneObject o;

  const _Swatch(this.o);

  @override
  Widget build(BuildContext context) {
    final line = o.kind == 'wire' || o.kind == 'dimension';
    final color = k.hex(['text', 'dimension', 'wire'].contains(o.kind) ? o.stroke : o.fill);
    return Container(
      width: 16,
      height: line ? 5 : 16,
      decoration: BoxDecoration(
        color: color,
        border: Border.all(color: k.hex(o.stroke)),
        borderRadius: BorderRadius.circular(line ? 1 : 3),
      ),
    );
  }
}

// ====================================================================== 屬性
class _Properties extends StatefulWidget {
  final SimulationModel model;
  final String oid;
  final void Function(String) onMessage;
  final void Function(String oid) onChooseImage;
  final void Function(String oid) onCalibrate;

  const _Properties({
    super.key,
    required this.model,
    required this.oid,
    required this.onMessage,
    required this.onChooseImage,
    required this.onCalibrate,
  });

  @override
  State<_Properties> createState() => _PropertiesState();
}

class _PropertiesState extends State<_Properties> {
  final _name = TextEditingController();
  final _nameFocus = FocusNode();
  final _text = TextEditingController();
  final _textFocus = FocusNode();
  double? _opacityDrag;

  SimulationModel get m => widget.model;
  SceneObject? get o => m.get(widget.oid);

  @override
  void initState() {
    super.initState();
    _nameFocus.addListener(() {
      if (!_nameFocus.hasFocus) _commitName();
    });
    _textFocus.addListener(() {
      if (!_textFocus.hasFocus) _commitText();
    });
  }

  @override
  void dispose() {
    _name.dispose();
    _nameFocus.dispose();
    _text.dispose();
    _textFocus.dispose();
    super.dispose();
  }

  void _commitName() {
    final ob = o;
    final t = _name.text.trim();
    if (ob != null && t.isNotEmpty && t != ob.name) m.updateObject(ob.id, {'name': t}, '重新命名');
  }

  void _commitText() {
    final ob = o;
    if (ob is TextObject && _text.text != ob.text) m.updateObject(ob.id, {'text': _text.text}, '修改文字');
  }

  void _set(String key, Object? value, [String text = '修改屬性']) => m.updateObject(widget.oid, {key: value}, text);

  @override
  Widget build(BuildContext context) {
    final ob = o;
    if (ob == null) return const SizedBox.shrink();
    if (!_nameFocus.hasFocus && _name.text != ob.name) _name.text = ob.name;
    if (ob is TextObject && !_textFocus.hasFocus && _text.text != ob.text) _text.text = ob.text;

    final children = <Widget>[
      SectionTitle('屬性：${ob.label}'),
      Lines(_statusLines(ob), size: 12.5),
      const SizedBox(height: 6),
      TextField(
        controller: _name,
        focusNode: _nameFocus,
        decoration: const InputDecoration(labelText: '名稱', isDense: true),
        onSubmitted: (_) => _commitName(),
      ),
      const SizedBox(height: 10),
    ];

    if (ob is TextObject) {
      children.addAll([
        TextField(
          controller: _text,
          focusNode: _textFocus,
          minLines: 2,
          maxLines: 5,
          decoration: const InputDecoration(labelText: '內容（離開欄位即套用）', isDense: true),
        ),
        const SizedBox(height: 10),
      ]);
    }
    if (ob is ImageObject) {
      children.add(Wrap(spacing: 8, children: [
        OutlinedButton.icon(
            onPressed: () => widget.onChooseImage(ob.id),
            icon: const Icon(Icons.image_outlined, size: 18),
            label: const Text('更換圖檔')),
        OutlinedButton.icon(
            onPressed: () => widget.onCalibrate(ob.id),
            icon: const Icon(Icons.straighten, size: 18),
            label: const Text('比例校正')),
      ]));
      children.add(const Padding(
        padding: EdgeInsets.only(top: 4, bottom: 8),
        child: Text('比例校正：在圖上點兩個已知距離的點，再輸入實際距離', style: TextStyle(color: k.textHint, fontSize: 12)),
      ));
    }
    if (ob is TruckObject) {
      for (final (key, label, options, text) in truckCombos) {
        final value = ob.toJson()[key] as String;
        final enabled = key == 'facing' ? ob.view == 'side' : (key == 'container_type' ? ob.container != 'none' : true);
        children.add(Row(children: [
          SizedBox(width: 80, child: Text(label)),
          Expanded(
            child: DropdownButton<String>(
              isExpanded: true,
              value: value,
              items: [for (final e in options.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
              onChanged: enabled ? (v) => v != null && v != value ? _set(key, v, text) : null : null,
            ),
          ),
        ]));
      }
      children.add(const SizedBox(height: 8));
    }

    final fields = numericFields[ob.kind] ?? const [];
    if (fields.isNotEmpty) {
      children.add(FieldGrid(children: [
        for (final (key, label, minimum, tip) in fields)
          ValueField(
            title: label,
            unit: '',
            decimals: 2,
            compact: true,
            getter: () => ((m.get(widget.oid)?.toJson()[key] as num?) ?? double.nan).toDouble(),
            setter: (v) {
              if (minimum != null && v < minimum) throw OutOfReachError('不可小於 ${g(minimum)}');
              _set(key, v);
            },
            help: tip,
            onError: widget.onMessage,
          ),
      ]));
      children.add(const SizedBox(height: 8));
    }

    if (ob is DimensionObject) {
      children.add(Row(children: [
        const SizedBox(width: 80, child: Text('顯示')),
        Expanded(
          child: DropdownButton<String>(
            isExpanded: true,
            value: ob.mode,
            items: [for (final e in dimModes.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
            onChanged: (v) => v != null && v != ob.mode ? _set('mode', v, '修改標註格式') : null,
          ),
        ),
      ]));
    }
    if (ob is PolygonObject) children.add(_PointsTable(model: m, oid: ob.id, onMessage: widget.onMessage));

    // 外觀
    children.add(const SectionTitle('外觀'));
    final colorRows = <(String, String)>[];
    if (fillKinds.contains(ob.kind)) {
      colorRows.add(('fill', ob is WireObject ? '安全帶顏色' : (ob is TruckObject ? '車頭顏色' : '填色')));
    }
    if (ob is TruckObject) colorRows.add(('container_fill', '貨櫃顏色'));
    if (ob is! ImageObject) {
      colorRows.add((
        'stroke',
        ob is TextObject ? '文字顏色' : (ob is WireObject || ob is DimensionObject ? '線條顏色' : '邊框色')
      ));
    }
    for (final (key, label) in colorRows) {
      final value = ob.toJson()[key] as String;
      children.add(Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(children: [
          SizedBox(width: 80, child: Text(label)),
          Expanded(
            child: GestureDetector(
              onTap: () async {
                final c = await pickColor(context, value);
                if (c != null && c != value) _set(key, c, '修改顏色');
              },
              child: Container(
                height: 30,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: k.hex(value),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: const Color(0xff868e96)),
                ),
                child: Text(value,
                    style: TextStyle(color: k.lightness(k.hex(value)) < 140 ? Colors.white : k.text, fontSize: 13)),
              ),
            ),
          ),
        ]),
      ));
    }
    final op = _opacityDrag ?? ob.opacity;
    children.add(Row(children: [
      const SizedBox(width: 80, child: Text('透明度')),
      Expanded(
        child: Slider(
          min: 0.05,
          max: 1.0,
          divisions: 95,
          value: op.clamp(0.05, 1.0),
          onChanged: (v) => setState(() => _opacityDrag = v),
          onChangeEnd: (v) {
            setState(() => _opacityDrag = null);
            final r = (v * 100).round() / 100;
            if ((r - ob.opacity).abs() > 1e-6) _set('opacity', r, '修改透明度');
          },
        ),
      ),
      SizedBox(width: 44, child: Text('${(op * 100).round()}%')),
    ]));
    children.add(Wrap(spacing: 12, children: [
      _check('顯示', ob.visible, (v) => _set('visible', v)),
      _check('鎖定（不可拖動）', ob.locked, (v) => _set('locked', v)),
    ]));

    // 碰撞
    if (ob.collidable) {
      children.addAll([
        const SectionTitle('碰撞檢查'),
        _check('參與碰撞檢查', ob.collision, (v) => _set('collision', v)),
        const SizedBox(height: 4),
        SizedBox(
          width: 200,
          child: ValueField(
            title: '安全間距 (m)',
            unit: '',
            decimals: 2,
            compact: true,
            getter: () => m.get(widget.oid)?.margin ?? double.nan,
            setter: (v) {
              if (v < 0) throw OutOfReachError('不可小於 0');
              _set('margin', v, '修改安全間距');
            },
            onError: widget.onMessage,
          ),
        ),
      ]);
    }

    // 圖層
    children.addAll([
      const SectionTitle('圖層'),
      Wrap(spacing: 8, runSpacing: 6, children: [
        for (final (text, where) in [('移到最上層', 'top'), ('上移一層', 'up'), ('下移一層', 'down'), ('移到最下層', 'bottom')])
          OutlinedButton(onPressed: () => m.moveLayer(widget.oid, where), child: Text(text)),
      ]),
    ]);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
  }

  Widget _check(String label, bool value, void Function(bool) onChanged) => Row(mainAxisSize: MainAxisSize.min, children: [
        Checkbox(value: value, onChanged: (v) => onChanged(v == true)),
        GestureDetector(onTap: () => onChanged(!value), child: Text(label)),
      ]);

  List<Line> _statusLines(SceneObject ob) {
    final rep = m.safety();
    const colors = {
      'collision': Color(0xffc0282e),
      'warning': Color(0xffd9480f),
      'info': Color(0xff56616d),
      'ok': Color(0xff2b8a3e)
    };
    final st = rep.status[ob.id] ?? 'none';
    final label = rep.labels[ob.id] ?? '';
    final stColor = colors[st] ?? k.textMuted;
    final lines = <Line>[];
    if (ob is LoadObject) {
      final tip = m.riggingTip();
      final pts = m.loadOutline(ob);
      final hook = ob.hookAt(tip);
      final ang = ob.slingAngle();
      final hk = m.hookSetup;
      var gap = '${hk.name}頂距${hk.sheave} ${fixed(hk.topGap(ob.hoist), 2)} m';
      var gapColor = k.text;
      switch (hk.overhoistState(ob.hoist)) {
        case 'over':
          gap = '**$gap（超過過捲極限）**';
          gapColor = const Color(0xffc0282e);
        case 'near':
          gap = '**$gap（接近過捲）**';
          gapColor = const Color(0xffd9480f);
      }
      if (label.isNotEmpty) lines.add(('**$label**', stColor));
      lines.addAll([
        ('臂端 →**吊掛**→ 掛鉤 →**吊索**→ 吊物', k.text),
        ('掛鉤高程 ${fixed(hook.y, 2)} m｜吊物頂 ${fixed(pts[2].y, 2)} m｜吊物底 ${fixed(pts[0].y, 2)} m', k.text),
        ('使用${hk.name}（掛在${hk.sheave}，高度 ${fixed(hk.blockHeight, 3)} m）', k.text),
        (gap, gapColor),
        ('過捲極限 ${fixed(hk.overhoist, 3)} m（原廠）｜提早警告 ${fixed(hk.overhoist + hk.warning, 3)} m', k.textHint),
        (
          '吊索實長 ${fixed(ob.slingLegLength(), 2)} m × 2，吊索角度 ${fixed(ang, 1)}°${ang < 45 ? '（角度過小，吊索張力大增）' : ''}',
          ang < 45 ? const Color(0xffc0282e) : const Color(0xff2b8a3e)
        ),
        ('在圖面上下拖曳吊物可調整吊掛長度', k.textHint),
      ]);
    } else if (ob.activeCollision) {
      if (label.isNotEmpty) lines.add(('**$label**（安全間距 ${fixed(ob.margin, 1)} m）', stColor));
    } else if (ob.collidable) {
      lines.add(('未參與碰撞檢查', k.text));
    } else if (ob is GroundObject) {
      lines.add(('地面高程一律納入地面檢查：吊物可以放進坑洞或放上樓板，但不能低於這裡的地面。', k.textMuted));
    } else if (ob is DimensionObject) {
      lines.add(('標註值 ${fixed(ob.value(), 2)} m', k.text));
    }
    if (ob is TruckObject) {
      var dims = '全長 ${fixed(ob.totalLength, 2)} m｜最高 ${fixed(ob.y + ob.topHeight, 2)} m｜'
          '板台 ${fixed(ob.y + ob.deckHeight, 2)} m';
      if (ob.containerHeight > 0) dims += '｜貨櫃頂 ${fixed(ob.y + ob.deckHeight + ob.containerHeight, 2)} m';
      lines.add((dims, k.text));
      lines.add(('車頂（貨櫃頂、板台、車頭）可放置吊物；吊臂、鋼索、吊鉤、吊索碰到車仍算碰撞', k.textHint));
    }
    return lines;
  }
}

// ====================================================================== 多邊形頂點
class _PointsTable extends StatelessWidget {
  final SimulationModel model;
  final String oid;
  final void Function(String) onMessage;

  const _PointsTable({required this.model, required this.oid, required this.onMessage});

  @override
  Widget build(BuildContext context) {
    final o = model.get(oid);
    if (o is! PolygonObject) return const SizedBox.shrink();
    final pts = o.points;
    List<List<double>> copy() => [for (final p in (model.get(oid) as PolygonObject).points) List<double>.of(p)];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SectionTitle('頂點座標 (m)'),
      for (var i = 0; i < pts.length; i++)
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            SizedBox(width: 22, child: Text('${i + 1}', style: const TextStyle(color: k.textHint))),
            for (final c in [0, 1])
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: ValueField(
                    title: c == 0 ? 'X' : 'Y',
                    unit: '',
                    decimals: 2,
                    compact: true,
                    getter: () {
                      final p = model.get(oid);
                      return p is PolygonObject && i < p.points.length ? p.points[i][c] : double.nan;
                    },
                    setter: (v) {
                      final ps = copy();
                      ps[i][c] = v;
                      model.updateObject(oid, {'points': ps}, '修改頂點');
                    },
                    onError: onMessage,
                  ),
                ),
              ),
            IconButton(
              tooltip: '在此點後插入頂點',
              icon: const Icon(Icons.add_circle_outline, size: 20),
              onPressed: () {
                final ps = copy();
                final a = ps[i], b = ps[(i + 1) % ps.length];
                ps.insert(i + 1, [(a[0] + b[0]) / 2, (a[1] + b[1]) / 2]);
                model.updateObject(oid, {'points': ps}, '新增頂點');
              },
            ),
            IconButton(
              tooltip: '刪除頂點',
              icon: const Icon(Icons.remove_circle_outline, size: 20),
              onPressed: pts.length <= 3
                  ? null
                  : () {
                      final ps = copy()..removeAt(i);
                      model.updateObject(oid, {'points': ps}, '刪除頂點');
                    },
            ),
          ]),
        ),
    ]);
  }
}
