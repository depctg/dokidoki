# Development state

## Plan

- M1 complete: models, validated XPath/JSON rules, bounded HTTP fetcher, SQLite snapshots/reading state, repository and fixture tests.
- M2: native app and basic reader, Manhuagui adapter if normal rendered DOM is needed.
- M3: composable display plans, image analysis, memory/disk cache, prefetch.
- M4: library/settings, rule exchange/QR, portability and final walkthrough.

## Environment and decisions

- Initial workspace contained only the design. Git initialized on `main`.
- Xcode 27.0 / Swift 6.4, macOS/iOS/visionOS 27 SDKs available. No available simulator runtimes at initial inspection.
- Deployment baselines remain 26. Use native libxml2 for XPath, GRDB for SQLite.
- Manhuagui homepage and manga HTML were reachable with ordinary HTTPS. Site uses `/comic/` paths, not only `/book/`; chapter extraction needs investigation. No third-party content fixtures are committed.

## Resume

Read AGENTS.md and design. Package tests will run with `swift test --package-path Packages/MangaCore`; application build instructions will be added with M2.

## M1 verification and review

- Core builds with Swift 6.4. All 5 focused Swift Testing tests pass, including the orphan-child regression added during clean-session review.
- `swift run --package-path Packages/MangaCore manga-probe` resolves fixture directory -> manga -> chapter -> page, with four ordered pages.
- Live probes on 2026-10-12: Manhuagui homepage produced 328 manga references; `/comic/32602/` produced title, cover, and 108 chapters. Counts are observations, not assertions.
- Manhuagui `/comic/32602/441493.html` contains a JavaScript-driven reader, so chapter HTTP-only probing reports the rendered-adapter requirement. No decoded scripts, site images, or downloaded third-party HTML are committed.
- Review correction: parent refresh now replaces its owned page snapshots transactionally, pruning removed pages/covers.
- Clean-session M1 review: stale-child finding reproduced and fixed; no remaining material blockers. Redirect/body-size limits and cancellation on rule/cache mutation are code-reviewed but not transport-fixture-tested yet.
- Core public seams: `RuleRegistry.match`, `SourceFetcher.fetch`, `RuleExtractor.extract`, `ObjectRepository.resolve`, `ObjectStore`; see `docs/RULES.md` for the schema.

