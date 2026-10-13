# Creating a site rule

This guide and [copyable prompt](PROMPT.md) are maintained developer material for a capable AI or human author. They stay outside `App/`, `Packages/`, Xcode resource membership and SwiftPM targets. [docs/RULES.md](../docs/RULES.md) is the schema reference; bundled JSON is executable evidence of that schema. Do not copy this guide into the application.

## Model and boundaries

`SiteObject` derives named directories and a search interface from a rule. Each `DirectoryObject` is one list. Manga own ordered chapter references, chapters own source-page references, and pages own image resources. Core object APIs request data through the repository and one shared sender, which handles concurrency, bursts, deduplication and cancellation. Objects are declarative Codable snapshots with optional known items and range APIs; shared managers own tasks, cursors and persistent URL-indexed sessions. A recipe describes data and ordinary DOM actions, not a scraping program.

Every source-dependent choice belongs in JSON, including hostnames, URL formats, DOM classes/IDs, observation paths, regexes, chapter ordering and image extensions. A site name appearing in production Swift or bridge JavaScript is a failed review. Synthetic test markup may model an actual rule, but production parsing cannot branch on that site. Adding a recipe normally requires no Swift changes.

## Collect evidence before writing

1. Fetch the public homepage and representative list/manga/chapter URLs. Compare a bounded direct request with a normal browser when necessary. Record HTTP/redirect failures separately; do not repair selectors when no HTML arrived.
2. Inspect source and rendered DOM. Compare desktop and iPhone user agents/redirects before assuming the same DOM; declare `rendering.contentMode: "desktop"` in JSON when that is the structure being parsed. Identify title, cover, metadata, ordered chapters, image URLs and a complete-result signal. Verify counts against the website. A few images in a lazy DOM do not establish a complete chapter.
3. Follow public list/search/sort links and inspect their actual destinations, including the public JSON requests made by their normal UI. Preserve identifying query parameters. Check a successful query and a deliberately empty query. A loading placeholder must not be mistaken for an empty response.
4. List the exact document, script and image hosts needed by those examples. A diagnostics host can be an ad click destination or analytics URL; do not add every discovered string automatically. Extra hosts need evidence. Never replace the host list with a wildcard or relax the policy in Swift.
5. Observe source order and alternative chapter groups. Exclude the latest-chapter shortcut before extracting the full list. `reverse` only reverses the selection; it is not a title-based sort. The resulting `MangaObject` decides previous/next.

Do not commit downloaded manga artwork, whole site pages, credentials, signed resource URLs or copied scripts. Keep local investigation snapshots under `/tmp`. Never change access gates/cookies, bypass login or port a site's decryption. Let the website perform its own normal work; if it does not expose usable content, report the limitation.

## Choose the smallest supported recipe

- Default to rendered DOM for chapters (`format` omitted means `renderedHTML`). Explicit `html` or `json` remains available for ordinary static/public API responses. Use `read`, `fallback`, `regex`/`group`, named scalar `variables`, `urlTemplate` and `queryPath` only where observed data requires them. HTML XPath fields select nodes; they are not arbitrary expressions returning strings/numbers. JSON templates substitute strings without evaluating code or inventing encodings.
- A matcher can select a named `extractor` for another representation of the same kind, such as JSON search alongside an HTML catalog. For JSON link objects, `read: "attr:property"` and a relative `titlePath` map identifiers and labels without a new object language.
- Use `renderedHTML` for asynchronous DOM content. `rendering.readyXPath` selects an existing site-created node that means extraction can finish. Include a genuine completed-empty marker if applicable; without one, a missing list times out instead of silently caching an empty snapshot.
- For partial DOM chapters, declare `totalCount`, optional one-based `pageNumber`, and `session` mode `scroll` or `page` with an XPath target. Core retains the URL-indexed browser and resolves requested ranges; `{index}` is a chapter-only one-based page target. Directory page controls use ordinary next/load actions and an end marker or total. Verify replay after session disposal and end detection on the merged list. See RULES.md for limits.
- Keep explicit `renderedJSON` for compatibility only when normal DOM actions cannot expose the content. Declare a dotted `captureFunction`, optionally `captureResult: true`, and a mandatory `readyImageXPath` for a site-created image with `src`. The observer preserves the normal call and emits `data`, `imageURL`, document `title` and `url`. It never invokes a function on behalf of the rule. Broad functions can receive unrelated calls: verify the captured value at readiness on more than one chapter.
- Hidden WebKit images/media/fonts load by default, including ads on declared hosts. A rendered extractor may set `loadAds: false`; the global Background resource loading setting overrides any opt-in. This affects only temporary metadata sessions, not native reader image downloads. Scripts/documents still run with resources off. The renderer disables automatic media playback/popups, displays no ads, and retains at most four contexts for 60 seconds idle. Cancellation/refresh/invalidation closes them; none is a persistent background service. Passive resource lookup reuses already-loaded accessible images; a miss uses central HTTP, never a new browser fetch just to fill the cache. No script or simulated ad interaction is accepted from a recipe.
- Use `browse` for at most 24 real directories and `searchURLTemplate` only for a verified directory endpoint containing `{query}`. Catalog `next`, sort axes and selected links must be real directory destinations. A normal public JSON API can instead declare `pagination` with offset/limit/total response paths and the offset query parameter. Check page two, final/empty responses, and retained search/sort parameters. Omit unsupported controls; don't manufacture endpoints, client-side sorts or unsupported action scripts.

Unknown rule options are rejected. Reuse the same stable `id`; increment `version` for any installed recipe change so snapshots refresh. Unmatched optional metadata is omitted; preserve the site's original rating scale, status wording and tags. Avoid patterns that silently capture ad images or loading placeholders as content pages.

## Validate in layers

From the repository root, replace the example paths/URLs below with the actual recipe and observed destinations:

```sh
swift run --package-path Packages/MangaCore manga-probe --rule /tmp/site.json --rendered 'https://reader.example/catalog'
swift run --package-path Packages/MangaCore manga-probe --rule /tmp/site.json --rendered --references 'https://reader.example/series/example'
swift run --package-path Packages/MangaCore manga-probe --rule /tmp/site.json --rendered 'https://reader.example/chapter/example'
swift run --package-path Packages/MangaCore manga-probe --rule /tmp/site.json --rendered --range 4:2 'https://reader.example/chapter/example'
swift run --package-path Packages/MangaCore manga-probe --rule /tmp/site.json --rendered --no-background 'https://reader.example/chapter/example'
swift run --package-path Packages/MangaCore manga-probe --rule /tmp/site.json --rendered --snapshot /tmp/source.html 'https://reader.example/catalog'
swift test --package-path Packages/MangaCore
```

The first invocation decodes/validates the rule before requesting data. The chapter probe reports the full declared count and decodes the first image. `--range start:count` resolves a zero-based chapter range; verify middle/final pages to catch truncated lazy DOMs. Combine it with `--snapshot` for the advanced DOM. `--references` exposes all chapter references for order inspection; keep its output local if URLs contain tokens. `--snapshot` saves the fetched HTML/JSON and returns before extraction. Use `--diagnostics` to list source-text hosts without dumping paths; it is not proof those resources were requested or required.

Verify at least: one directory and its next/sort links if provided; manga cover/metadata and full order; two chapters with full page counts and decoded images; valid/empty searches; background loading on/off; no unexpected hosts. Run the native app on iPhone/iPad for a new rendered source because WebKit content modes can differ. The first bundled filename declares the shipped default and is adopted once even on existing installations; subsequent user order/removal is preserved. Use Settings → Restore bundled rules for other newly bundled recipes, or import the JSON through the normal preview. Restore respects newer installed versions and keeps reading data.

Add a small original synthetic fixture only where it guards a real risk, such as lazy page completeness, optional metadata or source order. Exercise the actual recipe rather than implementing a second parser inside the test. Keep live checks out of the deterministic UI suite. If the engine changed, run affected platform builds and request a clean-session review of policy enforcement, request ownership, cancellation and the JSON-only boundary.

## Example evidence and maintenance

The bundled `00-mangacopy.json` demonstrates asynchronous HTML directories/manga and default rendered-DOM chapters. Its initial chapter DOM exposes three lazy images and a complete count (205 pages for the first tested volume); its JSON scroll strategy exposes later URLs without observing JavaScript data. Its chapter selector omits a latest shortcut outside the chapter tabs. Its search uses a named JSON extractor for the public endpoint requested by the website, with identifier/title fields and offset/limit/total pagination. Core probes verified two 12-item pages and an empty response. Native pull-to-load testing/fixes were deferred at the user’s request; do not claim that gesture is verified. Live sites can change: current dates, tested URLs/counts and native results belong in [DEV_STATE](../docs/DEV_STATE.md).

When changing the language, update `docs/RULES.md`, this guide and the prompt in the same milestone. Record limits and verification honestly, including failed or unavailable checks. Audit production Swift/bridge code for source-specific strings. Verify these authoring files have not entered a target/resource directory, resolve clean-session review findings, then commit JSON/code/documentation together.
