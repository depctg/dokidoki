# Creating a site rule

This guide and [copyable prompt](PROMPT.md) are maintained developer material for a capable AI or human author. They stay outside `App/`, `Packages/`, Xcode resource membership and SwiftPM targets. [docs/RULES.md](../docs/RULES.md) is the schema reference; bundled JSON is executable evidence of that schema. Do not copy this guide into the application.

## Model and boundaries

`SiteObject` derives named directories and a search interface from a rule. Each `DirectoryObject` is one list. Manga own ordered chapter references, chapters own source-page references, and pages own image resources. Core object APIs request data through the repository and one shared sender, which handles concurrency, bursts, deduplication and cancellation. A recipe describes data; it does not own transport or run a scraping program.

Every source-dependent choice belongs in JSON, including hostnames, URL formats, DOM classes/IDs, observation paths, regexes, chapter ordering and image extensions. A site name appearing in production Swift or bridge JavaScript is a failed review. Synthetic test markup may model an actual rule, but production parsing cannot branch on that site. Adding a recipe normally requires no Swift changes.

## Collect evidence before writing

1. Fetch the public homepage and representative list/manga/chapter URLs. Compare a bounded direct request with a normal browser when necessary. Record HTTP/redirect failures separately; do not repair selectors when no HTML arrived.
2. Inspect source and rendered DOM. Compare desktop and iPhone user agents/redirects before assuming the same DOM; declare `rendering.contentMode: "desktop"` in JSON when that is the structure being parsed. Identify title, cover, metadata, ordered chapters, image URLs and a complete-result signal. Verify counts against the website. A few images in a lazy DOM do not establish a complete chapter.
3. Follow public list/search/sort links and inspect their actual destinations. Preserve identifying query parameters. Check a successful query and a deliberately empty query. A loading placeholder must not be mistaken for an empty response.
4. List the exact document, script and image hosts needed by those examples. A diagnostics host can be an ad click destination or analytics URL; do not add every discovered string automatically. Extra hosts need evidence. Never replace the host list with a wildcard or relax the policy in Swift.
5. Observe source order and alternative chapter groups. Exclude the latest-chapter shortcut before extracting the full list. `reverse` only reverses the selection; it is not a title-based sort. The resulting `MangaObject` decides previous/next.

Do not commit downloaded manga artwork, whole site pages, credentials, signed resource URLs or copied scripts. Keep local investigation snapshots under `/tmp`. Never change access gates/cookies, bypass login or port a site's decryption. Let the website perform its own normal work; if it does not expose usable content, report the limitation.

## Choose the smallest supported recipe

- Prefer `html` with XPath or `json` with dotted paths. Use `read`, `fallback`, `regex`/`group`, named scalar `variables`, `urlTemplate` and `queryPath` only where observed data requires them. HTML XPath fields select nodes; they are not arbitrary expressions returning strings/numbers. JSON templates substitute strings without evaluating code or inventing encodings.
- Use `renderedHTML` for asynchronous DOM content. `rendering.readyXPath` selects an existing site-created node that means extraction can finish. Include a genuine completed-empty marker if applicable; without one, a missing list times out instead of silently caching an empty snapshot.
- Use `renderedJSON` when normal script execution passes/returns complete data while the visible DOM is partial. Declare a dotted `captureFunction`, optionally `captureResult: true`, and a mandatory `readyImageXPath` for a site-created image with `src`. The observer preserves the normal call and emits `data`, `imageURL`, document `title` and `url`. It never invokes a function on behalf of the rule. Broad functions can receive unrelated calls: verify the captured value at readiness on more than one chapter.
- Hidden WebKit images/media/fonts load by default, including ads on declared hosts. A rendered extractor may set `loadAds: false`; the global Background resource loading setting overrides any opt-in. This affects only temporary metadata sessions, not native reader image downloads. Scripts/documents still run with resources off. The renderer disables automatic media playback/popups, displays no ads, and stops when extraction completes. No script or simulated ad interaction is accepted from a recipe.
- Use `browse` for at most 24 real directories and `searchURLTemplate` only for a verified directory endpoint containing `{query}`. Catalog `next`, sort axes and selected links must be real directory destinations. Omit unsupported controls; don't manufacture client-side sorts or JavaScript pagination actions.

Unknown rule options are rejected. Reuse the same stable `id`; increment `version` for any installed recipe change so snapshots refresh. Unmatched optional metadata is omitted; preserve the site's original rating scale, status wording and tags. Avoid patterns that silently capture ad images or loading placeholders as content pages.

## Validate in layers

From the repository root, replace the example paths/URLs below with the actual recipe and observed destinations:

```sh
swift run --package-path Packages/MangaCore manga-probe --rule /tmp/site.json --rendered 'https://reader.example/catalog'
swift run --package-path Packages/MangaCore manga-probe --rule /tmp/site.json --rendered --references 'https://reader.example/series/example'
swift run --package-path Packages/MangaCore manga-probe --rule /tmp/site.json --rendered 'https://reader.example/chapter/example'
swift run --package-path Packages/MangaCore manga-probe --rule /tmp/site.json --rendered --no-background 'https://reader.example/chapter/example'
swift run --package-path Packages/MangaCore manga-probe --rule /tmp/site.json --rendered --snapshot /tmp/source.html 'https://reader.example/catalog'
swift test --package-path Packages/MangaCore
```

The first invocation decodes/validates the rule before requesting data. The chapter probe resolves pages and decodes the first image. `--references` exposes all chapter references for order inspection; keep its output local if URLs contain tokens. `--snapshot` saves the fetched HTML/JSON and returns before extraction. Use `--diagnostics` to list source-text hosts without dumping paths; it is not proof those resources were requested or required.

Verify at least: one directory and its next/sort links if provided; manga cover/metadata and full order; two chapters with full page counts and decoded images; valid/empty searches; background loading on/off; no unexpected hosts. Run the native app on iPhone/iPad for a new rendered source because WebKit content modes can differ. Use Settings → Restore bundled rules to add a newly bundled recipe to an existing installation, or import the JSON through the normal preview. Restore respects newer installed versions and keeps reading data.

Add a small original synthetic fixture only where it guards a real risk, such as lazy page completeness, optional metadata or source order. Exercise the actual recipe rather than implementing a second parser inside the test. Keep live checks out of the deterministic UI suite. If the engine changed, run affected platform builds and request a clean-session review of policy enforcement, request ownership, cancellation and the JSON-only boundary.

## Example evidence and maintenance

The bundled `mangacopy.json` demonstrates asynchronous HTML directories/manga plus a normal JSON function result for chapters. Its initial chapter DOM exposes three lazy images while the observed result exposes the complete list (205 pages for the first tested volume). Its chapter selector omits a latest shortcut outside the chapter tabs. Its search has 12 initial results and JavaScript-only pagination; the current minimal recipe exposes the first result page and no invented next link. This limitation is source-specific, not an engine special case. Live sites can change: current dates, tested URLs/counts and native results belong in [DEV_STATE](../docs/DEV_STATE.md).

When changing the language, update `docs/RULES.md`, this guide and the prompt in the same milestone. Record limits and verification honestly, including failed or unavailable checks. Audit production Swift/bridge code for source-specific strings. Verify these authoring files have not entered a target/resource directory, resolve clean-session review findings, then commit JSON/code/documentation together.
