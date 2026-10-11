(function () {
  var script = document.currentScript;
  var base = script && script.src ? script.src : document.baseURI;
  ZXingWASM.setZXingModuleOverrides({
    locateFile: function (path, prefix) {
      return path.endsWith('.wasm') ? new URL('zxing_reader.wasm', base).href : prefix + path;
    }
  });
})();
