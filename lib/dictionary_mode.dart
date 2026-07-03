// "Dictionary mode": special bookmark grouping for folders of Arabic
// dictionaries (معجم / معاجم), where the same root can appear under several
// surface spellings — e.g. "عض", "عضض" and "عضعض" are all the root ع-ض-ض.
// Enabled per-folder by [isDictionaryFolder]; the transform itself is
// [dictionaryRootForm].

import 'normalize.dart' show stripDiacritics;

// Folder-name substrings (case-insensitive) that turn dictionary mode on.
const List<String> dictionaryFolderMarkers = [
  'معجم',
  'معاجم',
  'moajm',
  'dict',
  'dictionary',
];

/// True if [folderPath] (or any part of it, e.g. the picked folder's name)
/// suggests it holds Arabic dictionaries, enabling root-letter grouping.
bool isDictionaryFolder(String folderPath) {
  final name = folderPath.toLowerCase();
  return dictionaryFolderMarkers.any((m) => name.contains(m.toLowerCase()));
}

// Weak letters collapsed to their canonical root placeholder و.
const Map<String, String> _weakLetterMap = {'ا': 'و', 'ي': 'و', 'ى': 'و'};

// Hamza carriers collapsed to a bare hamza.
const Map<String, String> _hamzaMap = {
  'ؤ': 'ء',
  'ئ': 'ء',
  'أ': 'ء',
  'إ': 'ء',
  'آ': 'ء',
};

// Bare Arabic letters (no diacritics), used to detect pure root words.
final RegExp _arabicLettersOnly = RegExp(r'^[ء-ي]+$');

// Any whitespace, dropped entirely (not just collapsed) so "ع ض" reads as
// the same two-letter root as "عض".
final RegExp _whitespace = RegExp(r'\s+');

/// Collapse a dictionary bookmark title to its root-letter spelling:
/// - all spaces are removed ("ع ض" -> "عض")
/// - a two-letter root repeats its last letter ("عض" -> "عضض")
/// - a four-letter ABAB pattern drops the third letter ("عضعض" -> "عضض")
/// - weak letters ا/ي/ى unify to و, and hamza carriers ؤ/ئ/أ/إ/آ unify to ء
///
/// Applied only when [isDictionaryFolder] is true for the scanned folder, so
/// that spelling variants of the same root land in one topic.
String dictionaryRootForm(String input) {
  final s = stripDiacritics(input).replaceAll(_whitespace, '');
  var letters = s.split('');
  if (_arabicLettersOnly.hasMatch(s)) {
    if (letters.length == 2) {
      letters = [letters[0], letters[1], letters[1]];
    } else if (letters.length == 4 &&
        letters[0] == letters[2] &&
        letters[1] == letters[3]) {
      letters = [letters[0], letters[1], letters[3]];
    }
  }
  final buf = StringBuffer();
  for (final ch in letters) {
    buf.write(_weakLetterMap[ch] ?? _hamzaMap[ch] ?? ch);
  }
  return buf.toString();
}
