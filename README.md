# MangaViewer

A native SwiftUI manga reader for iOS, macOS, and visionOS 26+, with a standalone URL-to-object engine.

Implementation follows [the design](docs/MangaViewer_DESIGN.md). Progress and verification are in [DEV_STATE](docs/DEV_STATE.md); development conventions are in [AGENTS.md](AGENTS.md).

The core uses Foundation networking, native XPath (libxml2), and [GRDB](https://github.com/groue/GRDB.swift) for SQLite. Rules are versioned data, never executable scripts.

Build and test the core with Xcode 26 or later:

```sh
swift test --package-path Packages/MangaCore
```

Open `MangaViewer.xcodeproj`, select the MangaViewer scheme and a Mac, iOS, or visionOS destination. For device builds, choose your development team in Signing & Capabilities. No code generator is required.

```sh
xcodebuild -project MangaViewer.xcodeproj -scheme MangaViewer \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
open build/Build/Products/Debug/MangaViewer.app
```

Choose **Open the reading room** for a complete offline fixture. Open `https://www.manhuagui.com/` to browse the bundled live rule. Chapter availability depends on the source website. The app does not bypass site access restrictions.

The command-line engine probe also supports a live rendered chapter:

```sh
swift run --package-path Packages/MangaCore manga-probe
swift run --package-path Packages/MangaCore manga-probe --rendered https://www.manhuagui.com/comic/32602/441493.html
```

See [the rule format](docs/RULES.md) for XPath/JSON recipes. Original fixture artwork can be regenerated with `swift scripts/generate-fixtures.swift`.

Reader options include paged/vertical modes, reading direction, conservative margin trimming, spread detection, and facing pages in wide windows. You can keep, split, or pair the current original page manually. Arrow keys and edge taps turn pages; pinch or double-click/tap zooms in paged mode. Position is saved against original pages, including fractional scroll progress.

Decoded images are limited to 96 MiB in memory and image bytes to 256 MiB on disk. Only visible pages and a small neighbor window are decoded. Source objects and reading state use separate SQLite tables.

In **Settings**, import/export JSON rules, share small rules as QR images, manage reader defaults, and clear caches. QR payloads over 1200 UTF-8 bytes use JSON export instead. Rules are installed only after their allowed hosts are shown. Rule removal and cache clearing preserve saved titles and reading progress.

Run all automated checks with `bash scripts/verify.sh`. Generic simulator builds do not require installed simulator runtimes. Actual device signing requires your own Apple development team. The current verification record and remaining manual checks are in [DEV_STATE](docs/DEV_STATE.md).

Manhuagui's live directory, manga, and rendered chapter extraction have been exercised. Both tested chapters' CDN URLs returned HTTP 404 for their first images; the bundled reading room is the deterministic end-to-end baseline. Refresh can renew image URLs when the source supplies new ones.
