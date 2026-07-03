import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

/// HRESULT for a cancelled common dialog: HRESULT_FROM_WIN32(ERROR_CANCELLED).
const int _cancelled = 0x800704C7;

/// Shows the modern native Windows folder picker (IFileOpenDialog, the
/// Explorer-style dialog).
///
/// Returns the selected folder path, or null if the user cancelled.
/// Throws on unexpected COM failure so the caller can fall back to another
/// picker.
String? nativePickFolder() {
  final initHr = CoInitializeEx(
    COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE,
  );
  final needUninit = initHr == S_OK || initHr == S_FALSE;

  IFileOpenDialog? dialog;
  try {
    dialog = createInstance<IFileOpenDialog>(FileOpenDialog);
    dialog.setOptions(dialog.getOptions() | FOS_PICKFOLDERS);

    try {
      dialog.show(null);
    } on WindowsException catch (e) {
      if (e.hr == _cancelled) return null; // user pressed Cancel
      rethrow;
    }

    final item = dialog.getResult();
    if (item == null) return null;
    try {
      final name = item.getDisplayName(SIGDN_FILESYSPATH);
      final path = name.cast<Utf16>().toDartString();
      CoTaskMemFree(name);
      return path;
    } finally {
      item.release();
    }
  } finally {
    dialog?.release();
    if (needUninit) CoUninitialize();
  }
}
