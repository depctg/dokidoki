# MangaViewer development

Read `docs/MangaViewer_DESIGN.md` and `docs/DEV_STATE.md` before changing behavior.
Implement milestones sequentially, with a clean-session review subagent after each milestone. Resolve material findings before committing. Keep DEV_STATE and README accurate in each milestone commit.

- Swift 6, iOS/macOS/visionOS 26 minimum. One native SwiftUI application and one UI-independent MangaCore package.
- Prefer native APIs and small cohesive files. No scraper logic in views, arbitrary imported scripts, custom navigation framework, or speculative services.
- HTML rules use XPath through system libxml2 (the design's expressed XPath preference supersedes its illustrative CSS/SwiftSoup choice). JSON uses dotted paths. GRDB owns SQLite persistence.
- Object identity is rule-scoped; preserve identifying query parameters. Synthetic page keys must be recoverable through the owner. Reading state survives cache eviction.
- External requests, redirects, and extracted URLs must respect exact allowed hosts. Never export credentials. Do not implement access-control workarounds.
- Verify risky seams with fixture tests, run actual platform builds, and record unavailable simulator/device checks honestly.
- User requested https://www.manhuagui.com/ for live testing; deterministic bundled fixtures remain the offline baseline.
- The Manhuagui WebKit adapter must observe normal site behavior. Require a site-created reader image before extracting page references; never manipulate access gates or cookies. Keep imported rules data-only.
- SwiftUI image task identity must include resource URL, not just object key; clear stale image state before loading. Refresh must invalidate view data even when the chapter key is unchanged.
- Lazy reader rows must release offscreen bitmap state; an NSCache limit alone does not bound retained SwiftUI state. Keep prefetch to a small cancelable neighbor window. Never restore scroll position during an active gesture.
- Rule changes must reload open content and cancel old image/prefetch work. Removing a rule purges its cached snapshots transactionally while preserving saved titles and reading state.
- Keep the macOS sandbox's user-selected file read/write entitlement for native import/export. Settings has its own error presentation because it can run in a separate window.

