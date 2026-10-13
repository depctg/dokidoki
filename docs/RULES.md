# Rule format (schema 1)

The bundled JSON in `Packages/MangaCore/Sources/MangaCore/Resources` is the canonical example. Import accepts at most 128 KiB. `id` is stable; `version` must increase when changing an installed rule. `schemaVersion` is currently 1.

`allowedHosts` contains exact lowercase hosts, including image CDNs. External URLs must use HTTP(S), without user info, and use default web ports. Matching preserves query parameters and removes fragments. Matchers are anchored regular expressions with an integer `priority`; ties are errors. Every matcher names a `directory`, `manga`, `chapter`, or `page` extractor.

Each extractor has `format` (`html`, `json`, or `renderedHTML`) and `fields`. HTML fields use XPath `path`; `read` is `text` (default) or `attr:name`, with an optional fallback reader. JSON fields use dotted key paths, numeric array indices, and `*` for ordered array traversal. Link entries can be strings or `{ "url": "...", "title": "..." }` objects. URLs resolve relative to the final response URL.

| Kind | Required fields | Optional fields |
| --- | --- | --- |
| directory | title, mangaLinks | next |
| manga | title, chapterLinks | author, summary, coverImage |
| chapter | title, pageImages | mangaLink |
| page | image | title |

`searchURLTemplate` may contain `{query}`; it is escaped as a URL component before use. `processors` may name compiled `identity`, `marginAlign`, `spreadDetect`, and `layout` processors. Imported rules never contain executable scripts, credentials, or custom request headers.

`renderedHTML` requires an app-supplied fetch adapter. The command-line probe deliberately reports that requirement. A rule cannot provide its own JavaScript. Manhuagui uses this format for chapters, since its HTML contains scripts rather than page images. Normal directory and manga extraction uses HTTPS and XPath.

Reading state uses original source-page identities. Internal `reader://page/…?owner=…` keys are deterministic, scoped to a rule, and resolved through their parent without an HTTP request to the internal scheme.
