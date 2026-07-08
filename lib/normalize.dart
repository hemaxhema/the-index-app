// Arabic-aware normalization for grouping "nearly identical" bookmark titles.
//
// Two titles that differ only by diacritics, tatweel, alef/ya/ta-marbuta
// spelling variants, punctuation, digit script, or whitespace collapse to the
// same key so the same chapter across two books lands in one row.

// Arabic diacritics (harakat, tanwin, shadda, sukun, superscript alef, etc.).
final RegExp _diacritics = RegExp(
  '[ؐ-ًؚ-ٰٟۖ-ۜ۟-۪ۨ-ۭ]',
);

// Tatweel / kashida (used only for justification, never meaning).
const String _tatweel = 'ـ';

// Arabic-Indic and Extended Arabic-Indic digits -> ASCII.
const Map<String, String> _digitMap = {
  '٠': '0', '١': '1', '٢': '2', '٣': '3', '٤': '4',
  '٥': '5', '٦': '6', '٧': '7', '٨': '8', '٩': '9',
  '۰': '0', '۱': '1', '۲': '2', '۳': '3', '۴': '4',
  '۵': '5', '۶': '6', '۷': '7', '۸': '8', '۹': '9',
};

// Punctuation (ASCII + common Arabic) treated as separators.
final RegExp _punct = RegExp(
  r'''[،؛؟٪-٭۔!-/:-@\[-`{-~"'’‘“”—–…]''',
);

final RegExp _ws = RegExp(r'\s+');

/// Strip Arabic diacritics (harakat, tanwin, shadda...) and tatweel from
/// [input]. Shared by [normalizeTitle] and the dictionary-mode root-letter
/// transform (see `dictionary_mode.dart`).
String stripDiacritics(String input) =>
    input.replaceAll(_diacritics, '').replaceAll(_tatweel, '');

/// Produce the grouping key for a bookmark title.
String normalizeTitle(String input) {
  var s = input.trim();
  if (s.isEmpty) return '';

  // Strip diacritics and tatweel.
  s = stripDiacritics(s);

  // Unify letter spelling variants.
  final buf = StringBuffer();
  for (final ch in s.split('')) {
    switch (ch) {
      case 'أ': // أ
      case 'إ': // إ
      case 'آ': // آ
      case 'ٱ': // ٱ
      case 'ؤ': // ؤ
      case 'ئ': // ئ
        buf.write('ا'); // ا
        break;
      case 'ى': // ى (alef maksura)
        buf.write('ي'); // ي
        break;
      case 'ة': // ة (ta marbuta)
        buf.write('ه'); // ه
        break;
      default:
        buf.write(ch);
    }
  }
  s = buf.toString();

  // Normalize digits, then treat punctuation as spaces.
  final sb = StringBuffer();
  for (final ch in s.split('')) {
    sb.write(_digitMap[ch] ?? ch);
  }
  s = sb.toString().replaceAll(_punct, ' ');

  // Lowercase (for any Latin text) and collapse whitespace.
  s = s.toLowerCase().replaceAll(_ws, ' ').trim();
  return s;
}

// Matches a leading number, optionally with '.' or '-' separated groups
// (e.g. "3", "3.10", "2-1"), in ASCII or Arabic-Indic digits.
final RegExp _leadingNumber =
    RegExp(r'^\s*([0-9٠-٩۰-۹]+(?:[.\-][0-9٠-٩۰-۹]+)*)');

/// If [s] begins with a number (ASCII or Arabic-Indic), returns its
/// dot/dash-separated components as integers (e.g. "3.10" -> [3, 10]);
/// otherwise null. Lets numbered chapters sort before textual ones, min→max,
/// with "10" after "2" (numeric, not lexical).
List<int>? leadingNumber(String s) {
  final m = _leadingNumber.firstMatch(s);
  if (m == null) return null;
  final out = <int>[];
  for (final part in m.group(1)!.split(RegExp(r'[.\-]'))) {
    final sb = StringBuffer();
    for (final ch in part.split('')) {
      sb.write(_digitMap[ch] ?? ch);
    }
    final v = int.tryParse(sb.toString());
    if (v != null) out.add(v);
  }
  return out.isEmpty ? null : out;
}

