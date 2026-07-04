import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'models.dart';
import 'normalize.dart';
import 'renamer.dart';
import 'scanner.dart';
import 'store.dart';
import 'viewer.dart';
import 'folder_picker.dart';
import 'theme/app_theme.dart';
import 'viewer_settings.dart';

void main() => runApp(const BookmarkIndexApp());

/// Global day/night toggle. Day (light) mode is the normal/default mode.
final ValueNotifier<ThemeMode> appThemeMode = ValueNotifier(ThemeMode.light);

class BookmarkIndexApp extends StatelessWidget {
  const BookmarkIndexApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: appThemeMode,
      builder: (context, mode, _) {
        return MaterialApp(
          title: 'فهرس الفهارس',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.day(),
          darkTheme: AppTheme.night(),
          themeMode: mode,
          home: const Directionality(
            textDirection: TextDirection.rtl,
            child: HomePage(),
          ),
        );
      },
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final TextEditingController _searchCtrl = TextEditingController();
  late final FocusNode _searchFocus;
  final FocusNode _rootFocus = FocusNode(debugLabel: 'root');
  final ScrollController _scrollCtrl = ScrollController();

  // Debounces filtering so typing fast in a large library doesn't re-scan all
  // topics on every keystroke.
  Timer? _filterDebounce;

  // Cap chips rendered inline per row. A topic that appears on many
  // (book, page) pairs — common for dictionary roots — could otherwise build
  // thousands of chips in one Wrap, producing a monster row that stalls or
  // crashes the app when a scrollbar drag brings it into view. Overflow goes
  // behind a tappable "+N" chip that opens the full list.
  static const int _maxChipsPerRow = 12;

  // Every list row is laid out at this exact height. A uniform extent lets the
  // ListView map any scroll offset to a row index in O(1), so dragging the
  // scrollbar through thousands of rows is instant and never has to build the
  // rows in between (the old variable-height rows forced that walk, which
  // stalled and crashed the app on large libraries). Chips beyond one line go
  // to the "+N" dialog, so the content always fits this height.
  static const double _rowHeight = 88;

  LibraryIndex? _index;
  List<Topic> _filtered = const [];
  bool _loading = false;
  String? _status;
  int _selected = 0;
  bool _editingEnabled = true;
  bool _autoRefreshAfterEdit = true;

  @override
  void initState() {
    super.initState();
    _searchFocus = FocusNode(debugLabel: 'search', onKeyEvent: _onSearchKey);
    _searchCtrl.addListener(_onSearchChanged);
    // Defer to after the first frame so the initial setState calls in
    // _bootstrap/_applyFilter don't run during initState. Also explicitly grab
    // keyboard focus (autofocus alone is unreliable on Windows at startup).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _searchFocus.requestFocus();
      _bootstrap();
    });
  }

  @override
  void dispose() {
    _filterDebounce?.cancel();
    _searchCtrl.dispose();
    _searchFocus.dispose();
    _rootFocus.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  // Search box changed: coalesce bursts of keystrokes into a single filter
  // pass. Filtering re-scans every topic, so debouncing keeps typing smooth on
  // large libraries.
  void _onSearchChanged() {
    _filterDebounce?.cancel();
    _filterDebounce = Timer(const Duration(milliseconds: 120), _applyFilter);
  }

  Future<void> _bootstrap() async {
    final last = Store.instance.lastFolder;
    if (last == null) return;
    final cached = Store.instance.loadCache(last);
    if (cached != null) {
      setState(() => _index = cached);
      _applyFilter();
    } else {
      await _scan(last);
    }
  }

  Future<void> _chooseFolder() async {
    final picked = await pickFolder(
      context,
      initial: _index?.folder ?? Store.instance.lastFolder,
    );
    if (!mounted || picked == null) return;
    final cached = Store.instance.loadCache(picked);
    if (cached != null) {
      Store.instance.lastFolder = picked;
      setState(() {
        _index = cached;
        _selected = 0;
      });
      _applyFilter();
      _searchFocus.requestFocus();
    } else {
      await _scan(picked); // first time opening this folder
    }
  }

  Future<void> _scan(String folder) async {
    // Preserve this folder's custom order, disabled sources, and dictionary-
    // mode override across a rescan (refresh button, post-edit reload) —
    // those always rescan the folder already in _index. A brand-new folder
    // has no prior state to preserve.
    final samefolder = _index != null && _index!.folder == folder;
    final previousOrder = samefolder ? _index!.folderOrder : const <String>[];
    final previousDisabled = samefolder ? _index!.disabledFolders : const <String>{};
    final previousDictOverride = samefolder ? _index!.dictionaryModeOverride : null;
    setState(() {
      _loading = true;
      _status = 'يفحص ملفات PDF…';
    });
    try {
      final idx = await scanFolder(
        folder,
        folderOrder: previousOrder,
        disabledFolders: previousDisabled,
        dictionaryModeOverride: previousDictOverride,
      );
      Store.instance.lastFolder = folder;
      Store.instance.saveCache(idx);
      setState(() {
        _index = idx;
        _loading = false;
        _status = null;
        _selected = 0;
      });
      _applyFilter();
      _searchFocus.requestFocus(); // restore focus lost to the folder dialog
    } catch (e) {
      setState(() {
        _loading = false;
        _status = 'تعذّر الفحص: $e';
      });
    }
  }

  /// Seeds the folder-order dialog: saved order first (folders still present
  /// in the current index), then any newly-seen folders appended in
  /// alphabetical order.
  List<String> _orderedFolderNames() {
    final idx = _index;
    if (idx == null) return const [];
    final byLower = {for (final f in idx.folderNames) f.toLowerCase(): f};
    final result = <String>[];
    for (final saved in idx.folderOrder) {
      final match = byLower.remove(saved.toLowerCase());
      if (match != null) result.add(match);
    }
    result.addAll(byLower.values);
    return result;
  }

  /// Central "خيارات" dialog: gathers the actions/toggles that used to sit
  /// directly in the app bar (rescan, folder order, dictionary mode,
  /// auto-refresh, editing, PDF viewer settings, help) into one place.
  Future<void> _showOptionsDialog() async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('خيارات'),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ListTile(
                    leading: const Icon(Icons.refresh),
                    title: const Text('إعادة الفحص'),
                    enabled: !_loading && _index != null,
                    onTap: () {
                      Navigator.pop(ctx);
                      _scan(_index!.folder);
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.sort),
                    title: const Text('ترتيب المجلدات'),
                    enabled: !_loading && _index != null,
                    onTap: () {
                      Navigator.pop(ctx);
                      _showFolderOrderDialog();
                    },
                  ),
                  SwitchListTile(
                    secondary: Icon(
                      (_index?.dictionaryMode ?? false) ? Icons.auto_stories : Icons.auto_stories_outlined,
                    ),
                    title: const Text('وضع القاموس (تجميع حسب الجذر)'),
                    value: _index?.dictionaryMode ?? false,
                    onChanged: _index == null
                        ? null
                        : (_) {
                            _toggleDictionaryMode();
                            setDialogState(() {});
                          },
                  ),
                  SwitchListTile(
                    secondary: Icon(_autoRefreshAfterEdit ? Icons.sync : Icons.sync_disabled),
                    title: const Text('التحديث التلقائي بعد التعديل/الحذف'),
                    value: _autoRefreshAfterEdit,
                    onChanged: (v) {
                      setState(() => _autoRefreshAfterEdit = v);
                      setDialogState(() {});
                    },
                  ),
                  SwitchListTile(
                    secondary: Icon(_editingEnabled ? Icons.edit : Icons.edit_off),
                    title: const Text('تفعيل التعديل (إعادة تسمية / حذف)'),
                    value: _editingEnabled,
                    onChanged: (v) {
                      setState(() => _editingEnabled = v);
                      setDialogState(() {});
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.picture_as_pdf_outlined),
                    title: const Text('إعدادات عارض PDF'),
                    onTap: () {
                      Navigator.pop(ctx);
                      _showViewerSettings();
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.help_outline),
                    title: const Text('مساعدة واختصارات لوحة المفاتيح (F1)'),
                    onTap: () {
                      Navigator.pop(ctx);
                      _showHelpDialog();
                    },
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إغلاق')),
          ],
        ),
      ),
    );
  }

  Future<void> _showFolderOrderDialog() async {
    final order = _orderedFolderNames();
    final disabled = Set<String>.of(_index!.disabledFolders);
    final saved = await showDialog<(List<String>, Set<String>)>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('ترتيب المجلدات'),
          content: SizedBox(
            width: 420,
            height: 480,
            child: ReorderableListView.builder(
              buildDefaultDragHandles: false,
              itemCount: order.length,
              itemBuilder: (c, i) {
                final name = order[i];
                final isOn = !disabled.contains(name.toLowerCase());
                return ListTile(
                  key: ValueKey(name),
                  leading: Checkbox(
                    value: isOn,
                    onChanged: (v) => setDialogState(() {
                      if (v ?? true) {
                        disabled.remove(name.toLowerCase());
                      } else {
                        disabled.add(name.toLowerCase());
                      }
                    }),
                  ),
                  title: Text(
                    name,
                    style: isOn
                        ? null
                        : TextStyle(color: Theme.of(ctx).colorScheme.onSurfaceVariant),
                  ),
                  trailing: ReorderableDragStartListener(
                    index: i,
                    child: const Icon(Icons.drag_indicator),
                  ),
                );
              },
              onReorder: (oldIndex, newIndex) => setDialogState(() {
                if (newIndex > oldIndex) newIndex -= 1;
                final item = order.removeAt(oldIndex);
                order.insert(newIndex, item);
              }),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => setDialogState(() => disabled.clear()),
              child: const Text('تحديد الكل'),
            ),
            TextButton(
              onPressed: () => setDialogState(() {
                disabled
                  ..clear()
                  ..addAll(order.map((n) => n.toLowerCase()));
              }),
              child: const Text('إلغاء تحديد الكل'),
            ),
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, (order, disabled)),
              child: const Text('حفظ'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || saved == null) return;
    final (newOrder, newDisabled) = saved;
    setState(() => _index = _index!.reordered(newOrder, disabledFolders: newDisabled));
    Store.instance.saveCache(_index!); // persists the order with this folder's cache
    _applyFilter();
  }

  void _toggleDictionaryMode() {
    final idx = _index;
    if (idx == null) return;
    setState(() => _index = idx.withDictionaryMode(!idx.dictionaryMode));
    Store.instance.saveCache(_index!); // persists the override with this folder's cache
    _applyFilter();
  }

  void _applyFilter() {
    final idx = _index;
    final q = normalizeTitle(_searchCtrl.text);
    List<Topic> res;
    if (idx == null) {
      res = const [];
    } else if (q.isEmpty) {
      res = idx.topics;
    } else {
      final tokens = q.split(' ').where((t) => t.isNotEmpty).toList();
      res = idx.topics
          .where((t) => tokens.every((tok) => t.key.contains(tok)))
          .toList();
      // A bookmark whose key matches the search text exactly floats to the top.
      final exact = res.indexWhere((t) => t.key == q);
      if (exact > 0) res.insert(0, res.removeAt(exact));
    }
    setState(() {
      _filtered = res;
      _selected = 0; // any filter change selects the first result
    });
    // Bring the list back to the top so the (re)selected first item is visible.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) _scrollCtrl.jumpTo(0);
    });
  }

  // ---- keyboard ----

  Topic? get _current =>
      (_selected >= 0 && _selected < _filtered.length) ? _filtered[_selected] : null;

  void _move(int delta) {
    if (_filtered.isEmpty) return;
    setState(() => _selected = (_selected + delta).clamp(0, _filtered.length - 1));
    _ensureVisible();
  }

  void _ensureVisible() {
    if (!_scrollCtrl.hasClients) return;
    final pos = _scrollCtrl.position;
    // Rows are a fixed [_rowHeight], so the selected row's offset is exact —
    // no need to find its built widget. Center it in the viewport.
    final target = _selected * _rowHeight - (pos.viewportDimension - _rowHeight) / 2;
    _scrollCtrl.animateTo(
      target.clamp(0.0, pos.maxScrollExtent),
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOut,
    );
  }

  // If a debounced filter is still pending (fast typing followed immediately by
  // a shortcut), apply it now so [_current] reflects what's actually typed
  // before we act on it.
  void _flushFilter() {
    if (_filterDebounce?.isActive ?? false) {
      _filterDebounce!.cancel();
      _applyFilter();
    }
  }

  void _openNth(int i) {
    _flushFilter();
    final t = _current;
    if (t != null && i >= 0 && i < t.byBook.length) _openHit(t.byBook[i]);
  }

  /// Alt+E: open the "all books" dialog for the selected topic, as if its
  /// [_allBooksButton] had been tapped.
  void _openAllBooksForCurrent() {
    _flushFilter();
    final t = _current;
    if (t != null && t.byBook.length > 1) _showAllBooks(_selected, t);
  }

  Future<void> _openHit(BookHit hit) async {
    final book = _index?.bookById(hit.bookId);
    if (book == null) return;
    final page = hit.pages.isNotEmpty ? hit.pages.first : 1;
    await Viewer.open(book.path, page);
  }

  // ---- rename / delete ----

  Future<void> _showBookmarkMenu(
    Offset position, {
    required VoidCallback onRename,
    required VoidCallback onDelete,
  }) async {
    if (!_editingEnabled) return;
    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(position.dx, position.dy, position.dx, position.dy),
      items: const [
        PopupMenuItem(value: 'rename', child: Text('إعادة تسمية')),
        PopupMenuItem(value: 'delete', child: Text('حذف')),
      ],
    );
    if (selected == 'rename') onRename();
    if (selected == 'delete') onDelete();
  }

  Future<bool> _confirmDelete(String title) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('حذف الفهرس'),
        content: Text('هل تريد حذف "$title"؟ لا يمكن التراجع عن هذا الإجراء.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('حذف'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  Future<String?> _promptRename(String currentTitle) {
    final ctrl = TextEditingController(text: currentTitle);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('إعادة تسمية العنوان'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('حفظ'),
          ),
        ],
      ),
    );
  }

  /// Rename this topic's bookmark across every book it appears in.
  Future<void> _renameTopicRow(Topic t) async {
    final newTitle = await _promptRename(t.display);
    if (!mounted || newTitle == null || newTitle.isEmpty || newTitle == t.display) return;
    await _runRename(
        () => renameTopicEverywhere(index: _index!, topic: t, newTitle: newTitle));
  }

  /// Rename this topic's bookmark inside a single book only, scoped to the
  /// specific chip's page(s) so other pages of the same topic in this book
  /// (shown as separate chips) are left untouched.
  Future<void> _renameTopicChip(Topic t, BookHit hit) async {
    final current = hit.distinctOriginalTitles.isNotEmpty
        ? hit.distinctOriginalTitles.first
        : t.display;
    final newTitle = await _promptRename(current);
    if (!mounted || newTitle == null || newTitle.isEmpty || newTitle == current) return;
    await _runRename(() => renameTopicInBook(
        index: _index!, topic: t, bookId: hit.bookId, pages: hit.pages, newTitle: newTitle));
  }

  Future<void> _runRename(Future<void> Function() action) => _runMutation(
        action,
        progressText: 'إعادة التسمية…',
        errorPrefix: 'تعذّرت إعادة التسمية',
      );

  /// Delete this topic's bookmark across every book it appears in.
  Future<void> _deleteTopicRow(Topic t) async {
    if (!await _confirmDelete(t.display)) return;
    if (!mounted) return;
    await _runDelete(() => deleteTopicEverywhere(index: _index!, topic: t));
  }

  /// Delete this topic's bookmark inside a single book only, scoped to the
  /// specific chip's page(s) so other pages of the same topic in this book
  /// (shown as separate chips) are left untouched.
  Future<void> _deleteTopicChip(Topic t, BookHit hit) async {
    final current = hit.distinctOriginalTitles.isNotEmpty
        ? hit.distinctOriginalTitles.first
        : t.display;
    if (!await _confirmDelete(current)) return;
    if (!mounted) return;
    await _runDelete(() => deleteTopicInBook(
        index: _index!, topic: t, bookId: hit.bookId, pages: hit.pages));
  }

  Future<void> _runDelete(Future<void> Function() action) => _runMutation(
        action,
        progressText: 'الحذف…',
        errorPrefix: 'تعذّر الحذف',
      );

  Future<void> _runMutation(
    Future<void> Function() action, {
    required String progressText,
    required String errorPrefix,
  }) async {
    final folder = _index?.folder;
    if (folder == null) return;
    setState(() {
      _loading = true;
      _status = progressText;
    });
    try {
      await action();
      if (!mounted) return;
      if (_autoRefreshAfterEdit) {
        await _scan(folder); // rescan so the change reflects everywhere
      } else {
        setState(() {
          _loading = false;
          _status = null;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _status = '$errorPrefix: $e';
      });
    }
  }

  void _focusSearch() {
    _searchFocus.requestFocus();
    _searchCtrl.selection =
        TextSelection(baseOffset: 0, extentOffset: _searchCtrl.text.length);
  }

  /// Global shortcuts (work even while the search box is focused):
  /// Ctrl+F focuses search; Ctrl+1..9 opens the selected topic's Nth book;
  /// Alt+E opens the "all books" dialog for the selected topic; F1 opens the
  /// help dialog.
  /// Uses SingleActivator (via CallbackShortcuts) so Alt combos match reliably
  /// on Windows, where Alt+key arrives as a system key.
  Map<ShortcutActivator, VoidCallback> _globalShortcuts() {
    const topRow = [
      LogicalKeyboardKey.digit1, LogicalKeyboardKey.digit2,
      LogicalKeyboardKey.digit3, LogicalKeyboardKey.digit4,
      LogicalKeyboardKey.digit5, LogicalKeyboardKey.digit6,
      LogicalKeyboardKey.digit7, LogicalKeyboardKey.digit8,
      LogicalKeyboardKey.digit9,
    ];
    const numpad = [
      LogicalKeyboardKey.numpad1, LogicalKeyboardKey.numpad2,
      LogicalKeyboardKey.numpad3, LogicalKeyboardKey.numpad4,
      LogicalKeyboardKey.numpad5, LogicalKeyboardKey.numpad6,
      LogicalKeyboardKey.numpad7, LogicalKeyboardKey.numpad8,
      LogicalKeyboardKey.numpad9,
    ];
    final bindings = <ShortcutActivator, VoidCallback>{
      const SingleActivator(LogicalKeyboardKey.keyF, control: true): _focusSearch,
      const SingleActivator(LogicalKeyboardKey.keyE, alt: true):
          _openAllBooksForCurrent,
      const SingleActivator(LogicalKeyboardKey.f1): _showHelpDialog,
    };
    for (var i = 0; i < 9; i++) {
      bindings[SingleActivator(topRow[i], control: true)] = () => _openNth(i);
      bindings[SingleActivator(numpad[i], control: true)] = () => _openNth(i);
    }
    return bindings;
  }

  KeyEventResult _onSearchKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.arrowDown) {
      _move(1);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowUp) {
      _move(-1);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.escape) {
      _rootFocus.requestFocus();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored; // let text input through
  }

  KeyEventResult _onRootKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    if (_searchFocus.hasFocus) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.arrowDown) {
      _move(1);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowUp) {
      _move(-1);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.slash) {
      _focusSearch();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.escape) {
      _rootFocus.requestFocus();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // ---- UI ----

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return CallbackShortcuts(
      bindings: _globalShortcuts(),
      child: Listener(
        behavior: HitTestBehavior.translucent,
        // If the app subtree holds no focus (e.g. after returning from the PDF
        // viewer or the folder dialog), any click re-grabs it so shortcuts and
        // arrow keys work again without needing to click the search box.
        onPointerDown: (_) {
          if (!_rootFocus.hasFocus) _rootFocus.requestFocus();
        },
        child: Focus(
          focusNode: _rootFocus,
          onKeyEvent: _onRootKey,
          child: Scaffold(
        appBar: AppBar(
          title: const Text(
            'فهرس الفهارس',
            style: TextStyle(fontFamily: 'Typokar'),
          ),
          actions: [
            ValueListenableBuilder<ThemeMode>(
              valueListenable: appThemeMode,
              builder: (context, mode, _) {
                final isNight = mode == ThemeMode.dark;
                return IconButton(
                  tooltip: isNight ? 'الوضع النهاري' : 'الوضع الليلي',
                  icon: Icon(isNight ? Icons.light_mode : Icons.dark_mode),
                  onPressed: () => appThemeMode.value =
                      isNight ? ThemeMode.light : ThemeMode.dark,
                );
              },
            ),
            IconButton(
              tooltip: 'اختيار مجلد',
              icon: const Icon(Icons.folder_open),
              onPressed: _loading ? null : _chooseFolder,
            ),
            IconButton(
              tooltip: 'خيارات',
              icon: const Icon(Icons.settings_outlined),
              onPressed: _showOptionsDialog,
            ),
          ],
        ),
        body: Column(
          children: [
            _searchBar(cs),
            _statusBar(cs),
            const Divider(height: 1),
            Expanded(child: _body(cs)),
          ],
        ),
          ),
        ),
      ),
    );
  }

  Widget _searchBar(ColorScheme cs) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
      child: TextField(
        controller: _searchCtrl,
        focusNode: _searchFocus,
        autofocus: true,
        style: const TextStyle(fontSize: 16),
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          hintText: 'ابحث عن فصل أو موضوع…',
          prefixIcon: const Icon(Icons.search),
          suffixIcon: _searchCtrl.text.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => _searchCtrl.clear(),
                ),
        ),
      ),
    );
  }

  Widget _statusBar(ColorScheme cs) {
    final idx = _index;
    final String text;
    if (_loading) {
      text = _status ?? 'يعمل…';
    } else if (idx == null) {
      text = 'لم يتم اختيار مجلد بعد';
    } else {
      final matches = idx.sharedTopicCount;
      text =
          '${idx.books.length} كتاب · ${idx.topics.length} موضوع · $matches مشترك بين كتابين أو أكثر · العرض عبر ${Viewer.describeBackend()}';
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              _filtered.length != (idx?.topics.length ?? 0) && !_loading
                  ? 'النتائج: ${_filtered.length} — $text'
                  : text,
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12.5),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _body(ColorScheme cs) {
    if (_loading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(_status ?? 'يعمل…'),
          ],
        ),
      );
    }
    if (_index == null) {
      return _emptyState(
        icon: Icons.folder_open,
        title: 'اختر مجلد الكتب',
        subtitle: 'مجلد يحتوي على ملفات PDF مزوّدة بفهارس (Bookmarks)، أو ملفات HTML.',
        actionLabel: 'اختيار مجلد',
        onAction: _chooseFolder,
      );
    }
    if (_filtered.isEmpty) {
      return _emptyState(
        icon: Icons.search_off,
        title: 'لا توجد نتائج',
        subtitle: 'جرّب كلمات أقل أو تهجئة مختلفة.',
      );
    }
    // Fixed [_rowHeight] rows: the Scrollbar maps a drag position straight to a
    // scroll offset (offset / itemExtent = index) without building any rows in
    // between, so scrubbing through thousands of topics stays instant.
    return Scrollbar(
      controller: _scrollCtrl,
      child: ListView.builder(
        controller: _scrollCtrl,
        itemExtent: _rowHeight,
        itemCount: _filtered.length,
        itemBuilder: _buildRow,
      ),
    );
  }

  Widget _emptyState({
    required IconData icon,
    required String title,
    required String subtitle,
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 56, color: Theme.of(context).colorScheme.outline),
          const SizedBox(height: 12),
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onAction,
              icon: const Icon(Icons.folder_open),
              label: Text(actionLabel),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildRow(BuildContext context, int i) {
    final cs = Theme.of(context).colorScheme;
    final t = _filtered[i];
    final selected = i == _selected;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => setState(() => _selected = i),
      onSecondaryTapUp: (details) => _showBookmarkMenu(
        details.globalPosition,
        onRename: () => _renameTopicRow(t),
        onDelete: () => _deleteTopicRow(t),
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          color: selected ? cs.primaryContainer.withValues(alpha: 0.45) : null,
          border: Border(bottom: BorderSide(color: Theme.of(context).dividerColor)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            _bookBadge(t.bookCount, cs),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    t.display,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 6),
                  // A single, horizontally-scrollable line of chips keeps the
                  // row at [_rowHeight]. The "all books" button (outside this
                  // strip) is the guaranteed way to reach every book
                  // regardless of how many fit on screen.
                  SizedBox(
                    height: 38,
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          for (var j = 0;
                              j < t.byBook.length && j < _maxChipsPerRow;
                              j++) ...[
                            if (j > 0) const SizedBox(width: 8),
                            _bookChip(i, t, j, selected, cs),
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (t.byBook.length > 1) ...[
              const SizedBox(width: 8),
              _allBooksButton(i, t, t.byBook.length, cs),
            ],
          ],
        ),
      ),
    );
  }

  Widget _bookBadge(int count, ColorScheme cs) {
    final multi = count > 1;
    return Container(
      width: 34,
      height: 34,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: multi ? cs.primary : cs.surfaceContainerHighest,
        shape: BoxShape.circle,
      ),
      child: Text(
        '$count',
        style: TextStyle(
          color: multi ? cs.onPrimary : cs.onSurfaceVariant,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  /// The book name and trailing detail text for a chip: name "book", detail
  /// "ص 12" (or the original spelling in dictionary/HTML mode). Returned as
  /// two parts rather than one interpolated string so the caller lays them
  /// out explicitly (name on the right) instead of leaving their order to
  /// the Unicode bidi algorithm, which doesn't reliably keep two RTL text
  /// segments joined by "-" in typed order.
  (String, String) _chipLabelParts(BookHit hit) {
    final book = _index?.bookById(hit.bookId);
    final name = book?.title ?? hit.bookId;
    final String trailing;
    if (book != null && Viewer.isHtml(book.path)) {
      // HTML "books" are named after their folder (see scanner.dart), so the
      // page label (meaningless here) is replaced by the file's own title.
      trailing = hit.distinctOriginalTitles.join('، ');
    } else {
      // Dictionary mode groups by root letters, so the row title (t.display)
      // is a canonical root that may not match how the word is actually
      // spelled in this book — show that original spelling here instead.
      final wordPart = (_index?.dictionaryMode ?? false)
          ? '${hit.distinctOriginalTitles.join('، ')} - '
          : '';
      trailing = '$wordPart${_pagesLabel(hit.pages)}';
    }
    return (name, trailing);
  }

  /// Book chip label: name fixed on the right, detail fixed on the left
  /// (see [_chipLabelParts]). Shared by the inline chips and the "all books"
  /// dialog so both stay identical. Pass [constrained] when the parent gives
  /// this a bounded width (e.g. inside the dialog) so long text ellipsizes
  /// instead of overflowing; the inline chip strip scrolls horizontally with
  /// unbounded width, where a Flexible child would assert.
  Widget _chipLabel(BookHit hit, {bool constrained = false}) {
    final (name, trailing) = _chipLabelParts(hit);
    Widget nameText = Text(name, maxLines: 1, overflow: TextOverflow.ellipsis);
    Widget trailingText =
        Text(trailing, maxLines: 1, overflow: TextOverflow.ellipsis);
    if (constrained) {
      nameText = Flexible(child: nameText);
      trailingText = Flexible(child: trailingText);
    }
    return Row(
      textDirection: TextDirection.rtl,
      mainAxisSize: MainAxisSize.min,
      children: [nameText, const Text(' - '), trailingText],
    );
  }

  Widget _bookChip(int rowIndex, Topic t, int j, bool selected, ColorScheme cs) {
    final hit = t.byBook[j];
    return GestureDetector(
      onSecondaryTapUp: (details) => _showBookmarkMenu(
        details.globalPosition,
        onRename: () => _renameTopicChip(t, hit),
        onDelete: () => _deleteTopicChip(t, hit),
      ),
      child: ActionChip(
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        avatar: (selected && j < 9)
            ? CircleAvatar(
                backgroundColor: cs.primary,
                child: Text('${j + 1}',
                    style: TextStyle(fontSize: 11, color: cs.onPrimary)),
              )
            : null,
        label: _chipLabel(hit),
        onPressed: () {
          setState(() => _selected = rowIndex);
          _openHit(hit);
        },
      ),
    );
  }

  /// Fixed, always-visible button shown when a topic has more books than fit
  /// in the chip strip ([_maxChipsPerRow]). Opens a dialog listing all of them.
  /// Placed outside the horizontally-scrolling chip strip so it never needs
  /// scrolling to reach, unlike a "+N" chip appended at the strip's end.
  Widget _allBooksButton(int rowIndex, Topic t, int total, ColorScheme cs) {
    return Tooltip(
      message: 'عرض كل الكتب ($total)',
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => _showAllBooks(rowIndex, t),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: cs.secondaryContainer,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.list, size: 16, color: cs.onSecondaryContainer),
              const SizedBox(width: 4),
              Text(
                '$total',
                style: TextStyle(
                    color: cs.onSecondaryContainer, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Full list of the topic's books; tapping one opens it. Used when a row has
  /// more chips than fit inline (see [_maxChipsPerRow]).
  Future<void> _showAllBooks(int rowIndex, Topic t) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        final cs = Theme.of(ctx).colorScheme;
        return AlertDialog(
          title: Text(t.display, maxLines: 2, overflow: TextOverflow.ellipsis),
          content: SizedBox(
            width: 460,
            height: 480,
            child: Scrollbar(
              child: ListView.builder(
                itemCount: t.byBook.length,
                itemBuilder: (c, j) {
                  final hit = t.byBook[j];
                  return GestureDetector(
                    onSecondaryTapUp: (details) => _showBookmarkMenu(
                      details.globalPosition,
                      onRename: () => _renameTopicChip(t, hit),
                      onDelete: () => _deleteTopicChip(t, hit),
                    ),
                    child: ListTile(
                      dense: true,
                      leading: j < 9
                          ? CircleAvatar(
                              radius: 12,
                              backgroundColor: cs.primary,
                              child: Text('${j + 1}',
                                  style: TextStyle(
                                      fontSize: 11, color: cs.onPrimary)),
                            )
                          : null,
                      title: _chipLabel(hit, constrained: true),
                      onTap: () {
                        Navigator.pop(ctx);
                        setState(() => _selected = rowIndex);
                        _openHit(hit);
                      },
                    ),
                  );
                },
              ),
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('إغلاق')),
          ],
        );
      },
    );
  }

  /// Opens the PDF viewer settings dialog, then refreshes the status bar so
  /// the "displayed via" text reflects any change.
  Future<void> _showViewerSettings() async {
    await showViewerSettingsDialog(context);
    if (!mounted) return;
    setState(() {});
  }

  /// Shows every keyboard shortcut/gesture and a short explanation of how the
  /// program works. Opened from the AppBar help button and F1.
  Future<void> _showHelpDialog() async {
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        final cs = Theme.of(ctx).colorScheme;
        final textTheme = Theme.of(ctx).textTheme;
        return AlertDialog(
          title: const Text('مساعدة واختصارات لوحة المفاتيح'),
          content: SizedBox(
            width: 520,
            height: 560,
            child: Scrollbar(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _helpSectionTitle('كيف يعمل البرنامج', textTheme),
                    Text(
                      'يفحص المجلد الذي تختاره (ويشمل مجلداته الفرعية) بحثًا عن ملفات '
                      'PDF تحتوي على فهارس (Bookmarks)، ويجمع العناوين المتشابهة عبر '
                      'كتب مختلفة في صف واحد يعرض رقم الصفحة في كل كتاب. عند فتح '
                      'موضوع، يُفتح الكتاب عند تلك الصفحة عبر SumatraPDF إن كان '
                      'متوفرًا، وإلا في المتصفح الافتراضي. يُحفظ فهرس كل مجلد مؤقتًا '
                      'لتسريع فتحه لاحقًا — استخدم زر "إعادة الفحص" بعد إضافة كتب '
                      'جديدة إلى المجلد.',
                      style: TextStyle(color: cs.onSurfaceVariant, height: 1.5),
                    ),
                    const SizedBox(height: 18),
                    _helpSectionTitle('اختصارات عامة (تعمل من أي مكان)', textTheme),
                    _shortcutRow('Ctrl + F', 'تركيز مربع البحث (يحدد النص الحالي)', cs),
                    _shortcutRow('Ctrl + 1 … 9', 'فتح الموضوع المحدد في الكتاب رقم N', cs),
                    _shortcutRow('Alt + E', 'عرض كل كتب الموضوع المحدد', cs),
                    _shortcutRow('F1', 'فتح نافذة المساعدة هذه', cs),
                    const SizedBox(height: 14),
                    _helpSectionTitle('أثناء الكتابة في مربع البحث', textTheme),
                    _shortcutRow('↑ / ↓', 'تحريك التحديد بين النتائج', cs),
                    _shortcutRow('Esc', 'نقل التركيز إلى القائمة (لا يمسح نص البحث)', cs),
                    const SizedBox(height: 14),
                    _helpSectionTitle('عند تركيز القائمة (خارج مربع البحث)', textTheme),
                    _shortcutRow('↑ / ↓', 'تحريك التحديد', cs),
                    _shortcutRow('/', 'تركيز مربع البحث', cs),
                    _shortcutRow('Esc', 'يبقي التركيز على القائمة', cs),
                    const SizedBox(height: 18),
                    _helpSectionTitle('الفأرة', textTheme),
                    _shortcutRow('نقر', 'تحديد الصف، أو فتح الكتاب مباشرة عند النقر عليه', cs),
                    _shortcutRow('نقر يمين', 'قائمة إعادة تسمية / حذف لصف أو كتاب (عند تفعيل التعديل)', cs),
                    _shortcutRow('عرض الكل', 'يعرض كل كتب الموضوع عندما تكون أكثر مما يظهر في الصف', cs),
                    const SizedBox(height: 18),
                    _helpSectionTitle('أزرار الشريط العلوي', textTheme),
                    _shortcutRow('اختيار مجلد', 'فتح مجلد كتب جديد وبدء فحصه', cs),
                    _shortcutRow('إعادة الفحص', 'إعادة فحص المجلد الحالي (بعد إضافة كتب جديدة مثلًا)', cs),
                    _shortcutRow('ترتيب المجلدات', 'فتح نافذة لتخصيص ترتيب ظهور المجلدات', cs),
                    _shortcutRow('التحديث التلقائي', 'تبديل تحديث القائمة تلقائيًا بعد إعادة التسمية أو الحذف', cs),
                    _shortcutRow('التعديل', 'تبديل السماح بإعادة التسمية والحذف عبر النقر اليمين', cs),
                    _shortcutRow('عارض PDF', 'اختيار البرنامج المستخدم لفتح ملفات PDF', cs),
                    _shortcutRow('مساعدة', 'فتح نافذة المساعدة هذه', cs),
                  ],
                ),
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إغلاق')),
          ],
        );
      },
    );
  }

  Widget _helpSectionTitle(String text, TextTheme textTheme) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, top: 2),
      child: Text(text, style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
    );
  }

  /// One row in the help dialog: a bordered key/label chip plus its
  /// description. Shared by all sections so the list stays easy to scan.
  Widget _shortcutRow(String keys, String description, ColorScheme cs) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            constraints: const BoxConstraints(minWidth: 110),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest,
              border: Border.all(color: cs.outlineVariant),
              borderRadius: BorderRadius.circular(6),
            ),
            alignment: Alignment.center,
            child: Text(
              keys,
              textAlign: TextAlign.center,
              textDirection: TextDirection.ltr,
              style: const TextStyle(fontSize: 12.5),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(description)),
        ],
      ),
    );
  }

  /// Compact page label: "ص 12" / "ص 12، 45، 88 +2" / "—" if unknown.
  String _pagesLabel(List<int> pages) {
    if (pages.isEmpty) return '—';
    const maxShown = 3;
    final shown = pages.take(maxShown).join('، ');
    final extra = pages.length - maxShown;
    return extra > 0 ? 'ص $shown +$extra' : 'ص $shown';
  }
}
