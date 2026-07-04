import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'native_folder_picker.dart';

/// Picks a folder. Tries the native Windows Explorer-style dialog first; if it
/// fails unexpectedly, falls back to the in-app browser. A user cancel of the
/// native dialog just returns null (no fallback).
Future<String?> pickFolder(BuildContext context, {String? initial}) async {
  try {
    return nativePickFolder();
  } catch (_) {
    if (!context.mounted) return null;
    return pickFolderInApp(context, initial: initial);
  }
}

/// In-app folder browser (fallback). Pure dart:io + Flutter, RTL, keyboard-driven.
Future<String?> pickFolderInApp(BuildContext context, {String? initial}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _FolderPickerDialog(initial: initial),
  );
}

class _Entry {
  final String name;
  final String path; // for the ".." entry, empty means "go to drives list"
  final bool isUp;
  const _Entry(this.name, this.path, {this.isUp = false});
}

class _FolderPickerDialog extends StatefulWidget {
  const _FolderPickerDialog({this.initial});
  final String? initial;

  @override
  State<_FolderPickerDialog> createState() => _FolderPickerDialogState();
}

class _FolderPickerDialogState extends State<_FolderPickerDialog> {
  String? _current; // null => showing the list of drives
  List<_Entry> _entries = const [];
  int _sel = 0;
  int _pdfCount = 0;
  int _subCount = 0;
  String? _error;

  final TextEditingController _pathCtrl = TextEditingController();
  final FocusNode _listFocus = FocusNode();
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    final start = widget.initial;
    _navigate((start != null && Directory(start).existsSync()) ? start : null);
  }

  @override
  void dispose() {
    _pathCtrl.dispose();
    _listFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  List<String> _drives() {
    final out = <String>[];
    for (var c = 'A'.codeUnitAt(0); c <= 'Z'.codeUnitAt(0); c++) {
      final path = '${String.fromCharCode(c)}:\\';
      if (Directory(path).existsSync()) out.add(path);
    }
    return out;
  }

  void _navigate(String? path) {
    setState(() {
      _error = null;
      _sel = 0;
      if (path == null || path.isEmpty) {
        _current = null;
        _pathCtrl.text = '';
        _pdfCount = 0;
        _subCount = 0;
        _entries = [for (final d in _drives()) _Entry(d, d)];
        return;
      }
      final dir = Directory(path);
      if (!dir.existsSync()) {
        _error = 'المسار غير موجود';
        return;
      }
      _current = p.normalize(path);
      _pathCtrl.text = _current!;
      final parent = p.dirname(_current!);
      final entries = <_Entry>[
        _Entry('..', parent == _current ? '' : parent, isUp: true),
      ];
      try {
        final children = dir.listSync(followLinks: false);
        final subs = children.whereType<Directory>().toList()
          ..sort((a, b) =>
              p.basename(a.path).toLowerCase().compareTo(p.basename(b.path).toLowerCase()));
        for (final s in subs) {
          final name = p.basename(s.path);
          if (name.startsWith(r'$')) continue; // skip $Recycle.Bin etc.
          entries.add(_Entry(name, s.path));
        }
        _subCount = subs.length;
        _pdfCount = children
            .whereType<File>()
            .where((f) => p.extension(f.path).toLowerCase() == '.pdf')
            .length;
      } catch (_) {
        _error = 'تعذّر فتح المجلد (صلاحيات؟)';
      }
      _entries = entries;
    });
    _scrollToSel();
  }

  void _scrollToSel() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      const itemExtent = 44.0;
      final target = (_sel * itemExtent) - 120;
      _scroll.animateTo(
        target.clamp(0.0, _scroll.position.maxScrollExtent),
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
      );
    });
  }

  void _moveSel(int delta) {
    if (_entries.isEmpty) return;
    setState(() => _sel = (_sel + delta).clamp(0, _entries.length - 1));
    _scrollToSel();
  }

  void _openEntry(_Entry e) {
    _navigate(e.isUp ? (e.path.isEmpty ? null : e.path) : e.path);
  }

  void _openSelected() {
    if (_sel >= 0 && _sel < _entries.length) _openEntry(_entries[_sel]);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.arrowDown) {
      _moveSel(1);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowUp) {
      _moveSel(-1);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.numpadEnter) {
      _openSelected();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.backspace) {
      _navigate(_current == null ? null : (p.dirname(_current!) == _current ? null : p.dirname(_current!)));
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.escape) {
      Navigator.of(context).pop();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final canSelect = _current != null;
    return AlertDialog(
      title: const Text('اختر مجلد الكتب'),
      contentPadding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      content: SizedBox(
        width: 580,
        height: 480,
        child: Column(
          children: [
            _pathBar(cs),
            const SizedBox(height: 8),
            Expanded(
              child: Focus(
                focusNode: _listFocus,
                autofocus: true,
                onKeyEvent: _onKey,
                child: Container(
                  decoration: BoxDecoration(
                    border: Border.all(color: cs.outlineVariant),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: _error != null
                      ? Center(child: Text(_error!, style: TextStyle(color: cs.error)))
                      : _list(cs),
                ),
              ),
            ),
            const SizedBox(height: 8),
            _hintBar(cs),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('إلغاء'),
        ),
        FilledButton.icon(
          onPressed: canSelect ? () => Navigator.of(context).pop(_current) : null,
          icon: const Icon(Icons.check),
          label: const Text('اختيار هذا المجلد'),
        ),
      ],
    );
  }

  Widget _pathBar(ColorScheme cs) {
    return Row(
      children: [
        IconButton(
          tooltip: 'الأقراص',
          icon: const Icon(Icons.storage),
          onPressed: () => _navigate(null),
        ),
        IconButton(
          tooltip: 'للأعلى',
          icon: const Icon(Icons.arrow_upward),
          onPressed: _current == null
              ? null
              : () => _navigate(p.dirname(_current!) == _current ? null : p.dirname(_current!)),
        ),
        Expanded(
          child: TextField(
            controller: _pathCtrl,
            style: const TextStyle(fontSize: 14),
            textDirection: TextDirection.ltr,
            decoration: InputDecoration(
              isDense: true,
              hintText: r'الصق مسارًا هنا، مثال: C:\Books',
              prefixIcon: const Icon(Icons.folder_open, size: 20),
            ),
            onSubmitted: (v) => _navigate(v.trim()),
          ),
        ),
      ],
    );
  }

  Widget _list(ColorScheme cs) {
    return ListView.builder(
      controller: _scroll,
      itemCount: _entries.length,
      itemExtent: 44,
      itemBuilder: (context, i) {
        final e = _entries[i];
        final selected = i == _sel;
        return InkWell(
          onTap: () {
            setState(() => _sel = i);
            _openEntry(e);
          },
          child: Container(
            color: selected ? cs.primaryContainer.withValues(alpha: 0.5) : null,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            alignment: AlignmentDirectional.centerStart,
            child: Row(
              children: [
                Icon(
                  e.isUp ? Icons.subdirectory_arrow_left : Icons.folder,
                  color: e.isUp
                      ? cs.onSurfaceVariant
                      : (Theme.of(context).brightness == Brightness.dark
                          ? Colors.amber.shade400
                          : Colors.amber.shade700),
                  size: 22,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    e.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _hintBar(ColorScheme cs) {
    final String text;
    if (_current == null) {
      text = 'اختر قرصًا للبدء';
    } else {
      text = 'هنا: $_pdfCount ملف PDF · $_subCount مجلد فرعي '
          '(الفحص يشمل المجلدات الفرعية)';
    }
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: Text(text, style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant)),
    );
  }
}
