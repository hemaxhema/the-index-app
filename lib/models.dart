import 'package:path/path.dart' as p;

import 'dictionary_mode.dart';
import 'normalize.dart';

/// A single PDF file in the scanned folder.
class Book {
  final String id; // stable id = file path
  final String path;
  final String title; // display name (file name without extension)

  const Book({required this.id, required this.path, required this.title});

  Map<String, dynamic> toJson() => {'id': id, 'path': path, 'title': title};

  factory Book.fromJson(Map<String, dynamic> j) => Book(
        id: j['id'] as String,
        path: j['path'] as String,
        title: j['title'] as String,
      );
}

/// One occurrence of a topic inside a specific book.
class Occurrence {
  final String bookId;
  final String originalTitle; // the raw bookmark text as it appears in the PDF
  final int page; // 1-based physical page number; -1 if unresolved
  final int level; // outline depth (0 = top level)

  const Occurrence({
    required this.bookId,
    required this.originalTitle,
    required this.page,
    required this.level,
  });

  Map<String, dynamic> toJson() => {
        'bookId': bookId,
        'originalTitle': originalTitle,
        'page': page,
        'level': level,
      };

  factory Occurrence.fromJson(Map<String, dynamic> j) => Occurrence(
        bookId: j['bookId'] as String,
        originalTitle: j['originalTitle'] as String,
        page: j['page'] as int,
        level: j['level'] as int,
      );
}

/// One book's page(s) for a given topic.
class BookHit {
  final String bookId;
  final List<int> pages; // sorted, 1-based; may be empty if unresolved

  // The raw bookmark text as it appears in the PDF, aligned index-for-index
  // with [pages] (one original spelling per page). In dictionary mode a
  // topic's display title is the canonical root, so this is what lets the UI
  // show the actual spelling ("عض" vs "عضعض") found in each book.
  final List<String> originalTitles;

  const BookHit(this.bookId, this.pages, this.originalTitles);

  /// Distinct original spellings, in first-seen order.
  List<String> get distinctOriginalTitles => originalTitles.toSet().toList();
}

/// A topic: one normalized chapter/heading grouped across all books.
class Topic {
  final String key; // normalized key used for grouping
  final String display; // human-friendly title (first seen original)
  final List<Occurrence> occurrences;

  // User-chosen folder order (folder name, lowercased -> rank); see
  // Store.folderRank. Folders not present here sort after ranked ones.
  final Map<String, int> folderRank;

  Topic({
    required this.key,
    required this.display,
    required this.occurrences,
    this.folderRank = const {},
  });

  /// Occurrences collapsed to one entry per distinct (book, page) — a book
  /// with two separate bookmarks for this topic yields two chips instead of
  /// one chip listing both pages. Computed once since this is what the UI
  /// renders, and a title that repeats at the same page many times in a book
  /// should still yield a single chip instead of thousands.
  late final List<BookHit> byBook = _computeByBook();

  List<BookHit> _computeByBook() {
    final seenPagesByBook = <String, Set<int>>{};
    final hits = <BookHit>[];
    for (final o in occurrences) {
      if (o.page <= 0) continue;
      final seen = seenPagesByBook.putIfAbsent(o.bookId, () => <int>{});
      if (seen.add(o.page)) {
        hits.add(BookHit(o.bookId, [o.page], [o.originalTitle.trim()]));
      }
    }
    // Books whose occurrences all had unresolved pages (e.g. every HTML
    // "bookmark", which has no page) still get one placeholder chip so the
    // book isn't dropped from the row entirely — keep their original titles
    // instead of discarding them, since HTML chips show that text in place
    // of a page label.
    final unresolvedTitlesByBook = <String, List<String>>{};
    for (final o in occurrences) {
      if (o.page <= 0) {
        unresolvedTitlesByBook
            .putIfAbsent(o.bookId, () => [])
            .add(o.originalTitle.trim());
      }
    }
    for (final entry in unresolvedTitlesByBook.entries) {
      if (!seenPagesByBook.containsKey(entry.key)) {
        hits.add(BookHit(entry.key, const [], entry.value));
      }
    }
    // Order chips by the file's immediate parent folder, then book title, so
    // books from the same folder sit together. bookId is the file's full path;
    // memoize the derived keys per distinct path so a topic spanning thousands
    // of (book, page) pairs doesn't re-parse the path on every comparison.
    final folderOf = <String, String>{};
    final titleOf = <String, String>{};
    String folderKey(String id) =>
        folderOf[id] ??= p.basename(p.dirname(id)).toLowerCase();
    String titleKey(String id) =>
        titleOf[id] ??= p.basenameWithoutExtension(id).toLowerCase();

    hits.sort((a, b) {
      // Ranked folders (per the user's saved order) come first, in that
      // order; unranked folders fall back to alphabetical, which is also
      // what this reduces to when folderRank is empty (fa == fb == 0 always).
      final fa = folderRank[folderKey(a.bookId)] ?? folderRank.length;
      final fb = folderRank[folderKey(b.bookId)] ?? folderRank.length;
      if (fa != fb) return fa.compareTo(fb);
      final cf = folderKey(a.bookId).compareTo(folderKey(b.bookId));
      if (cf != 0) return cf;
      final ct = titleKey(a.bookId).compareTo(titleKey(b.bookId));
      if (ct != 0) return ct;
      final pa = a.pages.isNotEmpty ? a.pages.first : 0;
      final pb = b.pages.isNotEmpty ? b.pages.first : 0;
      final cp = pa.compareTo(pb);
      if (cp != 0) return cp;
      return a.bookId.compareTo(b.bookId); // deterministic final tiebreak
    });
    return hits;
  }

  /// Distinct books this topic appears in. Cached: it's read per row on every
  /// rebuild (badge + status bar), so recomputing the Set each time is wasteful.
  late final int bookCount = byBook.map((h) => h.bookId).toSet().length;
}

/// The whole index: books + grouped topics. Serializes to a cache file.
class LibraryIndex {
  final String folder;
  final DateTime builtAt;
  final List<Book> books;
  final List<Topic> topics;

  // User-chosen folder display order for this library (folder display
  // names, in order). Empty = alphabetical. Persisted with this index's
  // cache file, so each library keeps its own order (see lib/main.dart's
  // folder-order dialog and Store.saveCache/loadCache).
  final List<String> folderOrder;

  // True when [folder]'s name marks it as an Arabic-dictionary folder (see
  // dictionary_mode.dart), enabling root-letter bookmark grouping and the
  // "original word" chip label in the UI.
  bool get dictionaryMode => isDictionaryFolder(folder);

  // O(1) id -> book lookup. [bookById] is called for every chip of every
  // visible row on every rebuild, so a linear scan over [books] was a real
  // per-frame cost on large libraries.
  late final Map<String, Book> _bookById = {for (final b in books) b.id: b};

  // Topics shared by more than one book. Precomputed once instead of being
  // recounted (with a Set per topic) on every status-bar rebuild.
  late final int sharedTopicCount =
      topics.where((t) => t.bookCount > 1).length;

  LibraryIndex({
    required this.folder,
    required this.builtAt,
    required this.books,
    required this.topics,
    this.folderOrder = const [],
  });

  Book? bookById(String id) => _bookById[id];

  /// Build topics by grouping raw bookmarks on their normalized key.
  static LibraryIndex build({
    required String folder,
    required List<Book> books,
    required List<Occurrence> occurrences,
    List<String> folderOrder = const [],
  }) {
    final folderRank = {
      for (var i = 0; i < folderOrder.length; i++) folderOrder[i].toLowerCase(): i,
    };
    final dictionaryMode = isDictionaryFolder(folder);
    final groups = <String, List<Occurrence>>{};
    final display = <String, String>{};
    for (final o in occurrences) {
      // In dictionary-mode folders, group by root-letter form so spelling
      // variants of the same root (عض / عضض / عضعض) land in one topic; the
      // topic's display title becomes that canonical root.
      final grouped =
          dictionaryMode ? dictionaryRootForm(o.originalTitle) : o.originalTitle;
      final key = normalizeTitle(grouped);
      if (key.isEmpty) continue;
      groups.putIfAbsent(key, () => []).add(o);
      display.putIfAbsent(key, () => grouped.trim());
    }
    final topics = <Topic>[];
    groups.forEach((key, occ) {
      // Sort a topic's occurrences by book title for stable display.
      occ.sort((a, b) => a.bookId.compareTo(b.bookId));
      topics.add(Topic(
        key: key,
        display: display[key]!,
        occurrences: occ,
        folderRank: folderRank,
      ));
    });
    // Order: numbered chapters first, ascending by their number (so 2 < 10);
    // then textual (Arabic) chapters alphabetically.
    final nums = {for (final t in topics) t.key: leadingNumber(t.display)};
    topics.sort((a, b) {
      final an = nums[a.key];
      final bn = nums[b.key];
      if (an != null && bn == null) return -1; // numbers before text
      if (an == null && bn != null) return 1;
      if (an != null && bn != null) {
        final c = _compareNumbers(an, bn);
        if (c != 0) return c;
      }
      return a.key.compareTo(b.key); // alphabetical (Arabic) tiebreak
    });
    return LibraryIndex(
      folder: folder,
      builtAt: DateTime.now(),
      books: books,
      topics: topics,
      folderOrder: folderOrder,
    );
  }

  Map<String, dynamic> toJson() => {
        'folder': folder,
        'builtAt': builtAt.toIso8601String(),
        'books': books.map((b) => b.toJson()).toList(),
        // Store flat occurrences; topics are rebuilt on load so grouping logic
        // stays in one place and stays consistent if normalization changes.
        'occurrences': [
          for (final t in topics)
            for (final o in t.occurrences) o.toJson(),
        ],
        'folderOrder': folderOrder,
      };

  factory LibraryIndex.fromJson(Map<String, dynamic> j) {
    final books = (j['books'] as List)
        .map((e) => Book.fromJson(e as Map<String, dynamic>))
        .toList();
    final occ = (j['occurrences'] as List)
        .map((e) => Occurrence.fromJson(e as Map<String, dynamic>))
        .toList();
    final folderOrder = (j['folderOrder'] as List?)
            ?.map((e) => e as String)
            .toList() ??
        const [];
    final idx = LibraryIndex.build(
      folder: j['folder'] as String,
      books: books,
      occurrences: occ,
      folderOrder: folderOrder,
    );
    return LibraryIndex(
      folder: idx.folder,
      builtAt: DateTime.tryParse(j['builtAt'] as String? ?? '') ?? DateTime.now(),
      books: idx.books,
      topics: idx.topics,
      folderOrder: idx.folderOrder,
    );
  }

  /// Distinct immediate parent-folder names across [books], case-insensitively
  /// deduped and alphabetically sorted. Source list for the folder-order
  /// dialog (see lib/main.dart).
  List<String> get folderNames {
    final seen = <String>{};
    final names = <String>[];
    for (final b in books) {
      final name = p.basename(p.dirname(b.path));
      if (seen.add(name.toLowerCase())) names.add(name);
    }
    names.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return names;
  }

  /// Rebuilds topics with a new folder order, from the already-loaded books
  /// and occurrences — no rescan/disk work needed.
  LibraryIndex reordered(List<String> newOrder) => LibraryIndex.build(
        folder: folder,
        books: books,
        occurrences: [
          for (final t in topics) for (final o in t.occurrences) o,
        ],
        folderOrder: newOrder,
      );
}

/// Compares two dotted numbers component-wise (e.g. [3] < [3,2] < [10]).
int _compareNumbers(List<int> a, List<int> b) {
  final n = a.length < b.length ? a.length : b.length;
  for (var i = 0; i < n; i++) {
    final c = a[i].compareTo(b[i]);
    if (c != 0) return c;
  }
  return a.length.compareTo(b.length);
}
