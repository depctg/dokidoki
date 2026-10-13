# MangaViewer

A native SwiftUI manga reader for iOS, macOS, and visionOS 26+, with a standalone URL-to-object engine.

Implementation follows [the design](docs/MangaViewer_DESIGN.md). Progress and verification are in [DEV_STATE](docs/DEV_STATE.md); development conventions are in [AGENTS.md](AGENTS.md).

The core uses Foundation networking, native XPath (libxml2), and [GRDB](https://github.com/groue/GRDB.swift) for SQLite. Rules are versioned data, never executable scripts.

Build and test the core with Xcode 26 or later:

```sh
swift test --package-path Packages/MangaCore
```

Open `MangaViewer.xcodeproj`, select the MangaViewer scheme and a Mac, iOS, or visionOS destination. For device builds, choose your development team in Signing & Capabilities. No code generator is required.

For an iOS preview, select an iPhone or iPad simulator and Run. Xcode 27 opens simulators in Device Hub. The local `MangaViewer Compact` and `MangaViewer Expanded` devices have iOS 27 installed. The actual iPhone Duo simulator requires [Xcode 27.1](https://developer.apple.com/iphone-duo/prepare/); an iPhone/iPad comparison checks adaptive layout but does not simulate folding.

```sh
xcodebuild -project MangaViewer.xcodeproj -scheme MangaViewer \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
open build/Build/Products/Debug/MangaViewer.app
```

The app opens in **My Library**, with your saved manga. On iPhone, iPad, and visionOS, native floating tabs switch between **My Library**, **Browse**, **Recent**, and **Settings**, using the system's glass appearance and platform placement. Each tab keeps its own browsing history. macOS uses a sidebar.

Library and Recent rows show the cover, manga title, chapter, original page/total pages, and last-read age in hours or days. Tap a row to resume; an unread saved title starts at its first chapter. Swipe left on iPhone/iPad for **Star/Unstar**, **Remove**, and **Manga details**; the same actions are available in the context menu and accessibility actions. Stars put favorites first in Library; starring a Recent item also saves it. Removing from Library unsaves the title. Removing from Recent hides the history entry until you read it again. Both preserve the reading position. Older entries show cached page counts when available; missing covers use a placeholder.

One reader is shared by the whole app in a single main window. Opening another chapter replaces the active chapter. Collapse it to a small glass **Resume** bar with the manga cover, manga title, chapter and page progress; tapping it returns to the same page from any main view. In paged mode, pull down from the top; in scroll mode, swipe inward from the physical left edge. The collapse button and Escape also return to the main views. On iPhone the native accessory sits above the tabs and moves inline when they minimize; iPad keeps it at the bottom, visionOS uses a bottom window ornament, and macOS places it below the top toolbar. The iOS accessory follows Apple's [Music accessory pattern](https://developer.apple.com/videos/play/wwdc2025/323/); Mac uses an in-window adaptation.

In **Browse**, choose **Open the reading room** for a complete offline fixture, or open `https://www.manhuagui.com/` to browse the bundled live rule. Chapter availability depends on the source website. The app does not bypass site access restrictions.

The command-line engine probe also supports a live rendered chapter:

```sh
swift run --package-path Packages/MangaCore manga-probe
swift run --package-path Packages/MangaCore manga-probe --rendered https://www.manhuagui.com/comic/32602/441493.html
```

See [the rule format](docs/RULES.md) for XPath/JSON selectors, regex captures, named variables, and simple URL templates. All site-specific parsing, including rendered chapter metadata and image URL construction, belongs in JSON. Original fixture artwork can be regenerated with `swift scripts/generate-fixtures.swift`.

Swipe horizontally to turn pages; the next and previous pages share the image prefetch cache. Tap/click the manga to hide or restore the toolbar without moving or resizing the artwork. A small floating chapter/page badge stays visible in immersive mode. The compact title shows the chapter name. The top-right controls return to the manga's current chapter row, open the previous/next chapter, and show reader settings. Pinch zooms in paged mode. With keyboard focus, arrow keys turn pages, Space toggles controls and Escape collapses the reader. On Mac, drag with the mouse or scroll with a trackpad to change pages.

Reader settings use icon choices for paged/scroll mode and right-to-left/left-to-right direction. Image adjustments contain margin trimming, spread detection, facing pages in wide windows and per-page overrides. Refresh and Source website are also in this menu. Opening it does not request text input. Position is saved against original pages, including fractional scroll progress, and restored when switching modes.

`MangaObject` decides previous/next chapters using its ordered chapter references. Near the end, the reader preloads the next chapter's metadata and first image. Pull past the last page to reveal its title and image; continue when a forward pull reveals 25% of the viewport and is released or finishes decelerating. Short paged pulls return to the last page. The preview also has an explicit Open next chapter action. This uses native SwiftUI scroll geometry, phases and target behavior; 25% is the app's chosen threshold. Chapter changes retain immersive mode.

Decoded images are limited to 96 MiB in memory and image bytes to 256 MiB on disk. Only visible pages and a small neighbor window are decoded. Source objects and reading state use separate SQLite tables.

Loading belongs to core objects and references: chapters load their pages, manga load their covers, and pages load their images. They share one repository and request sender. The sender queues document/image requests and rendered sessions, allowing four active requests total, two per initial host, and one rendered session. Identical requests share a result; canceling one caller preserves work needed by others. Results and errors return through native Swift async calls. WebKit manages subresources within its active session.

In **Settings**, import/export JSON rules, share small rules as QR images, manage reader defaults, and clear caches. QR payloads over 1200 UTF-8 bytes use JSON export instead. Rules are installed only after their allowed hosts are shown. Rule removal and cache clearing preserve saved titles and reading progress.

Run core tests and all platform builds with `bash scripts/verify.sh`. Generic simulator builds do not require installed simulator runtimes. The native UI suite has two distinct journeys: Library/navigation/actions, and reader gestures/chrome/position restoration. Database migration and retention details stay in core tests. Use a dedicated iPhone or iPad simulator for UI checks, because they change saved titles, reader preferences, and reading history. Run Product → Test, or:

```sh
xcodebuild -project MangaViewer.xcodeproj -scheme MangaViewer \
  -destination 'platform=iOS Simulator,id=<SIMULATOR-UDID>' \
  -derivedDataPath build -parallel-testing-enabled NO \
  -collect-test-diagnostics never CODE_SIGNING_ALLOWED=NO test
```

Actual device signing requires your own Apple development team. The current verification record and remaining manual checks are in [DEV_STATE](docs/DEV_STATE.md).

Manhuagui's live browsing and chapter images have been verified on iPhone and iPad simulators. Its JSON rule requests desktop content, configures the generic WebKit observer and puts chapters in reading order; Swift contains no site-specific parser. Individual chapters/CDNs may still return source errors; the bundled reading room remains the deterministic end-to-end baseline. Refresh can renew image URLs when the source supplies new ones.
