import 'package:flutter/material.dart';

import 'store.dart';
import 'viewer.dart';

const _sumatraUrl = 'https://www.sumatrapdfreader.org/download';
const _foxitUrl = 'https://www.foxit.com/ar/pdf-reader/';

/// Shows the one-time "install a PDF viewer" prompt if this is the app's first
/// run and neither SumatraPDF nor Foxit is installed. Safe to call on every
/// startup: it self-guards on the [Store.firstRunDone] flag.
Future<void> showViewerInstallPromptIfNeeded(BuildContext context) async {
  if (Store.instance.firstRunDone) return;
  // Mark first run complete unconditionally so the prompt only ever shows once,
  // even if a viewer is still missing on later launches.
  Store.instance.firstRunDone = true;
  if (Viewer.findSumatra() != null || Viewer.findFoxit() != null) return;
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (_) => const _ViewerInstallPromptDialog(),
  );
}

class _ViewerInstallPromptDialog extends StatelessWidget {
  const _ViewerInstallPromptDialog();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const bodyStyle = TextStyle(fontSize: 16, height: 1.6);
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      contentPadding: const EdgeInsets.fromLTRB(28, 28, 28, 12),
      actionsPadding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Tinted circular badge to give the dialog a clear, friendly header.
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: scheme.primary.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.picture_as_pdf_rounded,
              size: 34,
              color: scheme.primary,
            ),
          ),
          const SizedBox(height: 20),
          // The message mixes RTL Arabic with LTR program names. Flutter's bidi
          // reordering mangles a single Text.rich here, so lay the sentence out
          // as discrete widgets in an explicit RTL wrap (each run is a bidi
          // island). Spaces are baked into the Arabic segments so the trailing
          // period stays glued to "FoxitPDF".
          Wrap(
            textDirection: TextDirection.rtl,
            alignment: WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.center,
            runSpacing: 4,
            children: [
              const Text('لتجربة استعمال سَلِسَة يرجَى تثبيت برنامج ',
                  style: bodyStyle),
              _Link(text: 'SumatraPDF ', url: _sumatraUrl, style: bodyStyle),
              const Text(' أو برنامج ', style: bodyStyle),
              _Link(text: 'FoxitPDF', url: _foxitUrl, style: bodyStyle),
              const Text('.', style: bodyStyle),
            ],
          ),
        ],
      ),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(context),
          style: FilledButton.styleFrom(
            minimumSize: const Size(120, 44),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          child: const Text('حسنًا'),
        ),
      ],
    );
  }
}

/// A tappable, underlined program name that opens [url] in the default browser.
class _Link extends StatelessWidget {
  const _Link({required this.text, required this.url, required this.style});

  final String text;
  final String url;
  final TextStyle style;

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
          style: style.copyWith(
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
