import 'dart:io';

import 'package:path/path.dart' as p;

/// Path to the qpdf executable bundled next to the app, or `'qpdf'` (PATH
/// lookup) if the bundled copy isn't present — e.g. during `flutter run`,
/// where the CMake install step that copies `windows/qpdf/` into place
/// hasn't run.
String _qpdfExecutable() {
  final bundled = p.join(
    p.dirname(Platform.resolvedExecutable),
    'qpdf',
    'qpdf.exe',
  );
  return File(bundled).existsSync() ? bundled : 'qpdf';
}

/// Rewrites [path] via qpdf (classic xref, no object streams) into a temp
/// file and returns its path, or null if qpdf isn't available or fails.
///
/// Some PDFs (seen in "مفهرس" library batches) store their outline behind a
/// hybrid xref table + compressed object streams (PDF 1.5+); syncfusion
/// fails to resolve the outline through that structure and silently
/// behaves as if there is none — reporting zero bookmarks on read
/// (scanner.dart) and, worse, saving an emptied-out outline over the real
/// one on write (renamer.dart) if not routed through this normalization
/// first. Callers are responsible for deleting the returned temp file.
String? normalizePdfViaQpdf(String path) {
  final tempPath = p.join(
    Directory.systemTemp.path,
    'bmidx_${DateTime.now().microsecondsSinceEpoch}_${p.basename(path)}',
  );
  try {
    final result = Process.runSync(
      _qpdfExecutable(),
      ['--object-streams=disable', path, tempPath],
    );
    // Exit code 3 = completed with warnings (still usable); 0 = clean.
    if ((result.exitCode == 0 || result.exitCode == 3) &&
        File(tempPath).existsSync()) {
      return tempPath;
    }
  } catch (_) {
    // qpdf missing/not on PATH — no fallback available.
  }
  if (File(tempPath).existsSync()) {
    try {
      File(tempPath).deleteSync();
    } catch (_) {}
  }
  return null;
}
