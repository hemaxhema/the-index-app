import 'dart:io';

import 'package:path/path.dart' as p;

import 'store.dart';

/// Opens a PDF at a specific page in an external viewer, or an HTML file in
/// the default browser.
///
/// PDFs prefer SumatraPDF (`-reuse-instance -page N`) which reuses a single
/// window and jumps precisely. Falls back to opening the file URL with
/// `#page=N` in the default browser (Edge/Chrome honor the fragment).
class Viewer {
  static const _sumatraCandidates = [
    r'C:\Program Files\SumatraPDF\SumatraPDF.exe',
    r'C:\Program Files (x86)\SumatraPDF\SumatraPDF.exe',
  ];

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

  /// Human-readable description of what will be used to open PDFs. Cached: it
  /// is read on every status-bar rebuild, and [findSumatra] touches the disk
  /// (File.existsSync per candidate) — far too costly to repeat per frame.
  static String? _backendDescription;
  static String describeBackend() => _backendDescription ??=
      (findSumatra() != null ? 'SumatraPDF' : 'Default browser (#page)');

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
    final sumatra = findSumatra();
    if (sumatra != null) {
      await Process.start(
        sumatra,
        ['-reuse-instance', '-page', '$safePage', pdfPath],
        mode: ProcessStartMode.detached,
      );
      return;
    }
    // Fallback: default browser via file URL fragment.
    final url = '${Uri.file(pdfPath)}#page=$safePage';
    await Process.start(
      'cmd',
      ['/c', 'start', 'msedge', url],
      mode: ProcessStartMode.detached,
      runInShell: true,
    );
  }
}
