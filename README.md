# فهرس الفهارس — Bookmark Index

A fast Windows desktop app (Flutter) that scans a folder of PDF books, reads
each PDF's bookmarks (outline), and builds one unified topic list. Chapters with
the same name across different books are grouped into a single row, showing the
page in each book. Click a page → the book opens at that page in an external
viewer.

Built for Arabic grammar books (RTL, Arabic-aware matching), but works for any
bookmarked PDFs.

## Run

```powershell
flutter run -d windows          # dev
flutter build windows --release # -> build\windows\x64\runner\Release\bookmark_index.exe
```

1. Click the **folder** icon and choose the directory that contains your PDFs.
2. It scans (in a background isolate), groups the bookmarks, and caches the
   result. Use **refresh** to rescan after adding books.

## Keyboard shortcuts

In-app: click the **?** icon in the toolbar (or press `F1`) for the full list.

| Key | Action |
|-----|--------|
| type | live-filter the list |
| `↑` / `↓` | move selection |
| `Enter` | open selected topic in its first book |
| `Alt`+`1`–`9` | open selected topic in book N — works everywhere, even while typing in search |
| `Alt`+`E` | show all books for the selected topic — works everywhere |
| `Ctrl`+`F` or `/` | focus the search box (selects existing text) |
| `Esc` | focus the list (never clears the search text) |
| `F1` | open the in-app help/shortcuts dialog |

## How it works

- **Extraction** — `syncfusion_flutter_pdf` (pure Dart) reads each PDF outline
  into `(title, page, level)`. PDFs with no bookmarks are skipped. See
  `lib/scanner.dart`.
- **Matching** — titles are normalized (`lib/normalize.dart`): strip Arabic
  diacritics + tatweel, unify alef/ya/ta-marbuta variants, normalize digits and
  punctuation, collapse whitespace. Titles with the same normalized key are
  grouped into one `Topic`. Cross-book topics are listed first.
- **Viewer** — prefers **SumatraPDF** (`-reuse-instance -page N`, reuses one
  window). Falls back to the default browser via `file://…#page=N`. See
  `lib/viewer.dart`. Set a custom viewer path in the settings JSON if needed.
- **Storage** — settings and a per-folder index cache live under
  `%APPDATA%\bookmark_index\` as plain JSON (`lib/store.dart`). No platform
  plugins are used, so no "Developer Mode" is required to build.

## Notes / limits

- Page numbers are **physical** 1-based pages (what SumatraPDF/`#page=` expect),
  not printed page labels.
- Matching is normalized-exact by design. If some chapters are worded
  differently across books, they won't merge yet — a fuzzy "suggest merge" step
  and a persisted alias table are the natural next additions.
