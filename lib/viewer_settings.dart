import 'package:flutter/material.dart';

import 'native_folder_picker.dart';
import 'store.dart';
import 'viewer.dart';

/// Opens the "PDF viewer" settings dialog, letting the user pick which
/// program opens PDFs (SumatraPDF or Foxit Reader/Editor) and its path.
Future<void> showViewerSettingsDialog(BuildContext context) async {
  await showDialog<void>(
    context: context,
    builder: (_) => const _ViewerSettingsDialog(),
  );
  Viewer.invalidateCache();
}

class _ViewerSettingsDialog extends StatefulWidget {
  const _ViewerSettingsDialog();

  @override
  State<_ViewerSettingsDialog> createState() => _ViewerSettingsDialogState();
}

class _ViewerSettingsDialogState extends State<_ViewerSettingsDialog> {
  late ViewerKind _kind;
  late final TextEditingController _sumatraCtrl;
  late final TextEditingController _foxitCtrl;
  late final TextEditingController _chromeCtrl;

  @override
  void initState() {
    super.initState();
    _kind = Viewer.kind;
    _sumatraCtrl = TextEditingController(text: Store.instance.viewerPath ?? '');
    _foxitCtrl = TextEditingController(text: Store.instance.foxitPath ?? '');
    _chromeCtrl = TextEditingController(text: Store.instance.chromePath ?? '');
  }

  @override
  void dispose() {
    _sumatraCtrl.dispose();
    _foxitCtrl.dispose();
    _chromeCtrl.dispose();
    super.dispose();
  }

  Future<void> _browse(TextEditingController ctrl) async {
    try {
      final picked = nativePickExecutable();
      if (picked != null) setState(() => ctrl.text = picked);
    } catch (_) {
      // Native dialog unavailable; user can still type/paste a path.
    }
  }

  void _save() {
    Store.instance
      ..viewerKind = _kind.name
      ..viewerPath = _sumatraCtrl.text.trim()
      ..foxitPath = _foxitCtrl.text.trim()
      ..chromePath = _chromeCtrl.text.trim();
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('إعدادات عارض الPDF'),
      content: SizedBox(
        width: 520, 
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _kindTile(ViewerKind.sumatra, 'SumatraPDF (موصى به)'),
              if (_kind == ViewerKind.sumatra)
                _pathRow(_sumatraCtrl, hint: r'لتحديد مسار خاص أدخل مسار ملف SumatraPDF.exe'),
              _kindTile(ViewerKind.foxit, 'Foxit Reader / Editor'),
              if (_kind == ViewerKind.foxit)
                _pathRow(_foxitCtrl,
                    hint: r'لتحديد مسار خاص أدخل مسار ملف FoxitPDFEditor.exe أو نحوه'),
              _kindTile(ViewerKind.chrome, 'Chrome'),
              if (_kind == ViewerKind.chrome)
                _pathRow(_chromeCtrl,
                    hint: r'لتحديد مسار خاص أدخل مسار ملف chrome.exe'),
              const SizedBox(height: 8),
              Text(
                _kind == ViewerKind.sumatra && Viewer.noExplicitPreference
                    ? 'إن لم يُعثر على SumatraPDF، ستتم تجربة Foxit Reader/Editor ثم Chrome قبل الرجوع إلى المتصفح الافتراضي.'
                    : 'إن لم يُعثر على البرنامج، سيُفتح الملف في المتصفح الافتراضي بدلًا منه.',
                style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12.5),
              ),
              const SizedBox(height: 4),
              Text(
                'الحالة الحالية: ${Viewer.describeBackend()}',
                style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12.5),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('إلغاء')),
        FilledButton(onPressed: _save, child: const Text('حفظ')),
      ],
    );
  }

  Widget _kindTile(ViewerKind value, String title) {
    return RadioListTile<ViewerKind>(
      value: value,
      // ignore: deprecated_member_use
      groupValue: _kind,
      // ignore: deprecated_member_use
      onChanged: (v) => setState(() => _kind = v!),
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text(title),
    );
  }

  Widget _pathRow(TextEditingController ctrl, {required String hint}) {
    return Padding(
      padding: const EdgeInsets.only(right: 32, bottom: 8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: ctrl,
              style: const TextStyle(fontSize: 13),
              textDirection: TextDirection.ltr,
              decoration: InputDecoration(hintText: hint, isDense: true),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            tooltip: 'استعراض',
            icon: const Icon(Icons.folder_open),
            onPressed: () => _browse(ctrl),
          ),
          IconButton(
            tooltip: 'مسح',
            icon: const Icon(Icons.clear),
            onPressed: () => setState(() => ctrl.clear()),
          ),
        ],
      ),
    );
  }
}
