import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import 'viewer.dart';

const _appName = 'فهرس الفهارس';
const _emailUrl = 'mailto:ibraheemabdullatif25@gmail.com';
const _emailText = 'ibraheemabdullatif25@gmail.com';
const _telegramUrl = 'https://t.me/ibraheem_abdullatif';
const _githubUrl = 'https://github.com/hemaxhema/the-index-app';

/// Opens the "حول البرنامج" dialog: app name, version (read from the
/// `version.txt` asset), and contact links.
Future<void> showAboutAppDialog(BuildContext context) async {
  await showDialog<void>(
    context: context,
    builder: (_) => const _AboutAppDialog(),
  );
}

class _AboutAppDialog extends StatefulWidget {
  const _AboutAppDialog();

  @override
  State<_AboutAppDialog> createState() => _AboutAppDialogState();
}

class _AboutAppDialogState extends State<_AboutAppDialog> {
  String? _version;

  @override
  void initState() {
    super.initState();
    rootBundle.loadString('version.txt').then((v) {
      if (mounted) setState(() => _version = v.trim());
    }).catchError((_) {});
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('حول البرنامج'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_appName, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            if (_version != null) ...[
              const SizedBox(height: 4),
              Text(
                'الإصدار: $_version',
                style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13),
              ),
            ],
            const SizedBox(height: 16),
            const _ContactRow(label: 'البريد الإلكتروني', url: _emailUrl, text: _emailText),
            const SizedBox(height: 8),
            const _ContactRow(label: 'تيليجرام', url: _telegramUrl, text: _telegramUrl),
            const SizedBox(height: 8),
            const _ContactRow(label: 'GitHub', url: _githubUrl, text: _githubUrl),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('إغلاق')),
      ],
    );
  }
}

/// An Arabic label followed by a tappable, underlined LTR URL/contact value.
class _ContactRow extends StatelessWidget {
  const _ContactRow({required this.label, required this.url, required this.text});

  final String label;
  final String url;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text('$label: '),
        Expanded(child: _Link(text: text, url: url)),
      ],
    );
  }
}

/// A tappable, underlined program name/URL that opens [url] in the default
/// browser/mail client.
class _Link extends StatelessWidget {
  const _Link({required this.text, required this.url});

  final String text;
  final String url;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => Viewer.openUrl(url),
        child: Text(
          text,
          textDirection: TextDirection.ltr,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: scheme.primary,
            fontWeight: FontWeight.w700,
            decoration: TextDecoration.underline,
            decorationColor: scheme.primary.withValues(alpha: 0.6),
          ),
        ),
      ),
    );
  }
}
