/// 網頁版：直接呼叫瀏覽器 API（dart:js_interop，不需要額外套件）。
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

// ---------------------------------------------------------------- 本機儲存
extension type _Storage(JSObject _) implements JSObject {
  external JSString? getItem(JSString key);
  external void setItem(JSString key, JSString value);
  external void removeItem(JSString key);
}

@JS('localStorage')
external _Storage get _localStorage;

String? storageGet(String key) {
  try {
    return _localStorage.getItem(key.toJS)?.toDart;
  } catch (_) {
    return null; // 私密瀏覽或停用網站資料
  }
}

/// 寫入本機儲存；空間不足（或無法使用）時回傳 false。
bool storageSet(String key, String value) {
  try {
    _localStorage.setItem(key.toJS, value.toJS);
    return true;
  } catch (_) {
    return false;
  }
}

void storageRemove(String key) {
  try {
    _localStorage.removeItem(key.toJS);
  } catch (_) {}
}

// ---------------------------------------------------------------- 讀取網址
extension type _Response(JSObject _) implements JSObject {
  external bool get ok;
  external int get status;
  external JSPromise<JSString> text();
}

@JS('fetch')
external JSPromise<_Response> _fetch(JSString url);

Future<String> fetchText(String url) async {
  final res = await _fetch(url.toJS).toDart;
  if (!res.ok) throw StateError('讀取 $url 失敗（HTTP ${res.status}）');
  return (await res.text().toDart).toDart;
}

// ---------------------------------------------------------------- DOM
extension type _Document(JSObject _) implements JSObject {
  external _Element createElement(JSString tag);
  external _Element get body;
}

extension type _Element(JSObject _) implements JSObject {
  external set href(JSString v);
  external set download(JSString v);
  external set accept(JSString v);
  external set type(JSString v);
  external _FileList? get files;
  external void click();
  external void remove();
  external _Element appendChild(_Element child);
  external void setAttribute(JSString name, JSString value);
  external void addEventListener(JSString type, JSFunction listener);
}

extension type _FileList(JSObject _) implements JSObject {
  external int get length;
  external _File? item(int index);
}

extension type _File(JSObject _) implements JSObject {
  external JSString get name;
  external JSString get type;
  external JSPromise<JSArrayBuffer> arrayBuffer();
}

extension type _BlobOptions._(JSObject _) implements JSObject {
  external factory _BlobOptions({JSString type});
}

@JS('Blob')
extension type _Blob._(JSObject _) implements JSObject {
  external factory _Blob(JSArray<JSAny> parts, _BlobOptions options);
}

@JS('document')
external _Document get _document;

@JS('URL.createObjectURL')
external JSString _createObjectURL(JSObject blob);

@JS('URL.revokeObjectURL')
external void _revokeObjectURL(JSString url);

/// 下載文字檔（iPhone 會跳出預覽，可「儲存到檔案」或分享）。
void downloadText(String filename, String text, [String mime = 'application/json']) {
  final blob = _Blob([text.toJS].toJS, _BlobOptions(type: '$mime;charset=utf-8'.toJS));
  final url = _createObjectURL(blob);
  final a = _document.createElement('a'.toJS)
    ..href = url
    ..download = filename.toJS;
  a.setAttribute('style'.toJS, 'display:none'.toJS);
  _document.body.appendChild(a);
  a.click();
  a.remove();
  Timer(const Duration(seconds: 30), () => _revokeObjectURL(url));
}

/// 選擇檔案：(檔名, MIME 類型, 內容)；取消時為 null（舊版瀏覽器取消時不會有回應）。
Future<(String, String, Uint8List)?> pickFile(String accept) {
  final done = Completer<(String, String, Uint8List)?>();
  final input = _document.createElement('input'.toJS)
    ..type = 'file'.toJS
    ..accept = accept.toJS;
  input.setAttribute('style'.toJS, 'display:none'.toJS);
  _document.body.appendChild(input);
  input.addEventListener(
      'change'.toJS,
      ((JSAny _) {
        final files = input.files;
        final f = files == null || files.length == 0 ? null : files.item(0);
        input.remove();
        if (f == null) {
          if (!done.isCompleted) done.complete(null);
          return;
        }
        f.arrayBuffer().toDart.then((buf) {
          if (!done.isCompleted) done.complete((f.name.toDart, f.type.toDart, buf.toDart.asUint8List()));
        }, onError: (Object e) {
          if (!done.isCompleted) done.completeError(e);
        });
      }).toJS);
  input.addEventListener(
      'cancel'.toJS,
      ((JSAny _) {
        input.remove();
        if (!done.isCompleted) done.complete(null);
      }).toJS);
  input.click();
  return done.future;
}

// ---------------------------------------------------------------- 安全區域
@JS('craneSafeArea')
external JSArray<JSNumber> _craneSafeArea();

/// iPhone 瀏海、底部指示條的安全區域（px）：(上, 右, 下, 左)；由 index.html 量測。
(double, double, double, double) safeArea() {
  try {
    final v = _craneSafeArea().toDart.map((n) => n.toDartDouble).toList();
    return (v[0], v[1], v[2], v[3]);
  } catch (_) {
    return (0.0, 0.0, 0.0, 0.0);
  }
}

// ---------------------------------------------------------------- 圖片
@JS('craneImageToDataUrl')
external JSPromise<JSString> _imageToDataUrl(JSUint8Array bytes, JSString mime, JSNumber maxSide);

/// 圖片縮到最長邊 maxSide px 以內、轉成 JPEG 的 data URL（手機照片很大，存檔才放得下）。
Future<String> imageToDataUrl(Uint8List bytes, String mime, int maxSide) async =>
    (await _imageToDataUrl(bytes.toJS, mime.toJS, maxSide.toJS).toDart).toDart;
