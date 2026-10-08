/// 圖面元件：把觸控 / 滑鼠事件轉給 CanvasController，並用 ScenePainter 繪製。
///
/// - 單指：交給控制器（拖曳紅點、主臂、物件；空白處平移）
/// - 雙指：縮放 + 平移（第二指放下時取消尚未開始的單指操作）
/// - 電腦：滾輪縮放、右鍵 / 中鍵拖曳平移、觸控板雙指縮放
library;

import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import 'canvas_controller.dart';
import 'scene_images.dart';
import 'scene_painter.dart';

class CraneCanvas extends StatefulWidget {
  final CanvasController controller;
  final SceneImages images;

  const CraneCanvas({super.key, required this.controller, required this.images});

  @override
  State<CraneCanvas> createState() => _CraneCanvasState();
}

class _CraneCanvasState extends State<CraneCanvas> {
  final Map<int, Offset> _pointers = {};
  int? _primary; // 單指操作的手指
  int? _panPointer; // 滑鼠右鍵 / 中鍵平移
  bool _pinched = false; // 這次觸控有用過雙指：剩一指時不再開始單指操作
  double? _pinchDist;
  Offset? _pinchFocal;

  CanvasController get c => widget.controller;

  void _startPinch() {
    final pts = _pointers.values.take(2).toList();
    _pinchDist = math.max(1.0, (pts[0] - pts[1]).distance);
    _pinchFocal = (pts[0] + pts[1]) / 2;
  }

  void _onDown(PointerDownEvent e) {
    _pointers[e.pointer] = e.localPosition;
    if (e.kind == PointerDeviceKind.mouse && (e.buttons & (kSecondaryMouseButton | kMiddleMouseButton)) != 0) {
      _panPointer = e.pointer;
      return;
    }
    if (_pointers.length == 1) {
      _pinched = false;
      _primary = e.pointer;
      c.pointerDown(e.localPosition);
    } else if (_pointers.length == 2) {
      if (_primary != null) c.cancelGesture();
      _primary = null;
      _pinched = true;
      _startPinch();
    }
  }

  void _onMove(PointerMoveEvent e) {
    final old = _pointers[e.pointer];
    _pointers[e.pointer] = e.localPosition;
    if (e.pointer == _panPointer) {
      if (old != null) c.panBy(e.localPosition - old);
      return;
    }
    if (_pointers.length >= 2 && _pinchDist != null) {
      final pts = _pointers.values.take(2).toList();
      final d = math.max(1.0, (pts[0] - pts[1]).distance);
      final f = (pts[0] + pts[1]) / 2;
      c.panBy(f - _pinchFocal!);
      c.zoomAt(f, d / _pinchDist!);
      _pinchDist = d;
      _pinchFocal = f;
      return;
    }
    if (e.pointer == _primary) c.pointerMove(e.localPosition);
  }

  void _onUp(PointerEvent e, {bool cancel = false}) {
    _pointers.remove(e.pointer);
    if (e.pointer == _panPointer) {
      _panPointer = null;
      return;
    }
    if (e.pointer == _primary) {
      _primary = null;
      if (cancel) {
        c.cancelGesture();
      } else {
        c.pointerUp(e.localPosition);
      }
    }
    if (_pointers.length >= 2) {
      _startPinch();
    } else {
      _pinchDist = null;
      _pinchFocal = null;
    }
    if (_pointers.isEmpty) _pinched = false;
    // 雙指縮放後剩一指：不開始單指操作（避免誤拖物件）
    if (_pinched && _pointers.length == 1) _primary = null;
  }

  void _onSignal(PointerSignalEvent e) {
    if (e is PointerScrollEvent) {
      final factor = math.pow(1.15, -e.scrollDelta.dy / 100).toDouble();
      c.zoomAt(e.localPosition, factor);
    } else if (e is PointerScaleEvent) {
      c.zoomAt(e.localPosition, e.scale);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: _onDown,
      onPointerMove: _onMove,
      onPointerUp: (e) => _onUp(e),
      onPointerCancel: (e) => _onUp(e, cancel: true),
      onPointerHover: (e) => c.hover(e.localPosition),
      onPointerSignal: _onSignal,
      onPointerPanZoomUpdate: (e) {
        c.panBy(e.panDelta);
        if (e.scale != 1.0) c.zoomAt(e.localPosition, e.scale / (_lastTrackpadScale ?? 1.0));
        _lastTrackpadScale = e.scale;
      },
      onPointerPanZoomEnd: (_) => _lastTrackpadScale = null,
      child: LayoutBuilder(builder: (context, box) {
        c.setSize(box.biggest);
        return RepaintBoundary(
          child: CustomPaint(
            painter: ScenePainter(c, widget.images, Listenable.merge([c, c.model, widget.images])),
            size: box.biggest,
          ),
        );
      }),
    );
  }

  double? _lastTrackpadScale;
}
