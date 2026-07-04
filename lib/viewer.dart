import 'dart:io';

import 'package:path/path.dart' as p;

import 'store.dart';

/// Which PDF viewer to launch.
enum ViewerKind { sumatra, foxit }

ViewerKind _parseKind(String? raw) {
  for (final k in ViewerKind.values) {
    if (k.name == raw) return k;
  }
  return ViewerKind.sumatra;
}

/// Opens a PDF at a specific page in an external viewer, or an HTML file in
/// the default browser.
///
/// Supports SumatraPDF (`-reuse-instance -page N`) or Foxit Reader
/// (`<file> /A page=N`). If the chosen viewer's executable can't be found,
/// falls back to opening the file URL with `#page=N` in the default browser
/// (Edge/Chrome honor the fragment).
class Viewer {
  static const _sumatraCandidates = [
    r'C:\Program Files\SumatraPDF\SumatraPDF.exe',
    r'C:\Program Files (x86)\SumatraPDF\SumatraPDF.exe',
  ];

  static const _foxitCandidates = [
    r'C:\Program Files\Foxit Software\Foxit PDF Reader\FoxitPDFReader.exe',
    r'C:\Program Files (x86)\Foxit Software\Foxit PDF Reader\FoxitPDFReader.exe',
    r'C:\Program Files\Foxit Software\Foxit Reader\FoxitReader.exe',
    r'C:\Program Files (x86)\Foxit Software\Foxit Reader\FoxitReader.exe',
  ];

  static ViewerKind get kind => _parseKind(Store.instance.viewerKind);

  /// Returns the SumatraPDF path to use, or null if none found.
  static String? findSumatra() {
    final configured = Store.instance.viewerPath;
    if (configured != null && configured.isNotEmpty && File(configured).existsSync()) {
      return configured;
    }
    final local = Platform.environment['LOCALAPPDATA'];
    final candidates = [
      ..._sumatraCandidates,
      if (local != null) '$local\\SumatraPDF\\SumatraPDF.exe',
    ];
    for (final c in candidates) {
      if (File(c).existsSync()) return c;
    }
    return null;
  }

  /// Returns the Foxit Reader path to use, or null if none found.
  static String? findFoxit() {
    final configured = Store.instance.foxitPath;
    if (configured != null && configured.isNotEmpty && File(configured).existsSync()) {
      return configured;
    }
    for (final c in _foxitCandidates) {
      if (File(c).existsSync()) return c;
    }
    return null;
  }

  /// Human-readable description of what will be used to open PDFs. Cached: it
  /// is read on every status-bar rebuild, and finding a viewer touches the
  /// disk (File.existsSync per candidate) — far too costly to repeat per
  /// frame. Call [invalidateCache] after changing viewer settings.
  static String? _backendDescription;
  static String describeBackend() => _backendDescription ??= _describeBackend();

  static void invalidateCache() => _backendDescription = null;

  static String _describeBackend() {
    switch (kind) {
      case ViewerKind.sumatra:
        return findSumatra() != null
            ? 'SumatraPDF'
            : 'SumatraPDF (غير موجود، سيُستخدم المتصفح)';
      case ViewerKind.foxit:
        return findFoxit() != null
            ? 'Foxit Reader'
            : 'Foxit Reader (غير موجود، سيُستخدم المتصفح)';
    }
  }

  static bool isHtml(String path) {
    final ext = p.extension(path).toLowerCase();
    return ext == '.html' || ext == '.htm';
  }

  static Future<void> open(String pdfPath, int page) async {
    if (isHtml(pdfPath)) {
      // ShellExecute-style open by file association so it launches the
      // user's default browser, whichever that is.
      await Process.start(
        'cmd',
        ['/c', 'start', '', pdfPath],
        mode: ProcessStartMode.detached,
        runInShell: true,
      );
      return;
    }
    final safePage = page < 1 ? 1 : page;

    switch (kind) {
      case ViewerKind.sumatra:
        final sumatra = findSumatra();
        if (sumatra != null) return _launchSumatra(sumatra, pdfPath, safePage);
        return _openInBrowser(pdfPath, safePage);
      case ViewerKind.foxit:
        final foxit = findFoxit();
        if (foxit != null) return _launchFoxit(foxit, pdfPath, safePage);
        return _openInBrowser(pdfPath, safePage);
    }
  }

  static Future<void> _launchSumatra(String exe, String pdfPath, int page) async {
    await Process.start(
      exe,
      ['-reuse-instance', '-page', '$page', pdfPath],
      mode: ProcessStartMode.detached,
    );
  }

  static Future<void> _launchFoxit(String exe, String pdfPath, int page) async {
    await Process.start(
      exe,
      [pdfPath, '/A', 'page=$page'],
      mode: ProcessStartMode.detached,
    );
  }

  static Future<void> _openInBrowser(String pdfPath, int page) async {
    final url = '${Uri.file(pdfPath)}#page=$page';
    await Process.start(
      'cmd',
      ['/c', 'start', 'msedge', url],
      mode: ProcessStartMode.detached,
      runInShell: true,
    );
  }
}
