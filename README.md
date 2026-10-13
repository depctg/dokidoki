# MangaViewer

A native SwiftUI manga reader for iOS, macOS, and visionOS 26+, with a standalone URL-to-object engine.

Implementation follows [the design](docs/MangaViewer_DESIGN.md). Progress and verification are in [DEV_STATE](docs/DEV_STATE.md); development conventions are in [AGENTS.md](AGENTS.md).

The core uses Foundation networking, native XPath (libxml2), and [GRDB](https://github.com/groue/GRDB.swift) for SQLite. Rules are versioned data, never executable scripts.

The interface supports English and Simplified Chinese through Apple's native localization. It follows your system/per-app language and includes localized controls, accessibility labels, errors, progress and plural forms. Website content keeps its source language. See [localization](docs/LOCALIZATION.md) to add languages or update translations.

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

In **Browse**, use **Switch site** to choose the bundled reading room for an offline fixture or MangaCopy for live shelves. Chapter availability depends on the source website. The app does not bypass site access restrictions.

The command-line engine probe also supports a live rendered chapter:

```sh
swift run --package-path Packages/MangaCore manga-probe
swift run --package-path Packages/MangaCore manga-probe --rendered https://www.manhuagui.com/comic/32602/441493.html
swift run --package-path Packages/MangaCore manga-probe --rendered https://www.mangacopy.com/comic/yiquanchaoren/chapter/2c814b6a-4f03-11e9-8b1c-024352452ce0
```

Browse opens the first site in Settings order, initially MangaCopy. Core models it as a `SiteObject` containing rule-defined browse sources and search. MangaCopy now loads its homepage once to create the recommendation, popular-update and new-arrival lists, with known manga metadata. A site may use multiple source pages; core preserves their order and deduplicates lists. Each directory is one manga list, previewed as a horizontal cover row; tap a heading for the full list or a cover for manga details. Search opens a native results list with an editable search field and asks that Site object for a rule-defined search directory. MangaCopy and the reading room pass known titles, covers and available metadata from each list into cached manga objects. Cards with known covers skip manga-detail requests; opening a full list resolves its sorting/pagination, and manga details resolve chapters when still unknown. The globe menu switches sites. Open URL remains available from the link button (or Command-O on Mac). Rules without shelves show an empty state and retain URL/search access.

Directory and search lists show a native Sort menu only when their JSON extraction defines sort-by or order links. Selecting an option loads the website's sorted list; there is no hardcoded local title sort. Either axis may be absent. Manhuagui exposes its existing catalog/search choices, while its update list retains source order.

Drag Site rules in Settings to change the default site; iPhone/iPad also provide Edit handles. Order survives relaunch and recipe updates without restarting the reader. Rule rows show names and versions; network host permissions remain in JSON and in the import preview.

Manga cards, lists, Library/Recent, and manga details show optional **rating**, **publication status**, and **tags** captured by the site rule. Ratings retain the source's scale and statuses retain its wording; absent values are omitted. Full tags are available in manga details. Manhuagui's HTML provides status and genre tags; its JavaScript-loaded score is absent from ordinary HTML and its placeholder is excluded by the JSON rule. The offline reading room demonstrates all three fields.

See [the rule format](docs/RULES.md) for XPath/JSON selectors, regex captures, named variables, and simple URL templates. All site-specific parsing, including rendered chapter metadata and image URL construction, belongs in JSON. Original fixture artwork can be regenerated with `swift scripts/generate-fixtures.swift`.

MangaCopy is the bundled default for catalog shelves, source sorting/pagination, manga metadata and complete chapter images. The upgrade installs and selects it once; later user ordering/removal is preserved. Its JSON rule requests desktop content on iPhone to avoid the different mobile layout. Chapter v4 extracts the declared page count and lazy image URLs from the rendered DOM, scrolling only as requested; it no longer observes JavaScript data for chapters. Search uses the website’s public JSON endpoint and rule-declared counters for 12-item pages. Lists have a **Load more** action that appends through core. Pull-to-load support is in progress: its native gesture check failed and further testing/fixes are deferred to the next version at the user’s request. A standalone [AI authoring prompt](rule-authoring/PROMPT.md) and [guide](rule-authoring/GUIDE.md) explain how to create/test recipes; these files are outside the Swift application/package. The probe accepts `--rule /path/site.json` for an unbundled recipe and `--range 4:2` to resolve chapter pages 5–6 (zero-based start and count).

Each horizontal swipe moves at most one page forward or back, including fast flicks; the next and previous pages share the image prefetch cache. The reader fixes page width to its viewport and lets native scrolling retain position when neighboring images arrive. A bounded prefetch window keeps overlapping work running; later display requests reuse core image caches. Tap/click the manga to hide or restore the toolbar without moving or resizing the artwork. A small floating chapter/page badge stays visible in immersive mode. The compact title shows the chapter name. The top-right controls return to the manga's current chapter row, open the previous/next chapter, and show reader settings. Pinch zooms in paged mode. With keyboard focus, arrow keys turn pages, Space toggles controls and Escape collapses the reader. On Mac, drag with the mouse or scroll with a trackpad to change pages.

Manga sources can provide separate chapter, volume and extra lists. Core preserves their names and reading order, keeps navigation within the selected list, and stores chapter read status independently of the source cache.

Reader settings use icon choices for paged/scroll mode and right-to-left/left-to-right direction. Image adjustments contain margin trimming, spread detection, facing pages in wide windows and per-page overrides. Refresh and Source website are also in this menu. Opening it does not request text input. Position is saved against original pages, including fractional scroll progress, and restored when switching modes.

With **Detect spreads** enabled, core compares adjacent left/right page cuts, removes matching white binding margins and displays confident pairs as one seamless image in either reading mode. Uncertain pairs stay separate; **Keep original** prevents a join. Try **Aster House → Across the valley** in the bundled reading room. See [image processing](docs/IMAGE_PROCESSING.md) for the algorithm, external reference and limitations.

`MangaObject` decides previous/next chapters using its ordered chapter references. Near either end, the reader preloads adjacent metadata and one boundary image. On the last two display pages, the small page badge shows next-chapter loading or unavailable status before any boundary pull; the hint disappears when ready. In paged and scroll modes, drag beyond either chapter boundary to reveal its preview or a missing-chapter message, even when the same drag starts inside the content. Reaching the edge or bouncing from momentum alone never changes chapters. Each boundary is prepared with placeholder artwork, which updates when the preview loads, and grows in the exposed overscroll gap with a plain chapter title and pull/release hint behind it. Text keeps its size, wrapping and position as the gap reveals it; there is no progress bar. Pull beyond 25% of the viewport and release to finish enlarging the preview quickly and continue; shorter pulls return to the current chapter. Backward pulls open the previous chapter's last page; forward pulls open the next chapter's first page. Missing chapters show “No previous chapter” or “No next chapter.” The floating page badge remains visible. Chapter changes retain immersive mode and use native animation; Reduce Motion skips enlargement. Toolbar chapter buttons remain available.

Decoded images are limited to 96 MiB in memory (16 MiB reserved for covers) and image bytes to 256 MiB on disk. Only visible pages and a small neighbor window are decoded. Source objects and reading state use separate SQLite tables.

Loading belongs to core objects and references: chapters load their pages, manga load their covers, and pages load their images. They share one repository and request sender. The sender queues document/image requests and rendered sessions, allowing four active requests total, two per initial host, and one rendered operation. A rolling one-second budget also limits starts to eight total and four per initial host, including fast completions and retries. Queued work waits without occupying an active slot. Identical requests share a result; canceling one caller preserves work needed by others. Results and errors return through native Swift async calls. WebKit manages subresources within its retained browser contexts.

**Settings → Website loading → Background resource loading** defaults to on. Hidden WebKit metadata sessions can load normal website images/media/fonts, including ads, from the rule's declared hosts; ads are never presented. Turn it off to block those resources globally, or set `rendering.loadAds: false` for a particular object-kind extractor. The setting persists, cancels old object requests when changed and leaves native manga image downloads available. The core session manager retains up to four hidden browser contexts by logical URL and rule/extractor policy, expiring each after 60 seconds idle. Refresh, cancellation and policy/cache invalidation close affected sessions. These are in-process browsers, not an iOS background service.

In **Settings**, import/export JSON rules, share small rules as QR images, manage reader defaults, and clear caches. QR payloads over 1200 UTF-8 bytes use JSON export instead. Rules are installed only after their allowed hosts are shown. Rule removal and cache clearing preserve saved titles and reading progress.

**Settings → Error report** collects errors through Apple's native logging and lets you review, share, or export a text report. It includes up to 200 errors from the current app session, excluding normal activity and cancellation; see [diagnostics](docs/DIAGNOSTICS.md) for coverage and privacy limits.

Run core tests and all platform builds with `bash scripts/verify.sh`. Generic simulator builds do not require installed simulator runtimes. The native UI suite has two distinct journeys: Library/Browse/navigation/actions (including site order), and reader gestures/chrome/position restoration. Database migration and retention details stay in core tests. Use a dedicated iPhone or iPad simulator for UI checks, because they change saved titles, site order, reader preferences, and reading history. Run Product → Test, or:

```sh
xcodebuild -project MangaViewer.xcodeproj -scheme MangaViewer \
  -destination 'platform=iOS Simulator,id=<SIMULATOR-UDID>' \
  -derivedDataPath build -parallel-testing-enabled NO \
  -collect-test-diagnostics never CODE_SIGNING_ALLOWED=NO test
```

Actual device signing requires your own Apple development team. The current verification record and remaining manual checks are in [DEV_STATE](docs/DEV_STATE.md).

Manhuagui's live browsing and chapter images passed earlier iPhone and iPad checks. The latest local check (2026-10-13) cannot connect to the source: Browse and the core probe time out, and an independent HTTPS request fails before TLS. Live browsing remains unverified until connectivity recovers; see [DEV_STATE](docs/DEV_STATE.md). Its JSON rule requests desktop content for chapters, configures the generic WebKit observer and puts chapters in reading order; Swift contains no site-specific parser. The bundled reading room remains the deterministic end-to-end baseline. Refresh can renew image URLs when the source supplies new ones.

Core objects are Codable content snapshots with declarative range loads and optional known items; they own no browser, task or cursor state. Chapters default to rendered DOM extraction. Rules can declare a total count before all image URLs are visible; pages resolve their missing URL when requested, using rule-defined load, page or scroll actions in a retained browser. The shared core context owns pagination and caches; views never follow source next links. Passive per-session resource buffers reuse acquired bytes before new image requests, with URL/rule/referer isolation. The browser lookup reads only already-decoded, accessible images; it never issues a fetch to fill a miss. Cross-origin pixels blocked by WebKit fall back to the normal central HTTP request. Complete manga/chapter metadata is retained for seven days; list-discovered metadata uses the list lifetime and never downgrades a complete cached manga. Cover thumbnails have a protected memory allocation and higher disk retention priority. Refresh and cache clearing remain explicit.
