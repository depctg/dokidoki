# Development state

Updated 2026-10-21. This is a current handoff, not a chronological changelog. Earlier investigations, superseded implementations and historical test logs remain in Git (`git log -- docs/DEV_STATE.md`). Read [AGENTS.md](../AGENTS.md) for conventions and [the design](MangaViewer_DESIGN.md) for architecture.

## Status and next work

The application milestones and the code/design cleanup are complete. The cleanup preserves the existing reader, library, browsing, rules and local persistence features. No deployment or new preview revision was requested for this patch.

- **Queued user request:** investigate the odd manga-list background on iPhone Duo. Check whether the native gray background should extend across the whole screen, including safe areas and both open/closed layouts. Inspect before changing layout; prefer native container behavior.
- **Deferred product scope:** iCloud synchronization remains explicitly skipped. No accounts, full-library offline downloads, access-control workarounds or new parsing language are planned in this patch.
- **Remaining manual coverage:** physical Duo/Vision Pro interaction, a current Mac keyboard/mouse/zoom/window-resize walkthrough, and end-to-end sandboxed Mac file panels. Current cleanup has platform builds and Duo automation, not new physical-device or visionOS interaction results.

## Latest cleanup and verification

Two sequential milestones received clean-session reviews:

1. **Core ownership and validation** (`c7f516e`). Immutable `SiteRule` validates at native decoding; sender/resource/session keys use its complete Hashable value instead of repeatedly validating and encoding recipes. Startup/migration, settings persistence and library observation enter through ObjectRepository. RuleExchange owns async security-scoped reads and off-main QR rendering. Rule/order writes commit together, preserving import order and older partial preferences. Reviewer `review_cleanup_boundaries` identified the ordering issue and approved its correction.
2. **Native view lifetime and updates.** ObjectScreen and images use native task identity/cancellation. Successful content retains its identity on navigation return. Core DisplayPage owns image composition off the main executor; lazy rows release offscreen bitmaps. Library timers update only the age label. UIKit chapter cells observe personal state through configurationUpdateHandler; snapshots change only for structural edits. Hosted SwiftUI details own Dynamic Type. Reader fractions no longer invalidate the surface every pixel; native target geometry replaces the preference dictionary, separate offset observer and timed restoration delay. Reviewer `review_cleanup_ui` identified refresh-identity, interrupted-restoration and Dynamic Type dependencies; all findings are resolved and the production diff is approved.

Verification on the final implementation:

- **84 core tests in 21 suites pass**, including request concurrency/burst limits, independent cancellation, host policy, persistence/migration, cache retention, JSON extraction and real WebKit session contracts. `bash scripts/verify.sh` also passes **macOS arm64, iOS Simulator and visionOS Simulator builds**: `/tmp/dokidoki-cleanup-final-verify.log`.
- **Both permanent UI journeys pass on iPhone Duo / iOS 27.1**, with no test failures or runtime warnings: `/tmp/dokidoki-cleanup-ui-final.xcresult`. Library covers native action/status wiring, sorting, autoload/retained directory ranges, first-tap reading and rule reordering. Reader covers actual images, one-page flicks, fractional resume/relaunch, immersive layout, chapter boundaries in paged RTL/LTR and scroll mode, and joined-page rendering. An earlier full reader run also passed: `/tmp/dokidoki-cleanup-reader.xcresult`.
- Tests remain concentrated: the existing page-preparation contract now covers composition, bounded decode and portrait orientation, replacing an overlapping decode test. The two UI journeys remain; native Edit/reorder-handle automation replaces the fragile long-press rule drag, resolving the previously recorded Duo Library failure. Redundant custom failure screenshots were removed; XCTest captures failures.
- Production Swift/injected-JavaScript site-recipe audit, UI request/storage ownership audit and `git diff --check` pass. Website parsing stays in JSON. No rule syntax, cache budgets or request limits changed. The Settings cache description now matches the existing 512 MiB budget in English and Chinese.

## Current behavior and important discoveries

These notes explain decisions that are easy to regress; the full contracts live in AGENTS/design.

- **Objects and sessions:** Codable objects are declarative snapshots. Core owns range assembly, continuation, persistent browsers, shared request admission and cache decisions. Known metadata creates directory/manga/cover snapshots without fetching each manga catalog. Session resource buffers only reuse already-obtained bytes; a miss uses normal core transport. Resource policy/referer isolation and independent consumer cancellation remain necessary boundaries, not redundant validation.
- **Browsing:** native List rows request another range near the end; a plain footer shows loading/end/retry. Local filtering covers loaded items and pauses autoload. Navigation return retains loaded ranges and native position. Explicit refresh, a changed object key or loading policy invalidates them. Earlier pull-to-load and Tap to load more implementations are superseded.
- **Reader:** one app-owned reader presentation persists across chapter changes. Incoming pages, native ScrollPosition, title and one composed landing image publish together; ordinary chapter switching has no loading modal or whole-view fade. Native scroll ownership stays with the chapter that began tracking, across a brief idle-before-deceleration sequence; outgoing callbacks cannot overwrite incoming progress. `isPositionedByUser` stayed false in real Duo swipes and is not a reliable replacement for this ownership. Fractional restores use measured target/content coordinates, and a new gesture supersedes them.
- **Chapter lists:** Smart order compares concatenated Unicode decimal digits, preserving source ties and putting unnumbered titles last. Website/reverse website orders remain available; MangaObject adjacency always uses the source group, never UI sorting. Native UIKit index entries target the group header and actual interior rows, without artificial sections. Personal read/ignored state is durable and independent of evictable source snapshots.
- **Platform presentation:** native floating tabs/accessories own placement. visionOS uses one pushed reader Window; its exact scene disconnect collapses the app reader. Window content can outlive scene closure, so onDisappear alone is insufficient. Fit the first analyzed spread once; later resizing/page turns do not refit. Prior visionOS open/collapse/resume/native-close checks passed on 2026-10-13, before runtime removal.
- **Duo automation:** anchor XCTest coordinates to the native window, not XCUIApplication (which can target zero-size display 0). Device Hub controls open/closed poses; simulator screenshot display 1 is outer and 3 inner. Device Hub rotation preserves reader position; XCTest orientation assignment did not resize the inner display. Do not add app/device workarounds for automation targeting.
- **Native resources:** SwiftPM copies Rules and Fixtures separately; a bundle-root folder named Resources breaks sibling localization discovery. Preserve the Bundle.module.localizations regression. URI extraction preserves existing percent escapes while encoding remaining Unicode/path characters; double encoding formerly turned valid image URLs into 404s.

## Source verification

Bundled rules currently ship as MangaCopy v9 (`00-mangacopy.json`), Manhuagui v10 and offline demo v10. MangaCopy is adopted as the initial Browse site once; later user ordering/removal persists. All selectors, URL templates, desktop-content preferences and rendered actions remain in JSON.

- **Manhuagui, last live checks 2026-10-21:** catalog 42, updates 727, nonempty search 3, empty search 0, second catalog page 42 and rating sort 42. Linked previews have known covers and unknown chapter catalogs; opening a list does not fetch every manga. A chapter probe resolved 24 pages and decoded the first image at 980 × 1506 (`/tmp/dokidoki-transition-live-image.log`). Older port-443 failures are historical, not a current outage diagnosis.
- **MangaCopy, last live checks 2026-10-13:** 490 unique chapters across four source groups (241/35/29/185); rendered lazy chapters declared 205 and 189 pages, including successful late-page/range image decoding. Public JSON search supplied offset-based pages of 12 and a genuinely empty result. iPhone/iPad live directory → manga → reader checks passed with JSON-declared desktop content. Source availability can change; this cleanup did not repeat live-site tests or modify recipes.
- Diagnose future source failures at the failing layer with a bounded independent request before changing selectors. A connection failure before HTML is not evidence of a parser defect. Downloaded pages/artwork and temporary probes stay out of Git and app resources.

## Toolchain, preview and commands

- Xcode **27.1 (27A9275)**, Swift 6 language mode, iOS 27.1 SDK; macOS/visionOS 27.0 SDKs. Deployment minima remain 26. Recheck with `xcodebuild -version` and `xcodebuild -showsdks` when resuming on another setup.
- Only the **iOS 27.1 runtime (24A94425)** remains installed. At the user's request, iOS/visionOS 27.0 runtimes were removed without deleting simulator device records/data. visionOS builds work; its simulator currently cannot run. No simulators are booted after verification.
- Dedicated available destination: **dokidoki Duo Checks**, `50E1BD95-1711-4616-8C75-A28A028B1130`. Xcode 27 uses `/Applications/Xcode.app/Contents/Applications/DeviceHub.app`. Native Xcode logs include `invalidDigitCount(94425/94232)` and nil debugger-version warnings despite successful runs.
- Current marketing version is **0.1.0**, latest distributed preview build **20261021192420**. That revision was installed on Zhiyuan iPhone without clearing data; automatic launch then found the device locked. Developer trust was already resolved by the user. This cleanup did not reinstall or modify the physical device. Use a fresh UTC timestamp only for the next distributed revision.
- Keep target `MangaViewer`, bundle `com.mangaviewer.reader`, storage and OSLog identity stable; display name is literal `dokidoki"`.

```sh
# Core tests and the three native platform builds
bash scripts/verify.sh

# Two permanent UI journeys; use a dedicated simulator because preferences/library change
xcodebuild -project MangaViewer.xcodeproj -scheme MangaViewer \
  -destination 'platform=iOS Simulator,id=50E1BD95-1711-4616-8C75-A28A028B1130' \
  -derivedDataPath build -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO test
```

For parsing changes, use the fixtures and the bounded `manga-probe` workflow in [RULES.md](RULES.md), [PROMPT.md](../rule-authoring/PROMPT.md) and [GUIDE.md](../rule-authoring/GUIDE.md). Authoring material stays outside Swift resources. Native branding/assets and the local high-resolution marketing composition are documented in [ICON.md](ICON.md), [MARKETING.md](MARKETING.md) and [screenshot provenance](images/README.md); third-party artwork remains ignored. Temporary `/tmp` evidence may be purged, so rerun relevant verification when needed.
