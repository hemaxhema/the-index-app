import 'dart:io';

import 'package:path/path.dart' as p;

import 'store.dart';

/// Which PDF viewer to launch.
enum ViewerKind { sumatra, foxit, chrome }

ViewerKind _parseKind(String? raw) {
  for (final k in ViewerKind.values) {
    if (k.name == raw) return k;
  }
  return ViewerKind.sumatra;
}

/// Opens a PDF at a specific page in an external viewer, or an HTML file in
/// the default browser.
///
/// Supports SumatraPDF (`-reuse-instance -page N`), Foxit Reader/Editor
/// (`<file> /A page=N`), or Chrome (`file:///<path>#page=N`). If the chosen
/// viewer's executable can't be found, falls back to opening the file URL
/// with `#page=N` in the default browser (Edge/Chrome honor the fragment).
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
    r'C:\Program Files\Foxit Software\Foxit PDF Editor\FoxitPDFEditor.exe',
    r'C:\Program Files (x86)\Foxit Software\Foxit PDF Editor\FoxitPDFEditor.exe',
    r'C:\Program Files\Foxit Software\Foxit PhantomPDF\FoxitPhantomPDF.exe',
    r'C:\Program Files (x86)\Foxit Software\Foxit PhantomPDF\FoxitPhantomPDF.exe',
  ];

  static const _chromeCandidates = [
    r'C:\Program Files\Google\Chrome\Application\chrome.exe',
    r'C:\Program Files (x86)\Google\Chrome\Application\chrome.exe',
  ];

  static ViewerKind get kind => _parseKind(Store.instance.viewerKind);

  /// Whether the user has never explicitly saved a viewer preference (fresh
  /// install / never opened the settings dialog). Only in this state does
  /// the Sumatra path cascade through Foxit then Chrome before the browser;
  /// once the user explicitly picks Sumatra in settings, it is honored as
  /// a single choice like Foxit/Chrome are.
  static bool get noExplicitPreference => Store.instance.viewerKind == null;

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

  /// Returns the Foxit Reader/Editor path to use, or null if none found.
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

  /// Returns the Chrome path to use, or null if none found.
  static String? findChrome() {
    final configured = Store.instance.chromePath;
    if (configured != null && configured.isNotEmpty && File(configured).existsSync()) {
      return configured;
    }
    final local = Platform.environment['LOCALAPPDATA'];
    final candidates = [
      ..._chromeCandidates,
      if (local != null) '$local\\Google\\Chrome\\Application\\chrome.exe',
    ];
    for (final c in candidates) {
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
        if (findSumatra() != null) return 'SumatraPDF';
        if (noExplicitPreference) {
          if (findFoxit() != null) return 'Foxit Reader/Editor (SumatraPDF غير موجود)';
          if (findChrome() != null) return 'Chrome (SumatraPDF وFoxit غير موجودين)';
          return 'المتصفح الافتراضي (لم يُعثر على أي عارض)';
        }
        return 'SumatraPDF (غير موجود، سيُستخدم المتصفح)';
      case ViewerKind.foxit:
        return findFoxit() != null
            ? 'Foxit Reader/Editor'
            : 'Foxit Reader/Editor (غير موجود، سيُستخدم المتصفح)';
      case ViewerKind.chrome:
        return findChrome() != null
            ? 'Chrome'
            : 'Chrome (غير موجود، سيُستخدم المتصفح)';
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
        if (noExplicitPreference) {
          final foxit = findFoxit();
          if (foxit != null) return _launchFoxit(foxit, pdfPath, safePage);
          final chrome = findChrome();
          if (chrome != null) return _launchChrome(chrome, pdfPath, safePage);
        }
        return _openInBrowser(pdfPath, safePage);
      case ViewerKind.foxit:
        final foxit = findFoxit();
        if (foxit != null) return _launchFoxit(foxit, pdfPath, safePage);
        return _openInBrowser(pdfPath, safePage);
      case ViewerKind.chrome:
        final chrome = findChrome();
        if (chrome != null) return _launchChrome(chrome, pdfPath, safePage);
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

  /// Also works for Foxit PDF Editor / PhantomPDF, which share Foxit
  /// Reader's `/A page=N` command-line switch.
  static Future<void> _launchFoxit(String exe, String pdfPath, int page) async {
    await Process.start(
      exe,
      [pdfPath, '/A', 'page=$page'],
      mode: ProcessStartMode.detached,
    );
  }

  static Future<void> _launchChrome(String exe, String pdfPath, int page) async {
    final url = '${Uri.file(pdfPath)}#page=$page';
    await Process.start(
      exe,
      [url],
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

  /// Opens an arbitrary web URL in the user's default browser.
  ///
  /// Uses rundll32's URL handler instead of `cmd /c start`: cmd.exe owns a
  /// console window that flashes on screen for an instant even when detached,
  /// while rundll32 has no console to flash.
  static Future<void> openUrl(String url) async {
    await Process.start(
      'rundll32',
      ['url.dll,FileProtocolHandler', url],
      mode: ProcessStartMode.detached,
    );
  }
}
