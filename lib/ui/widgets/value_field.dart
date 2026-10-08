/// 數值欄位（移植自桌面版 ParamField，改成觸控）：標題 + 數值 + −／＋ 按鈕。
///
/// - 點數值輸入，按「完成」或離開欄位即套用；超出範圍時欄位變紅並拒絕套用
/// - −／＋ 微調（長按連續調整）
/// - 模型改變時自動更新（正在輸入時不覆蓋）
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/geometry.dart' show OutOfReachError;
import '../../core/pyformat.dart';
import '../colors.dart' as k;

/// 欄位外觀：一般、錯誤、紅（超限）、黃（≥80%）、橘（≥90%）。
enum FieldLook { ok, error, alert, caution, warn }

class ValueField extends StatefulWidget {
  final String title;
  final String unit;
  final int decimals;
  final double Function() getter;
  final void Function(double)? setter;
  final double step;
  final String? help;
  final bool compact;
  final String? Function()? display; // 自訂顯示文字（例如「碰撞」、「—」）
  final double Function(double base, int steps)? stepper; // −／＋ 的下一個值
  final FieldLook Function()? look; // 唯讀欄位的警示顏色
  final void Function(String message)? onError;

  const ValueField({
    super.key,
    required this.title,
    required this.unit,
    required this.decimals,
    required this.getter,
    this.setter,
    this.step = 0.1,
    this.help,
    this.compact = false,
    this.display,
    this.stepper,
    this.look,
    this.onError,
  });

  @override
  State<ValueField> createState() => _ValueFieldState();
}

class _ValueFieldState extends State<ValueField> {
  final _ctl = TextEditingController();
  final _focus = FocusNode();
  bool _modified = false;
  String? _error;
  String _errorAt = '';
  Timer? _repeat;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) {
        _commit();
        if (_error == null) setState(() {});
      }
    });
    _sync();
  }

  @override
  void dispose() {
    _repeat?.cancel();
    _ctl.dispose();
    _focus.dispose();
    super.dispose();
  }

  String _fmt(double v) => v.isFinite ? '${fixed(v, widget.decimals)}${widget.unit}' : '—';

  String _modelText() => widget.display?.call() ?? _fmt(widget.getter());

  /// 模型 → 欄位。使用者正在輸入時不覆蓋；有錯誤時保留，直到模型的值改變。
  void _sync({bool force = false}) {
    final t = _modelText();
    if (!force) {
      if (_focus.hasFocus && _modified) return;
      if (_error != null && t == _errorAt) return;
    }
    if (_ctl.text != t) _ctl.text = t;
    _modified = false;
    _error = null;
  }

  void _setError(String msg) {
    _error = msg;
    _errorAt = _modelText();
  }

  double? _parse() {
    var txt = _ctl.text.trim();
    for (final u in [widget.unit.trim(), 'm', '°', '度', 'M', 't', '%']) {
      if (u.isNotEmpty && txt.endsWith(u)) txt = txt.substring(0, txt.length - u.length).trim();
    }
    final v = double.tryParse(txt.replaceAll(',', '.').replaceAll('－', '-').replaceAll('．', '.'));
    return v != null && v.isFinite ? v : null;
  }

  void _apply(double v) {
    final setter = widget.setter;
    if (setter == null) return;
    try {
      setter(v);
    } on OutOfReachError catch (e) {
      setState(() => _setError(e.message));
      widget.onError?.call(e.message);
      return;
    }
    setState(() => _sync(force: true));
  }

  void _commit() {
    if (widget.setter == null || !_modified) return;
    final v = _parse();
    if (v == null) {
      setState(() => _setError('請輸入數字'));
      widget.onError?.call('${widget.title}：請輸入數字');
      return;
    }
    _modified = false;
    _apply(v);
  }

  void _step(int n) {
    if (widget.setter == null) return;
    var base = widget.getter();
    if (_modified) base = _parse() ?? base;
    _modified = false;
    final next = widget.stepper != null ? widget.stepper!(base, n) : pyRound(base + n * widget.step, widget.decimals);
    _apply(next);
  }

  void _startRepeat(int n) {
    _repeat?.cancel();
    var count = 0;
    _repeat = Timer.periodic(const Duration(milliseconds: 110), (_) {
      count++;
      _step(count > 15 ? n * 5 : n); // 長按久一點加快
    });
  }

  void _stopRepeat() {
    _repeat?.cancel();
    _repeat = null;
  }

  @override
  Widget build(BuildContext context) {
    _sync();
    final editable = widget.setter != null;
    var look = _error != null ? FieldLook.error : (widget.look?.call() ?? FieldLook.ok);
    if (!editable && look == FieldLook.ok) look = FieldLook.ok;
    final (border, fill, fg, bold) = switch (look) {
      FieldLook.error => (k.alertRed, const Color(0xfffff1f1), const Color(0xff9b0000), false),
      FieldLook.alert => (const Color(0xffc92a2a), k.alertRed, Colors.white, true),
      FieldLook.caution => (const Color(0xffe0b400), k.cautionYellow, const Color(0xff3a2600), true),
      FieldLook.warn => (const Color(0xffe8590c), k.warnAmber, const Color(0xff3a2600), true),
      FieldLook.ok => editable
          ? (k.fieldBorder, Colors.white, k.text, false)
          : (const Color(0xffb9c4cf), const Color(0xfff2f4f6), k.text, false),
    };
    final h = widget.compact ? 36.0 : 44.0;
    final field = Container(
      height: h,
      decoration: BoxDecoration(
        color: fill,
        border: Border.all(color: border, width: 2),
        borderRadius: BorderRadius.circular(8),
      ),
      alignment: Alignment.center,
      child: TextField(
        controller: _ctl,
        focusNode: _focus,
        readOnly: !editable,
        textAlign: TextAlign.center,
        keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
        textInputAction: TextInputAction.done,
        style: TextStyle(
          fontFamily: k.appFont,
          fontSize: widget.compact ? 15 : 19,
          color: fg,
          fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
        ),
        decoration: const InputDecoration(isCollapsed: true, border: InputBorder.none),
        onChanged: (_) {
          _modified = true;
          if (_error != null) setState(() => _error = null);
        },
        onSubmitted: (_) => _commit(),
        onTap: () {
          if (editable && !_modified) {
            _ctl.selection = TextSelection(baseOffset: 0, extentOffset: _ctl.text.length);
          }
        },
      ),
    );
    Widget btn(IconData icon, int n) => GestureDetector(
          onTap: () => _step(n),
          onLongPressStart: (_) => _startRepeat(n),
          onLongPressEnd: (_) => _stopRepeat(),
          onLongPressCancel: _stopRepeat,
          child: Container(
            width: widget.compact ? 30 : 34,
            height: h,
            alignment: Alignment.center,
            child: Icon(icon, size: 20, color: k.sectionBlue),
          ),
        );
    final title = Text(widget.title,
        textAlign: TextAlign.center,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: Color(0xff3b4652), fontSize: 13));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        widget.help == null
            ? title
            : GestureDetector(
                onTap: () => _showHelp(context),
                child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Flexible(child: title),
                  const SizedBox(width: 2),
                  const Icon(Icons.info_outline, size: 14, color: k.textHint),
                ]),
              ),
        const SizedBox(height: 2),
        editable
            ? Row(children: [btn(Icons.remove, -1), Expanded(child: field), btn(Icons.add, 1)])
            : field,
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(_error!, style: const TextStyle(color: k.errorText, fontSize: 11)),
          ),
      ],
    );
  }

  void _showHelp(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(widget.title),
        content: Text(widget.help!),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('知道了'))],
      ),
    );
  }
}

/// 兩欄排列（手機寬度不夠時改一欄）。
class FieldGrid extends StatelessWidget {
  final List<Widget> children;
  final double spacing;

  const FieldGrid({super.key, required this.children, this.spacing = 10});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final cols = box.maxWidth < 260 ? 1 : 2;
      final w = (box.maxWidth - spacing * (cols - 1)) / cols;
      return Wrap(
        spacing: spacing,
        runSpacing: 8,
        children: [for (final c in children) SizedBox(width: math.max(0, w), child: c)],
      );
    });
  }
}
