import 'package:flutter/material.dart';

/// Day (light) and night (dark navy) themes for the app.
class AppTheme {
  AppTheme._();

  // Night palette — softer navy.
  static const Color _nightBackground = Color(0xFF12172B);
  static const Color _nightFieldFill = Color(0xFF1E2540);
  static const Color _nightBorder = Color(0xFF313A5E);
  static const Color _nightText = Color(0xFFF0F2FA);
  static const Color _nightHint = Color(0xFF9AA3C0);

  // Day palette — light, same boxed input style.
  static const Color _dayBackground = Color(0xFFF7F8FC);
  static const Color _dayFieldFill = Color(0xFFEEF1F8);
  static const Color _dayBorder = Color(0xFFD7DBEA);
  static const Color _dayText = Color(0xFF1A1A2E);
  static const Color _dayHint = Color(0xFF6B7280);

  static const Color accent = Color(0xFF2D6CDF);

  static final ThemeData night = _build(
    brightness: Brightness.dark,
    background: _nightBackground,
    fieldFill: _nightFieldFill,
    border: _nightBorder,
    text: _nightText,
    hint: _nightHint,
  );

  static final ThemeData day = _build(
    brightness: Brightness.light,
    background: _dayBackground,
    fieldFill: _dayFieldFill,
    border: _dayBorder,
    text: _dayText,
    hint: _dayHint,
  );

  static ThemeData _build({
    required Brightness brightness,
    required Color background,
    required Color fieldFill,
    required Color border,
    required Color text,
    required Color hint,
  }) {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: accent,
      brightness: brightness,
    ).copyWith(
      primary: accent,
      surface: background,
      onSurface: text,
      surfaceContainerHighest: fieldFill,
      outline: hint,
      outlineVariant: border,
      onSurfaceVariant: hint,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: background,
      dividerTheme: DividerThemeData(color: border),
      appBarTheme: AppBarTheme(
        backgroundColor: background,
        foregroundColor: text,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: fieldFill,
        hintStyle: TextStyle(color: hint),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: accent, width: 1.5),
        ),
      ),
    );
  }
}
