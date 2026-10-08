/// 背景圖解碼快取：物件的 path 存的是圖片的 data URL，解碼完成後通知重畫。
library;

import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

class SceneImages extends ChangeNotifier {
  final Map<String, ui.Image?> _images = {};
  final Set<String> _failed = {};

  /// 已解碼的圖片；還在解碼或無法解碼時為 null。
  ui.Image? get(String path) {
    if (path.isEmpty || _failed.contains(path)) return null;
    if (_images.containsKey(path)) return _images[path];
    _images[path] = null;
    _decode(path);
    return null;
  }

  bool failed(String path) => path.isEmpty || _failed.contains(path);

  Future<void> _decode(String path) async {
    try {
      final bytes = UriData.parse(path).contentAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      _images[path] = frame.image;
    } catch (_) {
      _images.remove(path);
      _failed.add(path);
    }
    notifyListeners();
  }

  /// 圖片的寬高（px）；用來設定新背景圖的長寬比。
  static Future<(int, int)?> sizeOf(Uint8List bytes) async {
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      return (frame.image.width, frame.image.height);
    } catch (_) {
      return null;
    }
  }

  /// 清掉已不在圖上的圖片（釋放記憶體）。
  void retain(Set<String> paths) {
    final gone = [for (final k in _images.keys) if (!paths.contains(k)) k];
    for (final k in gone) {
      _images.remove(k)?.dispose();
    }
  }
}
