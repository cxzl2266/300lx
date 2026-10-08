/// 主畫面（移植自桌面版 main_window.py，改成手機版面）。
///
/// 直式手機：上方圖面、中間摘要列、下方分頁面板（可拖曳調整高度）。
/// 橫式 / 平板 / 電腦：左邊圖面、右邊面板。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../core/geometry.dart' show OutOfReachError, Pt;
import '../core/pyformat.dart';
import '../models/objects.dart';
import '../models/simulation.dart';
import '../platform/web_io.dart' as io;
import 'canvas/canvas_controller.dart';
import 'canvas/crane_canvas.dart';
import 'canvas/scene_images.dart';
import 'colors.dart' as k;
import 'panels/body_panel.dart';
import 'panels/boom_panel.dart';
import 'panels/load_panel.dart';
import 'panels/object_panel.dart';
import 'project_store.dart' as store;
import 'selftest_page.dart';
import 'widgets/common.dart';

const appName = '吊車作業模擬';
const appVersion = '1.0.0';

class HomePage extends StatefulWidget {
  final SimulationModel model;
  final Map<String, dynamic> specJson;

  const HomePage({super.key, required this.model, required this.specJson});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late final CanvasController canvas;
  final images = SceneImages();
  int _tab = 0;
  double _panelFrac = 0.42; // 直式：面板佔可用高度的比例
  List<Map<String, Object?>>? _clipboard;
  int _pasteCount = 0;
  Timer? _saveTimer;
  bool _saveWarned = false;

  SimulationModel get model => widget.model;

  @override
  void initState() {
    super.initState();
    canvas = CanvasController(model)
      ..onMessage = _message
      ..askText = (() => askString(context, '文字註記', label: '內容', initial: '註記', multiline: true))
      ..onCalibrationPicked = _onCalibration;
    _loadPrefs();
    model.addListener(_scheduleSave);
    canvas.addListener(_savePrefsSoon);
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    model.removeListener(_scheduleSave);
    canvas.removeListener(_savePrefsSoon);
    canvas.dispose();
    images.dispose();
    super.dispose();
  }

  // ================================================================ 保存
  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 800), _autosave);
  }

  void _autosave() {
    if (model.dragging || model.editing) {
      _scheduleSave();
      return;
    }
    final ok = store.saveAutosave(model.toProject());
    if (!ok && !_saveWarned) {
      _saveWarned = true;
      _message('手機瀏覽器的儲存空間不足（可能是背景圖太大），目前圖面沒有自動保存；請用「匯出專案檔」備份。');
    } else if (ok) {
      _saveWarned = false;
    }
    images.retain({for (final o in model.objects()) if (o is ImageObject) o.path});
  }

  Map<String, Object?> _prefs() => {
        'crosshair': canvas.showCrosshair,
        'body_dims': canvas.showBodyDims,
        'snap_step': canvas.snapStep,
        'snap_on': canvas.snapOn,
        'free_tip': canvas.freeTipDrag,
        'panel': _panelFrac,
        'tab': _tab,
      };

  String _lastPrefs = '';

  void _savePrefsSoon() {
    final p = jsonEncode(_prefs());
    if (p == _lastPrefs) return;
    _lastPrefs = p;
    store.savePrefs(_prefs());
  }

  void _loadPrefs() {
    final p = store.loadPrefs();
    canvas.showCrosshair = p['crosshair'] as bool? ?? true;
    canvas.showBodyDims = p['body_dims'] as bool? ?? true;
    canvas.snapStep = (p['snap_step'] as num?)?.toDouble() ?? 0.5;
    canvas.snapOn = p['snap_on'] as bool? ?? true;
    canvas.freeTipDrag = p['free_tip'] as bool? ?? false;
    _panelFrac = ((p['panel'] as num?)?.toDouble() ?? 0.42).clamp(0.12, 0.85);
    _tab = ((p['tab'] as num?)?.toInt() ?? 0).clamp(0, 3);
  }

  // ================================================================ 訊息
  void _message(String msg) {
    if (!mounted) return;
    final sm = ScaffoldMessenger.of(context);
    sm.hideCurrentSnackBar();
    sm.showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 5), showCloseIcon: true));
  }

  void _guard(void Function() fn) {
    try {
      fn();
    } on OutOfReachError catch (e) {
      _message(e.message);
    }
  }

  // ================================================================ 專案
  Future<void> _newProject() async {
    if (model.undoStack.canUndo &&
        !await confirm(context, '開新專案', '目前的圖面會被清除（無法復原），確定嗎？\n（需要的話請先「儲存專案」）')) {
      return;
    }
    canvas.setMode('select');
    canvas.selectIds(const []);
    model.reset();
    canvas.resetView();
  }

  void _openProjectData(Map<String, Object?> data) {
    final err = store.checkProject(data, model.spec.id);
    if (err != null) {
      _message(err);
      return;
    }
    try {
      canvas.setMode('select');
      canvas.selectIds(const []);
      model.loadProject(data);
      canvas.resetView();
    } catch (e) {
      _message('專案檔內容有誤，無法開啟：$e');
    }
  }

  Future<void> _myProjects() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => _ProjectsSheet(
        onSave: (name) {
          final ok = store.saveProject(name, model.toProject());
          _message(ok ? '已儲存「$name」' : '手機瀏覽器的儲存空間不足，無法儲存（可能是背景圖太大）；請改用「匯出專案檔」。');
        },
        onOpen: (p) async {
          if (model.undoStack.canUndo &&
              !await confirm(context, '開啟專案', '目前的圖面會被「${p.name}」取代（無法復原），確定嗎？')) {
            return;
          }
          _openProjectData(p.data);
          _message('已開啟「${p.name}」');
        },
      ),
    );
  }

  void _exportProject() {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final name = '吊車專案_${now.year}${two(now.month)}${two(now.day)}_${two(now.hour)}${two(now.minute)}.json';
    io.downloadText(name, const JsonEncoder.withIndent(' ').convert(model.toProject()));
    _message('已匯出「$name」（iPhone：在預覽畫面按分享 →「儲存到檔案」）');
  }

  Future<void> _importProject() async {
    final f = await io.pickFile('.json,application/json,text/plain');
    if (f == null) return;
    Map<String, Object?> data;
    try {
      data = jsonDecode(utf8.decode(f.$3)) as Map<String, Object?>;
    } catch (_) {
      _message('「${f.$1}」不是有效的專案檔');
      return;
    }
    if (!mounted) return;
    if (model.undoStack.canUndo && !await confirm(context, '匯入專案', '目前的圖面會被「${f.$1}」取代（無法復原），確定嗎？')) {
      return;
    }
    _openProjectData(data);
  }

  // ================================================================ 背景圖
  /// 選擇圖檔：(檔名, data URL, 高 ÷ 寬)；取消或無法讀取時為 null。
  Future<(String, String, double)?> _pickImage() async {
    final f = await io.pickFile('image/*');
    if (f == null) return null;
    final (name, mime, bytes) = f;
    try {
      final url = await io.imageToDataUrl(bytes, mime.isEmpty ? 'image/png' : mime, 2000);
      final size = await SceneImages.sizeOf(UriData.parse(url).contentAsBytes());
      if (size != null && size.$1 > 0) return (name, url, size.$2 / size.$1);
    } catch (_) {}
    _message('無法讀取這個圖檔');
    return null;
  }

  Future<void> _addImage() async {
    final r = await _pickImage();
    if (r == null) return;
    final (name, url, aspect) = r;
    const w = 30.0;
    final obj = ImageObject.fromJson({'path': url, 'name': name, 'x': -6.0, 'y': 0.0, 'width': w, 'height': w * aspect});
    model.addObject(obj, index: 0); // 背景圖放最下層
    canvas.selectIds([obj.id]);
    setState(() => _tab = 2);
    _message('已匯入背景圖。建議接著按「比例校正」。');
  }

  Future<void> _chooseImageFor(String oid) async {
    final r = await _pickImage();
    final o = model.get(oid);
    if (r == null || o is! ImageObject) return;
    model.updateObject(oid, {'path': r.$2, 'height': o.width * r.$3}, '更換背景圖');
  }

  void _startCalibration(String oid) {
    canvas.setMode('calibrate', target: oid);
  }

  Future<void> _onCalibration(String oid, Pt a, Pt b) async {
    final o = model.get(oid);
    if (o is! ImageObject) return;
    final measured = dist(a, b);
    if (measured <= 1e-6) return;
    final real = await askNumber(
        context, '比例校正', '圖上兩點目前相距 ${fixed(measured, 2)} m。\n實際距離是多少公尺？', pyRound(measured, 2));
    if (real != null) model.updateObject(oid, o.calibrated(a, b, real), '比例校正');
  }

  // ================================================================ 剪貼簿
  void _copy() {
    final ids = canvas.selectedIds();
    if (ids.isEmpty) return;
    setState(() {
      _clipboard = model.exportObjects(ids);
      _pasteCount = 0;
    });
    _message('已複製 ${ids.length} 個物件');
  }

  void _cut() {
    final ids = canvas.selectedIds();
    _copy();
    model.removeObjects(ids);
  }

  void _paste() {
    final dicts = _clipboard;
    if (dicts == null) return;
    _pasteCount += 1;
    final hadLoad = model.hasLoad();
    final ids = model.pasteObjects(dicts, 1.0 * _pasteCount, 0.0);
    canvas.selectIds(ids);
    final loadsInClip = dicts.where((d) => d['kind'] == 'load').length;
    final loadsPasted = ids.where((i) => model.get(i) is LoadObject).length;
    if (loadsInClip > loadsPasted) {
      final why = hadLoad ? '已有吊物' : '吊物只能有一個';
      _message(ids.isNotEmpty ? '$why，吊物未貼上（其他物件已貼上）' : '$why，吊物未貼上');
    }
  }

  // ================================================================ 對話框
  Future<void> _history() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => AnimatedBuilder(
        animation: model,
        builder: (ctx, _) {
          final texts = model.undoStack.texts;
          final idx = model.undoStack.index;
          return ListView(children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text('操作紀錄（點一下回到那一步）', style: TextStyle(fontWeight: FontWeight.w700)),
            ),
            for (var i = 0; i <= texts.length; i++)
              ListTile(
                dense: true,
                selected: i == idx,
                leading: Icon(i == idx ? Icons.arrow_right : null),
                title: Text(i == 0 ? '（開始）' : texts[i - 1],
                    style: TextStyle(color: i > idx ? k.textHint : null)),
                onTap: () => model.undoStack.setIndex(i),
              ),
          ]);
        },
      ),
    );
  }

  void _about() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text(appName),
        content: const SingleChildScrollView(
          child: Text('版本 $appVersion（手機網頁版）\n\n'
              '離線 2D 吊車作業模擬：計算半徑、鉤底離地高度、額定荷重與吊臂淨空。'
              '計算核心與電腦版相同（可用選單的「自我檢查」在手機上逐筆比對）。\n\n'
              '僅供規劃參考。吊重表數據必須來自原廠操作手冊；實際吊掛仍以吊車荷重計（LMI）與合格人員判斷為準。\n\n'
              '資料只存在這支手機的瀏覽器裡；換手機或清除瀏覽器資料前，請先「匯出專案檔」。\n\n'
              '中文字型：Noto Sans TC（SIL Open Font License 1.1）。'),
        ),
        actions: [
          TextButton(
              onPressed: () => showLicensePage(context: ctx, applicationName: appName, applicationVersion: appVersion),
              child: const Text('授權')),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('關閉')),
        ],
      ),
    );
  }

  void _help() {
    showInfo(
        context,
        '操作說明',
        '圖面\n'
            '• 拖曳主臂：改臂角（臂長不變）\n'
            '• 拖曳臂端紅點：改臂長（工具列「自由」開啟時同時改臂長與臂角）\n'
            '• 拖曳助臂尖紅點：改助臂長度與角度\n'
            '• 半徑接近荷重表的表列半徑時會吸附（選單可關閉吸附）\n'
            '• 單指拖曳空白處：平移；雙指：縮放與平移\n'
            '• 點物件選取；拖曳物件移動；拖曳白色方塊改形狀\n'
            '• 上下拖曳吊物：調整吊掛長度（往上停在過捲極限、往下停在著地）\n\n'
            '欄位\n'
            '• 點數值輸入，按鍵盤「完成」套用；−／＋ 微調，長按連續調整\n'
            '• 標題旁的 ⓘ 可看說明\n\n'
            '專案\n'
            '• 圖面會自動保存在這支手機；「我的專案」可命名保存多個\n'
            '• 「匯出專案檔」可備份或傳到其他手機、電腦版');
  }

  // ================================================================ 版面
  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([model, canvas]),
      builder: (context, _) {
        final size = MediaQuery.sizeOf(context);
        final wide = size.width >= 760 && size.width > size.height;
        return Scaffold(
          appBar: _appBar(wide),
          body: SafeArea(top: false, child: wide ? _wideLayout() : _narrowLayout()),
        );
      },
    );
  }

  PreferredSizeWidget _appBar(bool wide) {
    final st = model.undoStack;
    return AppBar(
      titleSpacing: 12,
      toolbarHeight: 52,
      title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text(appName, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
        Text('${model.spec.name}｜僅供規劃參考',
            style: const TextStyle(fontSize: 11, color: k.noteBrown), overflow: TextOverflow.ellipsis),
      ]),
      actions: [
        IconButton(
          tooltip: st.canUndo ? '復原：${st.undoText}' : '復原',
          onPressed: st.canUndo ? st.undo : null,
          icon: const Icon(Icons.undo),
        ),
        IconButton(
          tooltip: st.canRedo ? '重做：${st.redoText}' : '重做',
          onPressed: st.canRedo ? st.redo : null,
          icon: const Icon(Icons.redo),
        ),
        _menu(),
      ],
    );
  }

  Widget _menu() {
    PopupMenuItem<VoidCallback> item(String text, IconData icon, VoidCallback fn) =>
        PopupMenuItem(value: fn, child: ListTile(dense: true, leading: Icon(icon), title: Text(text)));
    CheckedPopupMenuItem<VoidCallback> check(String text, bool on, VoidCallback fn) =>
        CheckedPopupMenuItem(value: fn, checked: on, child: Text(text));
    return PopupMenuButton<VoidCallback>(
      tooltip: '選單',
      icon: const Icon(Icons.more_vert),
      onSelected: (fn) => fn(),
      itemBuilder: (_) => [
        item('開新專案', Icons.note_add_outlined, _newProject),
        item('我的專案（儲存／開啟）', Icons.folder_outlined, _myProjects),
        item('匯出專案檔', Icons.ios_share, _exportProject),
        item('匯入專案檔', Icons.file_open_outlined, _importProject),
        const PopupMenuDivider(),
        item('重設視圖', Icons.fit_screen, canvas.resetView),
        check('顯示十字輔助線', canvas.showCrosshair, () => canvas.setOption(() => canvas.showCrosshair = !canvas.showCrosshair)),
        check('標示車體尺寸', canvas.showBodyDims, () => canvas.setOption(() => canvas.showBodyDims = !canvas.showBodyDims)),
        check('吸附（特徵點、格線、表列半徑）', canvas.snapOn, () => canvas.setOption(() => canvas.snapOn = !canvas.snapOn)),
        check('格線吸附 0.5 m', canvas.snapStep == 0.5, () => canvas.setOption(() => canvas.snapStep = 0.5)),
        check('格線吸附 0.1 m', canvas.snapStep == 0.1, () => canvas.setOption(() => canvas.snapStep = 0.1)),
        check('不吸附格線', canvas.snapStep == 0.0, () => canvas.setOption(() => canvas.snapStep = 0.0)),
        const PopupMenuDivider(),
        item('操作紀錄', Icons.history, _history),
        item('自我檢查（與電腦版比對）', Icons.fact_check_outlined, () {
          Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => SelfTestPage(specJson: widget.specJson)));
        }),
        item('操作說明', Icons.help_outline, _help),
        item('關於', Icons.info_outline, _about),
      ],
    );
  }

  Widget _canvasArea() {
    return Stack(children: [
      Positioned.fill(child: CraneCanvas(controller: canvas, images: images)),
      Positioned(left: leftStrip + 4, right: 4, top: 4, child: _toolbar()),
      if (canvas.mode != 'select' || canvas.measurement != null)
        Positioned(left: leftStrip + 4, right: 4, top: 50, child: _modeBanner()),
    ]);
  }

  Widget _toolbar() {
    Widget tool(IconData icon, String label, bool on, VoidCallback? onTap, {String? tip}) => Padding(
          padding: const EdgeInsets.only(right: 6),
          child: Tooltip(
            message: tip ?? label,
            child: Material(
              color: on ? const Color(0xff2f8fd0) : Colors.white.withValues(alpha: 0.93),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(9),
                  side: BorderSide(color: onTap == null ? const Color(0xffd0d7de) : const Color(0xff3a9ad9), width: 1.5)),
              child: InkWell(
                borderRadius: BorderRadius.circular(9),
                onTap: onTap,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(icon, size: 18, color: on ? Colors.white : (onTap == null ? const Color(0xffa9b3bd) : const Color(0xff1f6fae))),
                    const SizedBox(width: 3),
                    Text(label,
                        style: TextStyle(
                            fontSize: 13,
                            color: on ? Colors.white : (onTap == null ? const Color(0xffa9b3bd) : k.text))),
                  ]),
                ),
              ),
            ),
          ),
        );
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(children: [
        tool(Icons.near_me_outlined, '選取', canvas.mode == 'select', () => canvas.setMode('select')),
        tool(Icons.straighten, '量測', canvas.mode == 'measure',
            () => canvas.setMode(canvas.mode == 'measure' ? 'select' : 'measure'),
            tip: '量測：距離、角度、水平 / 垂直距離'),
        PopupMenuButton<String>(
          tooltip: '新增物件',
          onSelected: (kind) => kind == 'image' ? _addImage() : canvas.addKind(kind),
          itemBuilder: (_) => [for (final (kind, text) in objectMenu) PopupMenuItem(value: kind, child: Text(text))],
          child: IgnorePointer(child: tool(Icons.add_box_outlined, '物件', canvas.mode == 'create', () {})),
        ),
        tool(Icons.call_made, '助臂', model.pose.jibEnabled,
            model.spec.jibAvailable ? () => _guard(() => model.setJibEnabled(!model.pose.jibEnabled)) : null,
            tip: '助臂（副臂）開關'),
        tool(Icons.open_with, '自由', canvas.freeTipDrag,
            () => canvas.setOption(() => canvas.freeTipDrag = !canvas.freeTipDrag),
            tip: '拖曳臂端紅點：關＝只改臂長；開＝同時改臂長與臂角（半徑接近表列值時吸附）'),
        tool(Icons.fit_screen, '全圖', false, canvas.resetView, tip: '重設視圖'),
      ]),
    );
  }

  Widget _modeBanner() {
    final children = <Widget>[];
    if (canvas.mode == 'measure' && canvas.measurement != null) {
      final m = canvas.measurement!;
      children.add(Expanded(
        child: Text(
            '距離 ${fixed(m.distance, 2)} m　角度 ${fixed(m.angle, 1)}°\n水平 ${fixed(m.dx, 2)} m　垂直 ${fixed(m.dy, 2)} m',
            style: const TextStyle(color: Color(0xff5f3dc4), fontWeight: FontWeight.w700, fontSize: 13)),
      ));
      children.add(TextButton(onPressed: canvas.keepMeasurement, child: const Text('保留為\n尺寸標註', textAlign: TextAlign.center)));
    } else {
      children.add(Expanded(child: Text(canvas.hint, style: const TextStyle(color: k.sectionBlue, fontSize: 13))));
    }
    if (canvas.mode == 'create' && canvas.createKind == 'polygon') {
      children.add(TextButton(onPressed: canvas.undoPolygonPoint, child: const Text('刪點')));
      children.add(FilledButton(onPressed: canvas.finishPolygon, child: const Text('完成')));
    }
    if (canvas.mode != 'select') {
      children.add(TextButton(
          onPressed: () => canvas.setMode('select'), child: Text(canvas.mode == 'measure' ? '結束' : '取消')));
    }
    return Material(
      color: Colors.white.withValues(alpha: 0.95),
      elevation: 2,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        child: Row(children: children),
      ),
    );
  }

  /// 摘要列：半徑、鉤底離地高度、額定、使用率、安全檢查。
  Widget _summary() {
    final m = model;
    final rating = m.loadRating();
    final chk = m.safety().loadCheck;
    Widget stat(String label, String value, {Color? bg, Color? fg}) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          margin: const EdgeInsets.only(right: 6),
          decoration: BoxDecoration(color: bg ?? const Color(0xffeef4fa), borderRadius: BorderRadius.circular(6)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(label, style: TextStyle(fontSize: 10, color: fg ?? k.textHint)),
            Text(value, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: fg ?? k.text)),
          ]),
        );
    final usage = chk?.usage;
    final (ubg, ufg) = switch (chk?.levelName) {
      'caution' => (k.cautionYellow, const Color(0xff3a2600)),
      'warning' => (k.warnAmber, const Color(0xff3a2600)),
      'collision' => (k.alertRed, Colors.white),
      _ => (null, null),
    };
    return Material(
      color: Colors.white,
      elevation: 1,
      child: InkWell(
        onTap: () => setState(() => _tab = 1),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 5, 8, 5),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: [
                stat('半徑', '${fixed(m.result.radius, 2)} m'),
                stat('鉤底離地高度', '${fixed(m.hookBottomHeight, 2)} m'),
                stat('臂長／臂角', '${fixed(m.pose.length, 2)} m／${fixed(m.pose.angle, 1)}°'),
                if (rating != null)
                  stat('額定總荷重', rating.capacity == null ? '無' : '${fixed(rating.capacity!, 2)} t',
                      bg: rating.capacity == null ? const Color(0xfffff1f1) : null,
                      fg: rating.capacity == null ? k.errorText : null),
                if (chk?.loadWeight != null)
                  stat('使用率', usage == null ? '—' : '${fixed(usage * 100, 1)}%', bg: ubg, fg: ufg),
              ]),
            ),
            const SizedBox(height: 4),
            SafetyBanner(model: m, compact: true, onTap: () => setState(() => _tab = 1)),
          ]),
        ),
      ),
    );
  }

  static const _tabs = [
    (Icons.architecture, '吊臂'),
    (Icons.scale_outlined, '荷重'),
    (Icons.category_outlined, '物件'),
    (Icons.local_shipping_outlined, '車體'),
  ];

  Widget _tabBar() {
    return Row(children: [
      for (final (i, (icon, label)) in _tabs.indexed)
        Expanded(
          child: InkWell(
            onTap: () => setState(() => _tab = i),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 6),
              decoration: BoxDecoration(
                border: Border(
                    bottom: BorderSide(color: _tab == i ? k.sectionBlue : const Color(0xffd6dde4), width: _tab == i ? 3 : 1)),
              ),
              child: Column(children: [
                Icon(icon, size: 20, color: _tab == i ? k.sectionBlue : k.textHint),
                Text(
                  i == 2 && canvas.selection.isNotEmpty ? '$label（${canvas.selection.length}）' : label,
                  style: TextStyle(
                      fontSize: 12.5,
                      color: _tab == i ? k.sectionBlue : k.textMuted,
                      fontWeight: _tab == i ? FontWeight.w700 : FontWeight.w400),
                ),
              ]),
            ),
          ),
        ),
    ]);
  }

  Widget _panelContent() {
    final Widget body = switch (_tab) {
      0 => BoomPanel(model: model, onMessage: _message),
      1 => LoadPanel(model: model, onMessage: _message),
      2 => ObjectPanel(
          model: model,
          canvas: canvas,
          onMessage: _message,
          onCopy: _copy,
          onCut: _cut,
          onPaste: _paste,
          canPaste: _clipboard != null,
          onAddImage: _addImage,
          onChooseImage: _chooseImageFor,
          onCalibrate: _startCalibration,
        ),
      _ => BodyPanel(model: model, canvas: canvas, onMessage: _message),
    };
    return SingleChildScrollView(
      key: PageStorageKey('tab$_tab'),
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        body,
        const Text('本軟體結果僅供規劃參考，實際吊掛以吊車荷重計（LMI）與合格人員判斷為準。',
            style: TextStyle(color: k.noteBrown, fontSize: 11.5)),
      ]),
    );
  }

  Widget _wideLayout() {
    return Row(children: [
      Expanded(child: _canvasArea()),
      Container(
        width: 390,
        decoration: const BoxDecoration(border: Border(left: BorderSide(color: Color(0xffd6dde4)))),
        child: Column(children: [
          _summary(),
          _tabBar(),
          Expanded(child: _panelContent()),
        ]),
      ),
    ]);
  }

  Widget _narrowLayout() {
    return LayoutBuilder(builder: (context, box) {
      final avail = box.maxHeight;
      final panelH = (avail * _panelFrac).clamp(90.0, avail - 160.0);
      return Column(children: [
        Expanded(child: _canvasArea()),
        _summary(),
        // 拖曳把手：上下拖曳調整面板高度
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onVerticalDragUpdate: (d) => setState(() {
            _panelFrac = ((panelH - d.delta.dy) / avail).clamp(0.12, 0.85);
          }),
          onVerticalDragEnd: (_) => _savePrefsSoon(),
          onDoubleTap: () => setState(() => _panelFrac = _panelFrac > 0.2 ? 0.12 : 0.42),
          child: Container(
            height: 14,
            color: const Color(0xfff3f5f7),
            alignment: Alignment.center,
            child: Container(
                width: 44, height: 4, decoration: BoxDecoration(color: const Color(0xffb9c4cf), borderRadius: BorderRadius.circular(2))),
          ),
        ),
        SizedBox(
          height: panelH,
          child: Material(
            color: const Color(0xfff8fafc),
            child: Column(children: [
              _tabBar(),
              Expanded(child: _panelContent()),
            ]),
          ),
        ),
      ]);
    });
  }
}

// ====================================================================== 我的專案
class _ProjectsSheet extends StatefulWidget {
  final void Function(String name) onSave;
  final void Function(store.SavedProject p) onOpen;

  const _ProjectsSheet({required this.onSave, required this.onOpen});

  @override
  State<_ProjectsSheet> createState() => _ProjectsSheetState();
}

class _ProjectsSheetState extends State<_ProjectsSheet> {
  @override
  Widget build(BuildContext context) {
    final list = store.listProjects();
    String two(int v) => v.toString().padLeft(2, '0');
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.75),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(children: [
                const Expanded(child: Text('我的專案', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700))),
                FilledButton.icon(
                  icon: const Icon(Icons.save_outlined, size: 18),
                  label: const Text('儲存目前圖面'),
                  onPressed: () async {
                    final now = DateTime.now();
                    final name = await askString(context, '儲存專案',
                        label: '專案名稱（同名會覆蓋）',
                        initial: '專案 ${now.month}/${now.day} ${two(now.hour)}:${two(now.minute)}');
                    if (name == null || name.trim().isEmpty) return;
                    widget.onSave(name.trim());
                    setState(() {});
                  },
                ),
              ]),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 6, 16, 6),
              child: Text('專案存在這支手機的瀏覽器裡；換手機或清除瀏覽器資料前，請用「匯出專案檔」備份。',
                  style: TextStyle(color: k.textHint, fontSize: 12)),
            ),
            if (list.isEmpty)
              const Padding(padding: EdgeInsets.all(16), child: Text('（還沒有儲存的專案）')),
            Flexible(
              child: ListView(shrinkWrap: true, children: [
                for (final p in list)
                  ListTile(
                    leading: const Icon(Icons.description_outlined),
                    title: Text(p.name),
                    subtitle: Text('${p.saved.year}/${p.saved.month}/${p.saved.day} ${two(p.saved.hour)}:${two(p.saved.minute)}'),
                    onTap: () {
                      Navigator.pop(context);
                      widget.onOpen(p);
                    },
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline),
                      tooltip: '刪除',
                      onPressed: () async {
                        if (await confirm(context, '刪除專案', '確定刪除「${p.name}」？（無法復原）', ok: '刪除')) {
                          store.deleteProject(p.name);
                          setState(() {});
                        }
                      },
                    ),
                  ),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}
