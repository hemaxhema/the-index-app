import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

/// HRESULT for a cancelled common dialog: HRESULT_FROM_WIN32(ERROR_CANCELLED).
/// Derived via HRESULT.fromWin32 (not a hardcoded literal) because HRESULT is
/// a signed 32-bit value and a raw positive hex literal never equals the
/// negative value WindowsException.hr actually carries.
final HRESULT _cancelled = HRESULT.fromWin32(ERROR_CANCELLED);

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

/// Shows the native Windows file picker restricted to `.exe` files, for
/// choosing a PDF viewer executable.
///
/// Returns the selected file path, or null if the user cancelled. Throws on
/// unexpected COM failure so the caller can fall back to manual path entry.
String? nativePickExecutable() {
  final initHr = CoInitializeEx(
    COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE,
  );
  final needUninit = initHr == S_OK || initHr == S_FALSE;

  IFileOpenDialog? dialog;
  Pointer<COMDLG_FILTERSPEC>? spec;
  PWSTR? namePwstr;
  PWSTR? specPwstr;
  try {
    dialog = createInstance<IFileOpenDialog>(FileOpenDialog);
    namePwstr = 'برامج تنفيذية (*.exe)'.toPwstr();
    specPwstr = '*.exe'.toPwstr();
    spec = calloc<COMDLG_FILTERSPEC>();
    spec.ref.pszName = namePwstr;
    spec.ref.pszSpec = specPwstr;
    dialog.setFileTypes(1, spec);

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
    if (spec != null) calloc.free(spec);
    if (namePwstr != null) calloc.free(namePwstr);
    if (specPwstr != null) calloc.free(specPwstr);
    dialog?.release();
    if (needUninit) CoUninitialize();
  }
}
