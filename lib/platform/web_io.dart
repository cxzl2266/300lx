/// 瀏覽器功能（本機儲存、下載檔案、選擇檔案、讀取網址）。
///
/// 網頁版用 web_io_web.dart；單元測試（VM）用 web_io_stub.dart。
library;

export 'web_io_stub.dart' if (dart.library.js_interop) 'web_io_web.dart';
