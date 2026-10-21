# dokidoki" — Design Specification (V1)

**Status:** maintained implementation design

**Branding:** the display name includes a trailing quotation mark. Native Icon Composer source and the derived visionOS stack are documented in [ICON.md](ICON.md); bundle/storage identity stays stable.
**Platforms:** iOS, macOS, visionOS; adaptive layout for iPhone Duo (closed and unfolded)  
**UI:** native SwiftUI  
**Primary goal:** a small, extensible URL-to-object engine with an excellent manga-reading view.

## 1. Product goal

Build a native manga viewer that fetches supported website content, converts it into typed internal objects (with site/manga independent fields), and presents it in a clean reading interface. Its inspiration is Yealico's rule-driven approach, not its full feature set.

The **content engine is the product's foundation**. Views consume objects; they never contain website-specific scraping code. A website rule determines how source URLs are recognized and interpreted. Content objects may be cached and persisted independently of the UI.

V1 is a functional vertical slice, not a general-purpose browser or universal scraper.

## 2. Design principles

1. **URL-first, object-centric.** A supported external URL is mapped deterministically to a typed object. (through url matching and parsing rules). Objects link to other objects through stable references.
2. **Site with a cached object graph.** `Site -> Directory -> Manga -> Chapter -> Page`. A Site derives browse sources/search from installed rule data. Each fetched SitePage can create multiple Directory previews; each Directory represents a single list. `Chapter` is first-class so it can be refreshed, cached, and navigated independently. each type could be created from a url.
3. **Identity is separate from transport.** A stable object key is not necessarily the URL used to download its bytes. This matters for CDN URLs, signed image links, and pages without individual HTML URLs.
4. **Core before UI.** Models, rule matching, extraction, persistence, and reader image planning live in a standalone Swift package with no SwiftUI dependency.
5. **Declarative site rules; compiled processors.** Shareable JSON configures known capabilities. It must not contain arbitrary executable Swift/JavaScript.
6. **Minimal implementation.** Prefer standard Apple frameworks, a few focused protocols, and only dependencies that save meaningful code. Avoid premature abstractions and extensive test infrastructure.

## 3. V1 scope

**Include:**
- Add a supported URL or import a site rule; browse a directory, open a manga, select a chapter, and read its pages.
- Directory: manga list, local filter, optional source-defined sorting by/order, and appending rule-provided next pages. Remote search uses a native results list only when a rule explicitly defines a search endpoint.
- Manga: cover/title-page object, metadata, ordered chapters, and resume reading.
- Chapter reader: paged and continuous-scroll modes, left-to-right/right-to-left order, memory/disk image cache, prefetch, and configurable page processing.
- My/Settings: saved manga, recent reading, reader preferences, site-rule management, JSON file export/import, and QR export for suitably small rules.
- Functional iOS, macOS, and visionOS shells using standard platform navigation and interaction patterns.

**Defer:** cloud sync, accounts, DRM/paywall/CAPTCHA workarounds, automatic rules for every website, a visual rule editor, script execution from imported rules, full offline library downloads, translation/OCR, advanced spread stitching, and immersive visionOS features.

## 4. Core object model

Core models are small `Sendable` value types; fetched snapshots are `Codable`. SiteObject is a declarative rule-backed entry point. SitePageObject caches each fetched home/source page with its directory references; the shared repository assembles their lists. No homepage URL is invented. Prefer a typed enum to a complex base-class hierarchy.

```swift
struct ObjectKey: Hashable, Codable, Sendable {
    let ruleID: String
    let identityURL: URL
}

enum ContentObject: Codable, Sendable {
    case site(SitePageObject)
    case directory(DirectoryObject)
    case manga(MangaObject)
    case chapter(ChapterObject)
    case page(PageObject)
}
```

Note that the fields here are not final; please continue working on and add more fields/types as it evolves (future we may also add new fields, eg, a manga could be a abstract manga linked to multiple url manga from multiple websites).

Each object contains `key`, `sourceURL` if applicable, basic metadata, and typed references to other objects:

| Object | Required role | Main fields |
| --- | --- | --- |
| `SiteObject` | Browse root for one installed rule | `id`, `name`, `version`, normalized `browseRefs`, `load(using:)` returning directories, `supportsSearch`, `search(query)` returning a directory reference |
| `SitePageObject` | One fetched site page | `key`, `sourceURL`, `title`, ordered `directoryRefs` |
| `DirectoryObject` | A single listing of manga | `title`, optional known `items` (`mangaRefs` compatibility view), optional `isPreview`, `hasMore`, optional total/end/`nextURL`, sort-by/order references and selected keys |
| `MangaObject` | A series and its chapters | `title`, optional author/summary/rating/status/tags, `coverPageRef`, optional known `chapters` (`chapterRefs` compatibility view) |
| `ChapterObject` | A navigable chapter | `title`, parent `mangaRef`, ordered `pageRefs`, optional chapter number |
| `PageObject` | One original image (cover or chapter page) | `ownerRef` (manga/chapter), `role` (cover/content), optional `sourceIndex`, optional resolved `imageURL`, optional `refererURL` and logical `sessionURL` provenance, dimensions/analysis |

Use `ObjectKey` references, not embedded recursive object graphs. One site source can create many directory/manga snapshots through bounded relative relationship fields. SiteObject.load delegates ordered, deduplicated source assembly to the repository; views own only presentation state. Homepage directory excerpts have unknown sorting/continuation until normal list loading; preview loads accept known items. Partial directory/manga updates cannot downgrade complete snapshots. Lists retain the extracted order; selecting a source-provided sort link loads a distinct directory object. DirectoryObject.load(_:using:) asks the shared core context for a zero-based range. Core loads enough source pages, deduplicates keys and keeps the first page identity/sorting; objects remain immutable snapshots with optional known items. JSON APIs may declare offset/limit/total paths plus a query parameter instead of a next-link selector. Matchers can select named extractors so one site can use HTML catalogs and JSON search without transport exceptions. Native List directory rows request the next object range near the end, with a plain loading/end/retry section footer. Successful content retains its view identity and loaded items on navigation return; explicit refresh, key changes and loading-policy revisions invalidate it. No custom scrolling handler or offset restoration is needed.

Manga rating and publication status are optional source text, and tags are an optional ordered string list. Rules capture their values using existing selectors/regex; the engine trims blanks and removes duplicate tags. Browse/list/Library/Recent rows and manga details display available values. Preserve the source's score scale and finished/ongoing wording without site-specific Swift mappings or guessed defaults. Linked manga creation accepts known title, cover URL and other metadata through `mangaLinks.fields`, using the same mapping as a full manga document. Core caches these partial snapshots with unknown chapters; preview requests with known covers skip detail loads. Normal manga loading resolves the chapter list. Missing fields remain compatible with older snapshots; same-version list refreshes never downgrade full manga snapshots or their cover/original fetch date. Cover resource provenance points to the discovering directory session separately from manga ownership, allowing passive resource reuse with unchanged host/referer policy.

### Identity and URL semantics

- External HTTP(S) URLs are normalized **conservatively** and matched to an installed site rule. Do not drop query parameters blindly; some identify chapters or pages. Strip fragments only for ordinary external HTTP requests when safe.
- A persistent key is `(ruleID, identityURL)`. This scopes matching and cache data to the rule responsible for the content.
- If a page lacks its own stable public URL, assign a deterministic internal `reader://...` identity from `(chapterKey, sourceIndex)`; retain the actual remote `imageURL` as a resource URL. Resolving an internal reference loads its owning chapter if necessary; it does not attempt an HTTP request to `reader://`.
- Redirected/final resource URLs and expiring signed image URLs are **not** object identity by default.
- Rule changes must not silently reinterpret persisted objects: record the parsing rule version and refresh objects parsed by an outdated version.

## 5. Resolution, extraction, and persistence

```text
External URL / ObjectKey
  -> RuleRegistry.match(URL)
  -> object/reference.load(using: repository, hint: cacheHint)
  -> ObjectRepository (shared resolution through the core cache)
      -> ObjectStore (cached snapshot, if valid)
      -> RequestSender (shared admission and completion)
          -> SourceFetcher (URLSession or rendered WebKit session)
      -> RuleExtractor (HTML or JSON)
      -> typed ContentObject + child references
      -> ObjectStore.upsert(...)
  -> SwiftUI view
```

**Responsibilities:**

- `RuleRegistry`: installed rules; match by host, URL pattern, object type, and explicit priority. Return an `unsupportedURL` result if no rule matches. Ambiguous matches are errors, not arbitrary choices.
- SiteObject creates normalized directory/search references and validates the actual encoded query against its own rule. Core objects/references expose loading methods; callers supply a shared repository without persisting service references inside Codable values. Chapters load their pages/parent manga, manga load their covers, and pages determine their image requests. `MangaObject` decides adjacent chapters within a selected named list using its rule-supplied order. ReadingPosition retains optional chapterListID; legacy callers use the first matching list. Flat chapterRefs remains a deduplicated compatibility view.
- `RequestSender` (`actor`): one admission queue for documents, images and rendered sessions, with native async result/error delivery. Share identical requests by URL, purpose, complete rule policy and image referer; each caller can cancel independently. Last-consumer cancellation removes queued work or cancels active transport, retaining capacity until that transport exits. FIFO among eligible requests allows four active total, two per initial host, and one rendered operation. A rolling one-second start budget allows eight total and four per initial host, regardless of how quickly requests finish. Rate-delayed work occupies no active slot and uses one cancellable native [ContinuousClock deadline](https://developer.apple.com/documentation/swift/task/sleep(until:tolerance:clock:)); other eligible hosts proceed. Deduplicated waiters and canceled queued requests spend no extra budget. Admitted attempts count even if they fail or are canceled. Browser-internal subresources remain WebKit-managed.
- `SourceFetcher`: HTTP(S) transport, redirects, timeouts and limited request headers; rendered sources use the generic WebKit adapter. Admission belongs to the shared sender. No UI dependency.
- Rendered sessions persist in a core manager indexed by logical URL (query included), full rule/extractor policy and background preference. At most four browser contexts are retained, with a 60-second idle expiry; refresh, cancellation and invalidation close affected contexts. One rendered operation is admitted at a time; retained browser timers/subresources remain WebKit-managed. Sessions are hidden, use ephemeral browser storage and never become object state or an iOS background service. Minimal JSON load/page/scroll strategies translate range intents into ordinary DOM actions, preserving existing resolved siblings. Directory requests supply known item identities so a recreated session can replay to unseen items without treating cached batches as stalled progress. Normal declared-host resource loading, including ads, defaults on; a persisted global Settings toggle or per-kind JSON `rendering.loadAds: false` blocks hidden images/media/fonts. Native reader images remain available. Policy changes cancel old object requests and participate in sender identity. No ad UI/interactions, autoplay, persistent background task or relaxed host checks. `readyXPath` waits for asynchronous DOM completion; rendered JSON observes a normal function argument or return value (`captureResult`) and a site-created readiness image. Full syntax lives in RULES.md; AI authoring guidance stays outside the app/package in rule-authoring/.
- `RuleExtractor`: XPath-select HTML or traverse JSON; resolve relative links against the response URL; preserve item order; create known child `PageObject`s plus all chapter page identities from a declared total. Unresolved descriptors retain identity/index with no guessed image URL; page image loads request only missing ranges.
- `ObjectRepository` (`actor`): shared context for object loading, cache decisions, deduplicated complete object resolutions, atomic storage of parent/child snapshots, and ownership of the shared sender/image cache.
- `ObjectStore`: local SQLite store of keyed, versioned `Codable` snapshots. Use GRDB as a small SQLite wrapper. Keep a storage protocol only where it supports a real fixture/in-memory implementation.
- Durable personal state: MangaObject.personalState carries library membership, stars, hidden Recent entries, source/fractional position, chapter unread/reading/read/ignored state and whole-manga progress. The v6 mangaLibrary table stores complete personal manga snapshots, independent of evictable content. It migrates the old three state tables, retaining uncached titles and structured object identities. Core hydrates cached/fresh objects and GRDB observation publishes changes. Read/ignored marks survive ordinary reading; explicit individual/group actions can reset them. Source upsert refreshes catalogs; older view/reader snapshots may only seed missing metadata at personal edits. Full manga extraction can use chapterLists with relative id/title/chapterLinks fields; no local status is scraped.

**Suggested minimal persisted schema:** `objects(key, kind, payloadJSON, ruleVersion, fetchedAt, accessedAt, priority)`, `rules(id, version, json)`, `mangaLibrary(mangaKey, payload)`, and `preferences(key, payload)`. Add indices only when a real query requires them.

### Cache policy

The **core cache layer owns all retention decisions**. Objects have no expiry or priority properties, and supplying known metadata from a list does not assign a lifetime. ObjectStore retains at most 64 MiB of serialized content payloads (SQLite file overhead and durable reading state are separate), preferring manga/cover metadata over chapter/page metadata over site/directory metadata. Eviction within priority is least-recently-used; chapter descriptor reads/touches are batched. A v5 migration replaces expiry with access time and priority without clearing user data. Cache eligibility includes rule version and completeness/preview needs. A fetched object is returned even when the cache declines retention; missing children resolve through the owning object's extractor and rule. Reading state, library membership and preferences are outside this eviction budget.

Normal object loads use `preferCache`; explicit `forceRefresh` fetches current content and `offlineOnly` forbids a miss from loading. There is no automatic age expiry. A source refresh updates that source and its known relationships without downgrading complete child snapshots; refreshing an opened list/manga requests that object's current data. Image byte identity is rule ID + canonical allowed hosts + URL + referer, independent of parsing revision. Every read still checks the current allowed-host policy. The current recipe’s legacy disk entries migrate lazily without downloading. Disk image caches survive process restarts but remain OS-purgeable; explicit image refresh/clear invalidates bytes. Metadata Refresh renews parsed source data. Cover and chapter images share core image policy/storage: 112 MiB decoded memory (32 MiB reserved for 768px covers), 512 MiB disk, with covers retained ahead of content. Passive session buffers retain already-acquired responses (four logical contexts, 24 MiB each), isolated by full rule, owner URL and referer. They may reuse accessible pixels from images already loaded by WebKit; no extra browser fetch fills a miss. Public WebKit APIs cannot expose every cross-origin resource, so unavailable bytes fall back to central HTTP. Cache/rule/policy invalidation discards old generations. `PageObject.image(using:)` determines its resource identity/request; the repository-owned image loader checks caches, asks the same sender for missing bytes, and decodes images. Never persist credentials or cookies in exported rules. Decode/display only visible images and a small neighbor window; cancel irrelevant prefetches when the user jumps chapters.

## 6. Site rules (JSON)

A rule is a portable, **data-only** recipe. Keep it compact enough for file/QR sharing. The supported schema includes:

- `schemaVersion`, stable rule `id`, display name, version, and allowed hosts.
- URL matchers for `directory`, `manga`, and `chapter` (page objects may be synthesized from chapter extraction).
- Fetch format defaults to `renderedHTML`; explicit `html`/`json` and legacy `renderedJSON` remain supported. Prefer DOM extraction and normal session actions for chapters.
- Extraction fields: XPath + text/attribute for HTML; a minimal dotted key path for JSON. Relative URL resolution is automatic.
- Optional search URL template, listing pagination, image source attribute fallback, and reader defaults.

The canonical schema, examples, action semantics and bounds are in [RULES.md](RULES.md). Session `load` reads a document, `page` activates a next/load control or chapter page option, and `scroll` reveals a rule-selected target. Chapter `totalCount` and optional one-based `pageNumber` preserve complete identities across partial DOM snapshots. Directories accumulate known items and compare declared totals against that aggregate. These capabilities remain data-only; no general expression language, imported scripts, credentials or arbitrary host access.

Use original offline HTML/JSON/browser fixtures for deterministic regressions, plus bounded live probes of the requested sources. A source connection failure is not evidence for changing selectors. Full-rendered chapter loading is the default; older explicit capture recipes can remain until a verified DOM migration is possible.

## 7. Chapter reader and image pipeline

The reader is the primary product feature. Separate **source pages**, **display planning**, and **image rendering**:

```text
ChapterObject -> [PageObject] -> image analysis
              -> PagePipeline (ordered processors)
              -> [DisplayPage] -> lazy SwiftUI renderer
```

A `DisplayPage` is a lightweight rendering plan, not necessarily one bitmap. It may reference an entire source image, a crop of one image, or regions from two adjacent source images. Keep the original source pages immutable. the pipeline should be able to compose multiple processors and support extending more processors in future version.

```swift
struct PageRegion: Sendable {
    let sourcePage: ObjectKey
    let normalizedCrop: CGRect  // 0...1 in image coordinates
}

struct DisplayPage: Sendable {
    let regions: [PageRegion]    // one or more source regions
    let sourcePageKeys: [ObjectKey]
}

protocol PageProcessor: Sendable {
    var id: String { get }
    func plan(
        _ pages: [DisplayPage],
        context: ReaderContext
    ) async throws -> [DisplayPage]
}
```

`ReaderContext` supplies display size, reading direction, reading mode, relevant image metadata/analysis, and validated processor settings. The registered Swift implementations are **compiled into the app**; JSON selects and configures them. A processor can perform `1 -> 1`, `1 -> many`, or `many -> 1` changes. The renderer fetches and decodes only the images referenced by nearby display plans.

Reader layout uses one stable image/loading/error container per lazy row and full-viewport scroll targets, with artwork insets inside each row. Their width is independent of image size or page count. Native lazy-stack anchoring handles ordinary image arrivals. Explicit navigation, viewport/preferences changes and replacement of the current region can restore source/fraction; unchanged plans never trigger timed repositioning. Initial restoration prepares the target region’s source dimensions before layout, including manual pairs. Image analysis is staged while scrolling and published with its plan after interaction. This follows Apple's [lazy-stack layout guidance](https://developer.apple.com/videos/play/wwdc2026/321/).

The presentation model chooses a small keyed preparation window (current, next two, previous; maximum six source images). It retains overlapping jobs and cancels only obsolete work or a collapsed reader. `PageObject.prepare(using:)` warms the shared core image cache and analyzes off the main executor. Normal display requests independently consume that cache or the same admitted in-flight request; no view-owned network path or second request budget exists.

**Built-in V1 pipeline:**

1. `identity`: no changes; always available as a fallback.
2. `marginAlign`: estimate visible content bounds from downsampled edge pixels, trim only conservative blank borders, and align pages consistently without cutting artwork. Provide an off switch.
3. `spreadDetect`: detect (a) a wide source image that may contain a double-page spread, using aspect ratio and center-gutter evidence, and (b) a possible **cross-page spread across two adjacent source images**, using conservative RGB continuity checks at the artwork edges after measuring small white margins. Confident left/right cuts lose only their touching white padding and render as one image in either reading mode. Preserve uncertain cases and provide manual split/keep/pair overrides. Respect right-to-left or left-to-right order when splitting. See [image processing](IMAGE_PROCESSING.md) for the external algorithm reference and limits.
4. `layout`: for wide windows, optionally pair consecutive single pages into a two-page display unit. Keep a detected intentional cross-page spread together; do not mistakenly rearrange its halves.

Sophisticated image stitching, seam reconstruction, and content-aware art repair are follow-up processors, not V1 requirements. Use Image I/O for efficient decode/downsampling, Core Graphics for cropping/composition, and Core Image where filters actually help. No third-party computer-vision dependency is needed initially.

**Reading modes:**
- **Paged:** use native view-aligned scrolling with an always-by-one limit for each swipe, plus keyboard navigation; zoom to fit, retain an optional two-page presentation on wide screens.
- **Continuous scroll:** lazily render display units vertically, with stable spacing and alignment. Avoid preloading the full chapter.
- **Position:** store progress by `(chapterKey, original sourcePageKey, fractionalOffset)` rather than a mutable display index. Switching modes, processors, or window widths must not lose the user's place.

Handle loading, failed images (retry), empty chapters, and end-of-chapter navigation. Reader modes share one native ScrollOverpull geometry/phase handler, reporting signed distance and viewport fraction; inertia may only shrink an existing preview. Both reading modes attach it directly to their scroll views: every user-driven pull beyond either boundary reveals feedback, including when the drag starts inside the content or interrupts a rubber-band return. Adjacent chapter navigation requires 25% viewport overscroll at release; simply reaching an edge or subsequent deceleration never triggers it. Keep both boundary surfaces mounted outside scrollable content with placeholder artwork, updating content as metadata arrives. Native geometry/phases own the clipped reveal and release, without an exact idle-position arming gate. A boundary image grows in the overscroll gap above plain, readable title/threshold feedback with fixed typography and position; clip the initial reveal instead of reflowing text, with no progress bar. Finish native enlargement quickly after release before switching; invalidate delayed navigation if the interaction is canceled or superseded. Show next-chapter loading/unavailable status in the small badge on the final two display pages; hide it when ready. Reduce Motion skips enlargement. Backward pulls enter the previous chapter at its last page; forward pulls enter the next chapter at its first. Missing neighbors show a boundary message. Processing failures degrade to the original page instead of blocking reading.

## 8. Views and adaptive platforms

Use one SwiftUI multi-platform application target over the shared core package. Prefer `NavigationStack` for compact layouts, `NavigationSplitView` where appropriate, system search/toolbar/settings/file sharing, and standard controls. Avoid device-name branches.

Use native Apple localization and system/per-app language selection. App text lives in String Catalogs, including accessibility and plural variants; core error resources use localized SwiftPM bundles. Separate localized display labels from persisted enum raw values and object identities. Website/rule content retains its source text. English and Simplified Chinese are the initial interface languages; see `docs/LOCALIZATION.md` for maintenance.

| View | Minimum experience |
| --- | --- |
| Browse | First site in persisted rule order; JSON-defined horizontal cover shelves with full-list links, selected-site search and site switcher |
| Directory | Cover/title list of manga, local filter, optional rule-extracted sort-by/order links, open manga; optional pagination |
| Manga | Adaptive cover/metadata, full-width description, Star, named chapter groups with per-group display sorting and read checks, resume |
| Chapter | Distraction-free reader, mode switch, reading direction, processing toggles, progress |
| My / Settings | Saved titles, recent reads, reader defaults, installed rules, JSON import/export, QR share, cache clear |

Root screens use native inlineLarge toolbar titles; details stay inline. Library/Recent row taps open details and a separate play button resumes the global reader. Library swipe only removes; Recent also offers stars. All cover surfaces preserve original image aspect ratios without gray framing or a forced portrait shape. A shared CoverImageView resolves the supplied page key and asks PageObject for its decoded image, without per-surface descriptor tasks or the chapter processing pipeline; shelves can reserve transparent stage space to align text. Manga details use the shared Star action; unstar retains the saved title and Remove unsaves it. Local per-group reversal affects display only. Reader navigation carries selected chapterListID and always asks MangaObject for neighbors. Completion means reaching the final loaded display page, or the bottom of continuous content; source/fraction alone cannot imply completion of a split image. Opening manga details scrolls to its latest chapter by default, controlled by the persisted jumpToLastChapter preference. An explicit reader-to-manga action always reveals that chapter. The iOS/iPadOS/visionOS manga list uses a native UICollectionView list with UIHostingConfiguration for the shared SwiftUI row/header content. Native indexTitles and indexPathForIndexTitle map a top arrow, short rule-derived indexTitle labels (two characters at most, ordinal fallback) and dots directly to any row. Each chapter group remains one section, even with hundreds of items. Dots target every max(25, ceil(count/9)) rows, bounding interior stops at eight per group while following display order. Stable composite list/chapter IDs preserve overlapping groups, sorting and current-chapter reveal. UIKit owns index tracking/compression/automatic visibility and self-sizing; no custom gestures or overlay. macOS retains SwiftUI List and its scrollbar.

Apple references: [Lists and tables HIG](https://developer.apple.com/design/human-interface-guidelines/lists-and-tables), [native row-index mapping](https://developer.apple.com/documentation/uikit/uicollectionviewdatasource/collectionview(_:indexpathforindextitle:at:)), and [Lists in UICollectionView, WWDC20](https://developer.apple.com/videos/play/wwdc2020/10026/). Apple's [Music library guide](https://support.apple.com/guide/iphone/play-music-iph0138fb328/ios) is the product design reference; it does not specify Music's internal index implementation. SwiftUI sectionIndexLabel targets section starts, so it cannot provide interior chapter stops without artificial section splits.

Search uses a native editable results list. Search and object destinations share a typed native navigation path, so opening a result and returning retains the search. Directory objects optionally expose rule-extracted sort-by/order references and active keys; source links define the available choices and URLs. Selecting a sort loads that directory through the shared core pipeline. Omitted axes have no controls; do not impose a local sort or derive source URL parameters. Older snapshots remain decodable.

Site rules may provide a minimal `browse` array of named site-page or directory source URLs and a `searchURLTemplate` containing `{query}`. Core builds SiteObject from this declaration and assembles ordered DirectoryObjects across those sources. A fetched SitePageObject caches directory references; nested known metadata creates list and manga previews without separate detail requests. Directory extraction supplies the full list title, sorting and pagination when opened. Source refresh preserves complete child snapshots and their original fetch date; missing or rule-invalid linked lists load through their own object rules. Browse previews at most eight items per shelf and lazily asks core objects for metadata/covers through the shared sender. Native Settings list reordering persists locally and defines the default site; it does not alter matcher priority, cache validity or the global reader. Hide allowed hosts in normal rule rows while retaining transport policy and the import preview.

**iPhone Duo:** closed display behaves like compact iPhone; unfolded display reflows into a wider layout with optional facing pages. Detect usable geometry, not a hard-coded device model or fold-state API. Preserve reading position through size changes.

**macOS:** native window resizing, keyboard shortcuts and navigation, pointer/trackpad interactions, file import/export. **visionOS:** a standard comfortable SwiftUI window with large accessible controls and gaze/gesture interaction; no immersive scene in V1. A single app-owned reader occupies a unique `Window` pushed in place of the main window. Native `pushWindow`/`dismissWindow` restore the main window on system close or collapse, retaining the same reader for its resume ornament. The reader scene's native disconnect notification calls the shared collapse action; backgrounding alone must not collapse it. Suppress reader scene restoration/default launch, and allow independent width/height resizing with minimum content dimensions only. Start wide with the existing paged/facing-page defaults; preserve saved preferences. Once the first visible source has complete image analysis, use PagePipeline to fit the image/spread's crop-aware combined aspect inside the initial bounds, growing only to satisfy scene minima. Replan for the proposed size until its wide/narrow layout agrees before making one geometry request to the reader's own UIWindowScene. Apply this initial fit once per reader window, never on later page turns or manual resize. iOS/iPadOS full-screen covers and the macOS sheet retain their existing behavior.

QR codes: use Core Image's QR generator for small rule payloads. If the JSON exceeds a reliable single-code size, show a clear message and use JSON file/share export instead. Do not build multi-QR transport in V1.

## 9. Technology choices and repository structure

- **Language/concurrency:** Swift, async/await, actors for repositories and shared loaders. Prefer modern OS baselines (proposed: iOS 26+, macOS 26+, visionOS 26+) to avoid compatibility scaffolding; validate against the available Xcode SDK.
- **UI:** SwiftUI only, with small platform-specific code where required.
- **Networking:** Foundation `URLSession`.
- **HTML extraction:** system libxml2 (XPath). **JSON:** Foundation `Codable` / `JSONSerialization`.
- **Persistence:** SQLite through GRDB, storing typed-object JSON snapshots behind a small repository interface.
- **Images:** Image I/O, Core Graphics, Core Image; `NSCache` and an app-managed disk LRU.
- **Sharing:** `fileImporter`, `fileExporter`/`ShareLink`, Core Image QR generation.

```text
MangaViewer/
  App/                 # SwiftUI app entry, navigation, platform settings
  Features/
    Directory/
    Manga/
    Reader/
    My/
  Packages/MangaCore/
    Models/
    Rules/
    Resolution/
    Networking/
    Persistence/
    Imaging/
  Resources/
    SampleRules/
    Fixtures/
  Tests/MangaCoreTests/
  DESIGN.md
```

Directory names are organizational, not an instruction to create one file/protocol per concept. Keep modules few and cohesive. The SwiftUI views depend on the core, never the reverse.

## 10. Minimal safety and operational constraints

Use HTTP(S) only for external network requests; respect allowed hosts and deliberate cross-host image-CDN declarations. Avoid unlimited downloads, aggressive concurrency, or logging sensitive URLs/headers. Support authorized sources and obey applicable site terms and content rights; do not include bypass mechanisms for access controls. Rules must not export cookies, credentials, or tokens.

No cloud backend, telemetry platform, dependency injection framework, elaborate event bus, or custom navigation framework in V1. Report unsupported URLs and extraction failures clearly rather than silently guessing their object type.

Use Apple's unified logging for error-only diagnostics. Core object loading records failed content/image loads; local action boundaries record startup, storage and rule failures. Native Settings reporting reads only the app's error category for the current process (at most 200 entries within 24 hours) and offers explicit share/text export. Exclude cancellation, normal activity and sensitive source/error payloads; see [diagnostics](DIAGNOSTICS.md).

## 11. Implementation milestones for Codex

**M1 — Core engine first**
- Create the shared Swift package and typed object graph.
- Implement conservative URL matching, sample rule decoding, HTML/JSON fixture extraction, `ObjectRepository`, and persistence.
- Demonstrate `Directory -> Manga -> Chapter -> Page` resolution from a sample rule without SwiftUI.

**M2 — End-to-end basic reader**
- Build directory, manga, and chapter SwiftUI screens against the repository.
- Implement original-image display, lazy loading, paged/scroll modes, progress, and basic error states.
- Prove one supported website or controlled fixture works end-to-end.

**M3 — Configurable processing and caching**
- Add processor registry and the `DisplayPage` plan model.
- Implement conservative margin alignment, wide-image and adjacent-page spread detection, and manual overrides.
- Implement memory/disk image caching and limited prefetch.

**M4 — Polish and portability**
- Add My/Settings, JSON import/export, QR share, and basic cache controls.
- Verify native navigation and resize behavior on iPhone, unfolded iPhone Duo layout, macOS, and visionOS simulator/device where available.
- Keep platform-specific exceptions localized.

## 12. Acceptance criteria and testing discipline

V1 is done when:

1. A supported directory URL resolves into manga refs, a manga opens its chapters, and a chapter renders its ordered original pages.
2. Objects persist across app restart, resolve from cache when fresh, refresh on demand, and do not lose reading progress when cached content is evicted.
3. Paged/scroll modes and RTL/LTR order work; switching modes or resizing retains the original source-page position.
4. Margin alignment and double-spread detection can be turned on/off; questionable detections leave artwork intact or allow manual override.
5. A rule exports as valid versioned JSON and can be imported; small rules can be shared as QR; oversized rules fall back to file export.
6. The codebase builds for each platform target, with a shared UI-independent core. Unsupported URLs and network failures produce understandable states rather than crashes.

**Test only the risky seams:** URL matching and canonicalization; relative-link extraction; object persistence/versioning; ordered page planning (including wide-image and adjacent-image spreads); source-page-based progress; and rule JSON round trips. Use small bundled fixtures and a few focused unit tests, plus one manual end-to-end reading walkthrough per platform. Do not create large UI snapshot suites, exhaustive mocks, or speculative robustness layers. Keep two UI journeys: Library/Browse/action wiring, and reader gestures/chrome/source-position restoration. The reader runs the same chapter-boundary contract over paged RTL, paged LTR and vertical scrolling; shell diagnostics only verifies report/export wiring, with formatting/redaction owned by core tests. Reuse a per-test transport spy for ordinary fixture responses and parameterize shared cache promotion/adjacency contracts; native transport and rendered-session tests retain their real framework adapters.

## 13. Instructions to Codex

- Treat this document as the source of truth for V1 scope and boundaries.
- Implement milestones sequentially. **Start with M1 only**, present the file tree and key interfaces, then write compiling code and small fixture tests.
- Do not build a large generic plugin framework, browser, rule editor, or service architecture beyond the specified extension points.
- Prefer simple, idiomatic Swift and Apple APIs. Make reasonable local decisions without adding abstractions for hypothetical future needs.
- At each milestone, report what builds, which targeted checks ran, limitations, and the next smallest task. Do not claim an Apple-platform build succeeded unless it was actually run in Xcode or `xcodebuild`.

### Native UI / personal state refinement (2026-10-13)

Directory continuation uses native List row appearance near the end to request a range through its object, with a plain loading/end/retry section footer. Keep loaded content and the native list identity on navigation return; explicit refresh or rule/policy changes invalidate them. No scroll-offset compensation or custom pagination gesture. The reader surface and chrome retain their native identity across chapter replacement. Prepare incoming chapter content through core while outgoing artwork stays visible, then replace pages/text without a whole-reader fade or loading modal. Chapter-scoped tasks restore the new source/fraction; native scroll geometry/phases remain system-owned. Reader chrome is owned by its stable presentation across chapter replacement; continuation artwork has no backing rectangle. Chapter indices target native list headers and interior item stops; native cell backgrounds highlight the current chapter. Library cards keep their native navigation disclosure after a separate bordered resume button, with the star away from the title.

Durable local manga state includes read/unread/ignored chapter actions, group actions and whole-manga progress. Percentages average chapter progress over unique nonignored chapters. Completing a manga records its known chapter catalog; a later source refresh adds unread chapters as New, changing to Reading when one is opened. Library/Recent put chapter and progress on separate lines, with book/checkmark/sparkles icons for Reading/Finished/New. Unknown catalogs show Reading without a percentage. **iCloud is deferred for this patch at the user's request**, including configuration preparation; local storage and Personal Team builds remain the scope.

Native references: [UIHostingConfiguration](https://developer.apple.com/documentation/swiftui/uihostingconfiguration) bridges SwiftUI actions into list cells; [firstItemInSection](https://developer.apple.com/documentation/uikit/uicollectionlayoutlistconfiguration-swift.struct/headermode-swift.enum/firstiteminsection) makes the group title an indexable native header.
