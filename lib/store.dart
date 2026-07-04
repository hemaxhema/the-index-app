import 'dart:convert';
import 'dart:io';

import 'models.dart';

/// App settings + on-disk index cache, kept under %APPDATA%\bookmark_index.
/// Uses dart:io only, so the app needs no platform plugins.
class Store {
  Store._(this._dir);

  final Directory _dir;

  static Store? _instance;

  static Store get instance {
    final base = Platform.environment['APPDATA'] ??
        Platform.environment['LOCALAPPDATA'] ??
        Directory.systemTemp.path;
    final dir = Directory('$base${Platform.pathSeparator}bookmark_index');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return _instance ??= Store._(dir);
  }

  File get _settingsFile => File('${_dir.path}${Platform.pathSeparator}settings.json');

  Map<String, dynamic> _readSettings() {
    try {
      if (_settingsFile.existsSync()) {
        return jsonDecode(_settingsFile.readAsStringSync()) as Map<String, dynamic>;
      }
    } catch (_) {}
    return {};
  }

  void _writeSettings(Map<String, dynamic> s) {
    _settingsFile.writeAsStringSync(jsonEncode(s));
  }

  String? get lastFolder => _readSettings()['folder'] as String?;
  set lastFolder(String? v) {
    final s = _readSettings()..['folder'] = v;
    _writeSettings(s);
  }

  /// Which PDF viewer to use: 'sumatra' or 'foxit'. Null/unrecognized falls
  /// back to 'sumatra'.
  String? get viewerKind => _readSettings()['viewerKind'] as String?;
  set viewerKind(String? v) {
    final s = _readSettings()..['viewerKind'] = v;
    _writeSettings(s);
  }

  /// Explicit SumatraPDF executable path (optional; auto-detected otherwise).
  String? get viewerPath => _readSettings()['viewerPath'] as String?;
  set viewerPath(String? v) {
    final s = _readSettings()..['viewerPath'] = v;
    _writeSettings(s);
  }

  /// Explicit Foxit Reader executable path (optional; auto-detected otherwise).
  String? get foxitPath => _readSettings()['foxitPath'] as String?;
  set foxitPath(String? v) {
    final s = _readSettings()..['foxitPath'] = v;
    _writeSettings(s);
  }

  File _cacheFile(String folder) {
    final key = folder.toLowerCase().codeUnits.fold<int>(
        7, (h, c) => (h * 31 + c) & 0x7fffffff); // simple stable hash
    return File('${_dir.path}${Platform.pathSeparator}cache_$key.json');
  }

  LibraryIndex? loadCache(String folder) {
    try {
      final f = _cacheFile(folder);
      if (f.existsSync()) {
        return LibraryIndex.fromJson(
            jsonDecode(f.readAsStringSync()) as Map<String, dynamic>);
      }
    } catch (_) {}
    return null;
  }

  void saveCache(LibraryIndex index) {
    try {
      _cacheFile(index.folder).writeAsStringSync(jsonEncode(index.toJson()));
    } catch (_) {}
  }
}
