// Diagnostic: runs the PDF bookmark extraction over a folder synchronously,
// logging each file, its bookmark/page counts, and the process memory (RSS)
// so we can see where a large scan runs out of memory or crashes.
//
// Usage:  dart run tool/scan_debug.dart "C:\path\to\pdf\folder"

// ignore_for_file: avoid_print

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:syncfusion_flutter_pdf/pdf.dart';

String _mb(int bytes) => '${(bytes / (1024 * 1024)).toStringAsFixed(0)} MB';

int _countBookmarks(PdfBookmarkBase base) {
  var n = 0;
  for (var i = 0; i < base.count; i++) {
    n++;
    final bm = base[i];
    if (bm.count > 0) n += _countBookmarks(bm);
  }
  return n;
}

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('usage: dart run tool/scan_debug.dart <folder>');
    exit(64);
  }
  final folder = args.first;
  final dir = Directory(folder);
  if (!dir.existsSync()) {
    stderr.writeln('folder not found: $folder');
    exit(66);
  }

  final pdfs = dir
      .listSync(recursive: true, followLinks: false)
      .whereType<File>()
      .where((f) => p.extension(f.path).toLowerCase() == '.pdf')
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  print('found ${pdfs.length} PDFs. start RSS=${_mb(ProcessInfo.currentRss)}');
  final sw = Stopwatch()..start();
  var totalBm = 0;

  for (var i = 0; i < pdfs.length; i++) {
    final f = pdfs[i];
    final sizeMb = (f.lengthSync() / (1024 * 1024)).toStringAsFixed(1);
    stdout.write('[${i + 1}/${pdfs.length}] ${p.basename(f.path)} '
        '(${sizeMb}MB) ... ');
    try {
      final bytes = f.readAsBytesSync();
      final doc = PdfDocument(inputBytes: bytes);
      final nbm = _countBookmarks(doc.bookmarks);
      final pages = doc.pages.count;

      // Mirror the real extractor's page-index build (a prime memory suspect).
      final pageIndex = <PdfPage, int>{};
      for (var pi = 0; pi < pages; pi++) {
        pageIndex[doc.pages[pi]] = pi;
      }

      doc.dispose();
      totalBm += nbm;
      print('$nbm bm, $pages pages | total bm=$totalBm '
          '| RSS=${_mb(ProcessInfo.currentRss)}');
    } catch (e, st) {
      print('ERROR: $e');
      stderr.writeln(st);
    }
  }

  print('DONE in ${sw.elapsedMilliseconds}ms | total bookmarks=$totalBm '
      '| final RSS=${_mb(ProcessInfo.currentRss)}');
}
