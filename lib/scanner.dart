import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;
import 'package:syncfusion_flutter_pdf/pdf.dart';

import 'models.dart';
import 'pdf_repair.dart';

/// Scan a folder of PDFs and build the grouped topic index.
///
/// All file IO and PDF parsing happen in a background isolate so the UI thread
/// stays responsive even for large books.
Future<LibraryIndex> scanFolder(
  String folder, {
  List<String> folderOrder = const [],
}) async {
  final raw = await Isolate.run(() => _scan(folder));

  final books = <Book>[];
  final occurrences = <Occurrence>[];
  for (final entry in raw) {
    books.add(Book(
      id: entry['id'] as String,
      path: entry['path'] as String,
      title: entry['title'] as String,
    ));
    for (final b in (entry['bookmarks'] as List)) {
      final m = b as Map;
      occurrences.add(Occurrence(
        bookId: entry['id'] as String,
        originalTitle: m['title'] as String,
        page: m['page'] as int,
        level: m['level'] as int,
      ));
    }
  }
  return LibraryIndex.build(
    folder: folder,
    books: books,
    occurrences: occurrences,
    folderOrder: folderOrder,
  );
}

/// Runs inside the isolate. Returns JSON-serializable data only.
List<Map<String, dynamic>> _scan(String folder) {
  final dir = Directory(folder);
  if (!dir.existsSync()) return const [];

  final files = dir
      .listSync(recursive: true, followLinks: false)
      .whereType<File>()
      .toList()
    ..sort((a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()));

  final result = <Map<String, dynamic>>[];
  for (final file in files) {
    final ext = p.extension(file.path).toLowerCase();
    if (ext == '.pdf') {
      final bookmarks = _extract(file.path);
      if (bookmarks.isEmpty) continue; // skip PDFs with no outline
      result.add({
        'id': file.path,
        'path': file.path,
        'title': p.basenameWithoutExtension(file.path),
        'bookmarks': bookmarks,
      });
    } else if (ext == '.html' || ext == '.htm') {
      // An HTML file has no internal outline: it becomes a single bookmark
      // named after the file itself, opened via the browser (see viewer.dart).
      // The "book" it belongs to is shown as its containing folder's name
      // (rather than the filename, which would just repeat the bookmark
      // title on every chip) so files from different folders stay distinct.
      final title = p.basenameWithoutExtension(file.path);
      final folderName = p.basename(p.dirname(file.path));
      result.add({
        'id': file.path,
        'path': file.path,
        'title': folderName,
        'bookmarks': [
          {'title': title, 'page': -1, 'level': 0},
        ],
      });
    }
  }
  return result;
}

/// Walk a single PDF's outline into a flat list of {title, page, level}.
///
/// Some PDFs (seen in "مفهرس" library batches) store their outline behind a
/// hybrid xref table + compressed object streams (PDF 1.5+); syncfusion
/// fails to resolve the outline through that structure and silently returns
/// zero bookmarks even though the file has a real one. When that happens,
/// fall back to asking qpdf to rewrite the file with classic xref/plain
/// objects, then retry — cheaper and more reliable than hand-parsing the
/// outline dictionary ourselves.
List<Map<String, dynamic>> _extract(String path) {
  final direct = _extractSyncfusion(path);
  if (direct.isNotEmpty) return direct;
  final normalized = normalizePdfViaQpdf(path);
  if (normalized == null) return direct;
  try {
    return _extractSyncfusion(normalized);
  } finally {
    try {
      File(normalized).deleteSync();
    } catch (_) {
      // Best-effort cleanup; leaving a temp file behind isn't fatal.
    }
  }
}

List<Map<String, dynamic>> _extractSyncfusion(String path) {
  final out = <Map<String, dynamic>>[];
  PdfDocument? doc;
  try {
    doc = PdfDocument(inputBytes: File(path).readAsBytesSync());
    final document = doc;

    // Cache page -> index once; indexOf per bookmark can be O(n).
    final pageIndex = <PdfPage, int>{};
    for (var i = 0; i < document.pages.count; i++) {
      pageIndex[document.pages[i]] = i;
    }

    void walk(PdfBookmarkBase base, int level) {
      for (var i = 0; i < base.count; i++) {
        final PdfBookmark bm = base[i];
        final title = bm.title.trim();
        var page = -1;
        try {
          final dest = bm.destination;
          if (dest != null) {
            page = (pageIndex[dest.page] ?? -1) + 1; // 1-based physical page
          }
        } catch (_) {
          // Some destinations (named/remote) can't resolve; leave page = -1.
        }
        if (title.isNotEmpty) {
          out.add({'title': title, 'page': page, 'level': level});
        }
        if (bm.count > 0) walk(bm, level + 1);
      }
    }

    walk(document.bookmarks, 0);
  } catch (_) {
    // Corrupt/encrypted PDF — skip it rather than failing the whole scan.
  } finally {
    doc?.dispose();
  }
  return out;
}
