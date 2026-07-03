import 'package:flutter_test/flutter_test.dart';

import 'package:bookmark_index/dictionary_mode.dart';
import 'package:bookmark_index/main.dart';
import 'package:bookmark_index/models.dart';
import 'package:bookmark_index/normalize.dart';

void main() {
  testWidgets('App boots and shows the search hint', (tester) async {
    await tester.pumpWidget(const BookmarkIndexApp());
    await tester.pump();
    expect(find.text('فهرس الفهارس'), findsOneWidget);
    expect(find.text('ابحث عن فصل أو موضوع…'), findsOneWidget);
  });

  group('Arabic normalization groups equivalent titles', () {
    test('diacritics and tatweel are ignored', () {
      expect(normalizeTitle('الْمُبْتَدَأ'), normalizeTitle('المبتدا'));
      expect(normalizeTitle('الفـــعل'), normalizeTitle('الفعل'));
    });

    test('alef / ya / ta-marbuta variants unify', () {
      expect(normalizeTitle('إعراب'), normalizeTitle('اعراب'));
      expect(normalizeTitle('الكبرى'), normalizeTitle('الكبري'));
      expect(normalizeTitle('الجملة'), normalizeTitle('الجمله'));
    });

    test('whitespace, punctuation and digits normalize', () {
      expect(normalizeTitle('الباب ٣: النواسخ'), normalizeTitle('الباب 3 النواسخ'));
      expect(normalizeTitle('  الفعل   الماضي '), normalizeTitle('الفعل الماضي'));
    });

    test('distinct topics stay distinct', () {
      expect(normalizeTitle('المبتدأ') == normalizeTitle('الخبر'), isFalse);
    });
  });

  group('leadingNumber', () {
    test('parses ASCII, Arabic-Indic and dotted numbers', () {
      expect(leadingNumber('10 النواسخ'), [10]);
      expect(leadingNumber('٣ - المبتدأ'), [3]);
      expect(leadingNumber('3.10 الجملة'), [3, 10]);
    });
    test('returns null for text-first titles', () {
      expect(leadingNumber('الفعل الماضي'), isNull);
      expect(leadingNumber('الباب 3'), isNull);
    });
  });

  group('dictionary mode folder detection', () {
    test('recognizes Arabic and Latin markers anywhere in the path', () {
      expect(isDictionaryFolder(r'C:\books\معجم الوسيط'), isTrue);
      expect(isDictionaryFolder(r'C:\books\معاجم اللغة'), isTrue);
      expect(isDictionaryFolder(r'C:\books\moajm-lisan'), isTrue);
      expect(isDictionaryFolder(r'C:\books\Arabic Dict'), isTrue);
      expect(isDictionaryFolder(r'C:\books\dictionary'), isTrue);
      expect(isDictionaryFolder(r'C:\books\grammar'), isFalse);
    });
  });

  group('dictionary root-letter transform', () {
    test('two-letter root repeats its last letter', () {
      expect(dictionaryRootForm('عض'), 'عضض');
    });

    test('four-letter ABAB pattern drops the third letter', () {
      expect(dictionaryRootForm('عضعض'), 'عضض');
    });

    test('a plain three-letter root passes through unchanged', () {
      expect(dictionaryRootForm('عضض'), 'عضض');
    });

    test('weak letters ا/ي/ى unify to و', () {
      expect(dictionaryRootForm('نام'), 'نوم');
    });

    test('hamza carriers unify to a bare ء', () {
      expect(dictionaryRootForm('سبأ'), 'سبء');
    });

    test('spaces are removed entirely, not just collapsed', () {
      expect(dictionaryRootForm('ع ض'), 'عضض');
      expect(dictionaryRootForm(' ع ض ع ض '), 'عضض');
    });
  });

  test('dictionary-mode folders group root spellings into one topic', () {
    Occurrence occ(String bookId, String title) =>
        Occurrence(bookId: bookId, originalTitle: title, page: 1, level: 0);
    final idx = LibraryIndex.build(
      folder: r'C:\books\معجم الوسيط',
      books: const [
        Book(id: 'a', path: 'a.pdf', title: 'a'),
        Book(id: 'b', path: 'b.pdf', title: 'b'),
        Book(id: 'c', path: 'c.pdf', title: 'c'),
      ],
      occurrences: [occ('a', 'عض'), occ('b', 'عضعض'), occ('c', 'عضض')],
    );
    expect(idx.topics, hasLength(1));
    final t = idx.topics.single;
    expect(t.display, 'عضض');
    expect(t.bookCount, 3);
    // Each book kept its own original spelling for the chip label.
    final byBook = {for (final h in t.byBook) h.bookId: h.distinctOriginalTitles};
    expect(byBook['a'], ['عض']);
    expect(byBook['b'], ['عضعض']);
    expect(byBook['c'], ['عضض']);
  });

  test('topics sort: numbers ascending first, then Arabic alphabetical', () {
    Occurrence occ(String title) =>
        Occurrence(bookId: 'b', originalTitle: title, page: 1, level: 0);
    final idx = LibraryIndex.build(
      folder: 'x',
      books: const [Book(id: 'b', path: 'b.pdf', title: 'b')],
      occurrences: [occ('الخبر'), occ('2 مقدمة'), occ('المبتدأ'), occ('10 خاتمة'), occ('١ تمهيد')],
    );
    final order = idx.topics.map((t) => t.display).toList();
    // 1, 2, 10 come first in numeric order, then the two text titles A→Z.
    expect(order.sublist(0, 3), ['١ تمهيد', '2 مقدمة', '10 خاتمة']);
    expect(order.sublist(3), ['الخبر', 'المبتدأ']);
  });
}
