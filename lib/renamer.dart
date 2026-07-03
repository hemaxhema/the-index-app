import 'dart:io';
import 'dart:isolate';
import 'dart:ui' show Offset;

import 'package:path/path.dart' as p;
import 'package:syncfusion_flutter_pdf/pdf.dart';

import 'models.dart';
import 'pdf_repair.dart';

/// Only PDFs have a rewritable outline; HTML "bookmarks" are just a filename
/// and can't be renamed/deleted in place, so mutation must skip them rather
/// than hand their path to the PDF parser.
bool _isPdfPath(String path) => p.extension(path).toLowerCase() == '.pdf';

/// Renames the outline bookmark(s) matching [topic] in every book it
/// occurs in, writing each affected PDF back to disk.
Future<void> renameTopicEverywhere({
  required LibraryIndex index,
  required Topic topic,
  required String newTitle,
}) async {
  final byBook = <String, List<Occurrence>>{};
  for (final o in topic.occurrences) {
    byBook.putIfAbsent(o.bookId, () => []).add(o);
  }
  for (final entry in byBook.entries) {
    final book = index.bookById(entry.key);
    if (book == null || !_isPdfPath(book.path)) continue;
    await renameBookmarksInFile(
        path: book.path, targets: entry.value, newTitle: newTitle);
  }
}

/// Renames [topic]'s bookmark(s) inside a single book, restricted to
/// [pages] — the specific chip the user acted on, since a topic can occur
/// at several pages within the same book (one chip per page).
Future<void> renameTopicInBook({
  required LibraryIndex index,
  required Topic topic,
  required String bookId,
  required List<int> pages,
  required String newTitle,
}) async {
  final book = index.bookById(bookId);
  if (book == null || !_isPdfPath(book.path)) return;
  final targets = topic.occurrences
      .where((o) => o.bookId == bookId && pages.contains(o.page))
      .toList();
  if (targets.isEmpty) return;
  await renameBookmarksInFile(path: book.path, targets: targets, newTitle: newTitle);
}

/// Rewrites the PDF outline at [path]: any bookmark whose (title, resolved
/// page) matches one of [targets] gets renamed to [newTitle]. Runs in a
/// background isolate and saves the file in place.
Future<void> renameBookmarksInFile({
  required String path,
  required List<Occurrence> targets,
  required String newTitle,
}) {
  final payload = [
    for (final o in targets) {'title': o.originalTitle, 'page': o.page},
  ];
  return Isolate.run(() => _renameInFile(path, payload, newTitle));
}

/// Deletes the outline bookmark(s) matching [topic] in every book it
/// occurs in, writing each affected PDF back to disk.
Future<void> deleteTopicEverywhere({
  required LibraryIndex index,
  required Topic topic,
}) async {
  final byBook = <String, List<Occurrence>>{};
  for (final o in topic.occurrences) {
    byBook.putIfAbsent(o.bookId, () => []).add(o);
  }
  for (final entry in byBook.entries) {
    final book = index.bookById(entry.key);
    if (book == null || !_isPdfPath(book.path)) continue;
    await deleteBookmarksInFile(path: book.path, targets: entry.value);
  }
}

/// Deletes [topic]'s bookmark(s) inside a single book, restricted to
/// [pages] — the specific chip the user acted on, since a topic can occur
/// at several pages within the same book (one chip per page).
Future<void> deleteTopicInBook({
  required LibraryIndex index,
  required Topic topic,
  required String bookId,
  required List<int> pages,
}) async {
  final book = index.bookById(bookId);
  if (book == null || !_isPdfPath(book.path)) return;
  final targets = topic.occurrences
      .where((o) => o.bookId == bookId && pages.contains(o.page))
      .toList();
  if (targets.isEmpty) return;
  await deleteBookmarksInFile(path: book.path, targets: targets);
}

/// Rewrites the PDF outline at [path]: any bookmark whose (title, resolved
/// page) matches one of [targets] gets removed. Runs in a background
/// isolate and saves the file in place.
Future<void> deleteBookmarksInFile({
  required String path,
  required List<Occurrence> targets,
}) {
  final payload = [
    for (final o in targets) {'title': o.originalTitle, 'page': o.page},
  ];
  return Isolate.run(() => _deleteInFile(path, payload));
}

/// Snapshot of a surviving bookmark, captured before the outline is
/// rebuilt (see [_deleteInFile]).
class _BookmarkSnapshot {
  _BookmarkSnapshot(this.title, this.page, this.mode, this.location,
      this.zoom, this.color, this.textStyle, this.isExpanded, this.children);

  final String title;
  final int page; // 1-based; -1 if unresolvable
  final PdfDestinationMode mode;
  final Offset location;
  final double zoom;
  final PdfColor color;
  final List<PdfTextStyle> textStyle;
  final bool isExpanded;
  final List<_BookmarkSnapshot> children;
}

/// Opens [path] for mutation, working around PDFs whose outline syncfusion
/// can't read directly (see pdf_repair.dart): hybrid xref + compressed
/// object streams (PDF 1.5+), seen in "مفهرس" library batches, make
/// syncfusion silently report zero bookmarks even though a real outline
/// exists. Blindly capturing/rebuilding from that would save an
/// emptied-out outline over the real one — so when the direct parse sees
/// no bookmarks, fall back to a qpdf-normalized copy instead. Returns the
/// document to mutate plus the temp file to delete afterward (null if none
/// was created).
(PdfDocument, String?) _openForMutation(String path) {
  final direct = PdfDocument(inputBytes: File(path).readAsBytesSync());
  if (direct.bookmarks.count > 0) return (direct, null);
  final normalized = normalizePdfViaQpdf(path);
  if (normalized == null) return (direct, null);
  final viaQpdf = PdfDocument(inputBytes: File(normalized).readAsBytesSync());
  if (viaQpdf.bookmarks.count > 0) {
    direct.dispose();
    return (viaQpdf, normalized);
  }
  viaQpdf.dispose();
  try {
    File(normalized).deleteSync();
  } catch (_) {}
  return (direct, null);
}

// PdfBookmarkBase.removeAt() performs in-place linked-list surgery on the
// PDF's outline dictionaries, and its handling of sibling Next/Prev
// pointers is unreliable across edge cases (e.g. removing the first
// child, or removing several siblings in one pass) — it can leave
// neighboring bookmarks pointing at stale/incorrect titles or
// destinations. To avoid that, deletion instead snapshots every
// surviving bookmark, clears the whole outline, and rebuilds it via
// add(), the same well-exercised path used to author outlines from
// scratch.
void _deleteInFile(String path, List<Map<String, dynamic>> targets) {
  final remaining = [
    for (final t in targets) (t['title'] as String, t['page'] as int),
  ];
  final (doc, tempPath) = _openForMutation(path);
  try {
    // Callers only ever pass a bookId the scanner found real bookmarks in
    // (see scanner.dart, which skips PDFs with an empty outline), so seeing
    // zero here — even after the qpdf fallback — always means the parse
    // failed, never a genuinely empty outline. Refuse to save: doing so
    // would silently replace the real outline with nothing.
    if (doc.bookmarks.count == 0) {
      throw StateError('could not read outline for $path; refusing to save');
    }
    final pageIndex = <PdfPage, int>{};
    for (var i = 0; i < doc.pages.count; i++) {
      pageIndex[doc.pages[i]] = i;
    }

    _BookmarkSnapshot? capture(PdfBookmark bm) {
      final title = bm.title.trim();
      var page = -1;
      PdfDestinationMode mode = PdfDestinationMode.location;
      Offset location = Offset.zero;
      double zoom = 0;
      try {
        final dest = bm.destination;
        if (dest != null) {
          page = (pageIndex[dest.page] ?? -1) + 1;
          mode = dest.mode;
          location = dest.location;
          zoom = dest.zoom;
        }
      } catch (_) {
        // Unresolvable destination; leave page = -1 (won't match, kept as-is).
      }
      final idx = remaining.indexWhere((t) => t.$1 == title && t.$2 == page);
      if (idx != -1) {
        remaining.removeAt(idx);
        return null; // dropped, along with its subtree
      }
      final children = <_BookmarkSnapshot>[];
      for (var i = 0; i < bm.count; i++) {
        final child = capture(bm[i]);
        if (child != null) children.add(child);
      }
      return _BookmarkSnapshot(bm.title, page, mode, location, zoom, bm.color,
          bm.textStyle, bm.isExpanded, children);
    }

    final roots = <_BookmarkSnapshot>[];
    for (var i = 0; i < doc.bookmarks.count; i++) {
      final snap = capture(doc.bookmarks[i]);
      if (snap != null) roots.add(snap);
    }

    doc.bookmarks.clear();

    void rebuild(PdfBookmarkBase parent, List<_BookmarkSnapshot> nodes) {
      for (final n in nodes) {
        final bm = parent.add(n.title,
            isExpanded: n.isExpanded, color: n.color, textStyle: n.textStyle);
        if (n.page >= 1 && n.page <= doc.pages.count) {
          bm.destination = PdfDestination(doc.pages[n.page - 1], n.location)
            ..mode = n.mode
            ..zoom = n.zoom;
        }
        rebuild(bm, n.children);
      }
    }

    rebuild(doc.bookmarks, roots);
    File(path).writeAsBytesSync(doc.saveSync());
  } finally {
    doc.dispose();
    if (tempPath != null) {
      try {
        File(tempPath).deleteSync();
      } catch (_) {}
    }
  }
}

void _renameInFile(String path, List<Map<String, dynamic>> targets, String newTitle) {
  final remaining = [
    for (final t in targets) (t['title'] as String, t['page'] as int),
  ];
  final (doc, tempPath) = _openForMutation(path);
  try {
    // See the matching guard in _deleteInFile: zero bookmarks here always
    // means a failed parse, not a genuinely empty outline.
    if (doc.bookmarks.count == 0) {
      throw StateError('could not read outline for $path; refusing to save');
    }
    final pageIndex = <PdfPage, int>{};
    for (var i = 0; i < doc.pages.count; i++) {
      pageIndex[doc.pages[i]] = i;
    }

    void walk(PdfBookmarkBase base) {
      for (var i = 0; i < base.count; i++) {
        final bm = base[i];
        final title = bm.title.trim();
        var page = -1;
        try {
          final dest = bm.destination;
          if (dest != null) page = (pageIndex[dest.page] ?? -1) + 1;
        } catch (_) {
          // Unresolvable destination; leave page = -1 (won't match).
        }
        final idx = remaining.indexWhere((t) => t.$1 == title && t.$2 == page);
        if (idx != -1) {
          bm.title = newTitle;
          remaining.removeAt(idx);
        }
        if (bm.count > 0) walk(bm);
      }
    }

    walk(doc.bookmarks);
    File(path).writeAsBytesSync(doc.saveSync());
  } finally {
    doc.dispose();
    if (tempPath != null) {
      try {
        File(tempPath).deleteSync();
      } catch (_) {}
    }
  }
}
