{{flutter_js}}
{{flutter_build_config}}

// Flutter 會換掉 viewport 設定；加回 viewport-fit=cover，iPhone 才量得到安全區域（瀏海、底部指示條）
function craneFixViewport() {
  const meta = document.querySelector('meta[name="viewport"]');
  if (meta && meta.content.indexOf('viewport-fit') < 0) {
    meta.content += ', viewport-fit=cover';
    window.dispatchEvent(new Event('resize')); // 讓 APP 重新量安全區域
  }
}

// 固定用完整版 CanvasKit（每種瀏覽器載入同一份，離線快取比較單純）
_flutter.loader.load({
  config: {
    canvasKitVariant: 'full',
  },
  onEntrypointLoaded: async function (engineInitializer) {
    const appRunner = await engineInitializer.initializeEngine();
    craneFixViewport();
    await appRunner.runApp();
    craneFixViewport();
    setTimeout(craneFixViewport, 500);
    const loading = document.getElementById('loading');
    if (loading) loading.remove();
  },
});
