# MangaViewer development

Read `docs/MangaViewer_DESIGN.md` and `docs/DEV_STATE.md` before changing behavior.
Implement milestones sequentially, with a clean-session review subagent after each milestone. Resolve material findings before committing. Keep DEV_STATE and README accurate in each milestone commit.

- Swift 6, iOS/macOS/visionOS 26 minimum. One native SwiftUI application and one UI-independent MangaCore package.
- Prefer native APIs and small cohesive files. No scraper logic in views, arbitrary imported scripts, custom navigation framework, or speculative services.
- My Library is the landing section. Use native `TabView`/`Tab` with `.tabBarOnly` on iOS/iPadOS/visionOS so the system owns floating glass placement and accessibility; macOS keeps its sidebar. Keep separate navigation paths for top-level browsing, but **exactly one app-owned reader session above all sections**. Chapters never belong to tab navigation stacks. Collapse retains source/fraction and cancels offscreen work; resume reuses the same reader. Use native tab bottom accessories on iOS/iPadOS and a bottom ornament on visionOS. Do not build a custom glass tab overlay.
- HTML rules use XPath through system libxml2 (the design's expressed XPath preference supersedes its illustrative CSS/SwiftSoup choice). JSON uses dotted paths. GRDB owns SQLite persistence.
- Object identity is rule-scoped; preserve identifying query parameters. Synthetic page keys must be recoverable through the owner. Reading state survives cache eviction.
- External requests, redirects, and extracted URLs must respect exact allowed hosts. Never export credentials. Do not implement access-control workarounds.
- Verify risky seams with fixture tests, run actual platform builds, and record unavailable simulator/device checks honestly.
- User requested https://www.manhuagui.com/ for live testing; deterministic bundled fixtures remain the offline baseline.
- **Hard rule: ALL site-specific parsing must live in the object-parsing JSON under `Packages/MangaCore/Sources/MangaCore/Resources/Rules` (or an imported rule).** This includes URL recognition, XPath/selectors, regex captures, named variables, chapter titles, filename extensions, CDN/path/query construction, rendering mode, and captured function paths. Never encode a website exception or fallback in Swift, views, transport, or injected bridge code. Add only generic capabilities to the engine; express the website recipe in JSON. Keep the language minimal and data-only, with no imported executable scripts or general expression evaluator.
- Rendered JSON observes normal site behavior and requires a site-created image selected by the rule's readiness XPath. Never manipulate access gates or cookies. Manhuagui's JSON requests desktop content because iPhone requests redirect to a different mobile host/DOM. Preserve exact host restrictions and primary policy errors.
- SwiftUI image task identity must include resource URL, not just object key; clear stale image state before loading. Refresh must invalidate view data even when the chapter key is unchanged.
- Lazy reader rows must release offscreen bitmap state; an NSCache limit alone does not bound retained SwiftUI state. Keep prefetch to a small cancelable neighbor window. Never restore scroll position during an active gesture.
- Keep one primary app window (native `Window` on macOS/visionOS; multiple scenes disabled on iOS). The app-owned reader must never be driven by competing window lifecycles. Deduplicated repository requests track consumers; cancel transport when the last consumer leaves, preserving requests still used elsewhere.
- Rule changes must reload open content and cancel old image/prefetch work. Removing a rule purges its cached snapshots transactionally while preserving saved titles and reading state.
- Keep the macOS sandbox's user-selected file read/write entitlement for native import/export. Settings has its own error presentation because it can run in a separate window.

## Required milestone checklist

- [ ] Audit production Swift and injected JavaScript for site names/hosts, DOM IDs, function names, image suffixes, URL patterns, and site-dependent branches. All website parsing recipes must be in JSON; no exceptions. Generic page labels and offline fixture transport are not website parsing rules.
- [ ] Exercise parsing with JSON-driven fixtures, and the requested live source when changing its recipe. Preserve final URL/redirect host checks.
- [ ] Run core tests, affected platform builds, and relevant reader interaction checks. Have a clean-session reviewer check the JSON-only boundary and resolve material findings.
- [ ] Update README and DEV_STATE with changes, verification, limitations, and next steps before committing.

