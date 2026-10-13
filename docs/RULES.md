# Rule format (schema 1)

The bundled JSON in `Packages/MangaCore/Sources/MangaCore/Resources/Rules` is the canonical example. Every JSON file in that directory is loaded automatically. Import accepts at most 128 KiB. `id` is stable; increase `version` whenever an installed recipe changes so cached snapshots refresh. **All site-specific parsing must be here or in imported object-parsing JSON.** Swift, views, and injected bridges must never encode website selectors, filename extensions, URL construction, or site-dependent exceptions. The required development checklist is in AGENTS.md.

`allowedHosts` contains exact lowercase hosts, including image CDNs. Requests, redirects, and extracted URLs use HTTP(S), without user info, and default web ports. Apple's default App Transport Security policy still applies. Matchers are anchored regular expressions with integer `priority`; ties are errors. Matching preserves query parameters and strips fragments.

Each extractor has `format` and `fields`:

- `html` / `renderedHTML`: XPath `path`; `read` is `text` (default) or `attr:name`, with optional `fallback` reader.
- `json` / `renderedJSON`: dotted `path`, numeric array indices, and `*` for ordered array traversal. Values are strings/numbers or `{ "url": "…", "title": "…" }` link objects.
- Optional `regex` selects the first match from each extracted value. `group` selects a capture (default 1, or 0 when there are no captures). No match omits that value.
- Optional extractor `variables` maps names to the same selector/regex fields. Each takes its first value. Variables are independent: no nesting, dependencies, URL templates, or expressions.
- Optional field `urlTemplate` substitutes `{value}` (the selected/regex-filtered value), `{vars.name}`, and `{dotted.json.path}` scalar values. Missing placeholders fail extraction. There are no functions, operators, loops, or evaluation of code.
- Optional field `queryPath` names a JSON object whose scalar values are appended as URL query parameters using Foundation's URL encoding.

URLs resolve against the final response URL and must still pass the exact-host policy after substitutions. Templates do not confer network permissions. Extensions remain literal data: the engine never guesses image filename suffixes or CDN paths.

| Kind | Required fields | Optional fields |
| --- | --- | --- |
| directory | title, mangaLinks | next |
| manga | title, chapterLinks | author, summary, coverImage |
| chapter | title, pageImages | mangaLink |
| page | image | title |

`searchURLTemplate` uses `{query}`, escaped as one URL component. `processors` selects compiled `identity`, `marginAlign`, `spreadDetect`, and `layout` page processors. These affect display planning, not site parsing.

## Rendered sources

Rendered formats run the website's own scripts in an ephemeral WebKit session. Optional `rendering.contentMode` is `recommended`, `desktop`, or `mobile`. `renderedHTML` returns the DOM for XPath extraction.

For `renderedJSON`, `rendering.captureFunction` names a simple dotted function path. A fixed generic observer preserves that function's behavior and captures its first argument when the website calls it normally. `rendering.readyImageXPath` must select an image the website created. Only after that image exists does the adapter return `{ "data": <captured argument>, "imageURL": <rendered image URL> }` for normal JSON extraction. It never invokes the named function, changes access gates/cookies, or executes rule-supplied code. Unsupported scripts/options and prototype-path components are rejected.

Manhuagui's chapter recipe is an example of these generic capabilities:

```json
{
  "format": "renderedJSON",
  "rendering": {
    "contentMode": "desktop",
    "captureFunction": "SMH.imgData",
    "readyImageXPath": "//*[@id='mangaFile']"
  },
  "variables": {
    "cdn": { "path": "imageURL", "regex": "^(https?://[^/]+)", "group": 1 }
  },
  "fields": {
    "title": { "path": "data.cname" },
    "mangaLink": { "path": "data.bid", "urlTemplate": "https://www.manhuagui.com/comic/{value}/" },
    "pageImages": { "path": "data.files.*", "urlTemplate": "{vars.cdn}{data.path}{value}", "queryPath": "data.sl" }
  }
}
```

Use `manga-probe --rendered <URL>` for WebKit sources. Without `--rendered`, the probe reports the adapter requirement. `--diagnostics` lists only extracted hosts, not signed paths/query strings.

## Exchange and identity

Rules never export scripts, credentials, or custom request headers. Settings exports canonical compact JSON. QR export uses that JSON up to a conservative 1200-byte limit; larger rules use files. No multi-code transport is supported.

Reading state uses original source-page identities. Internal `reader://page/…?owner=…` keys are deterministic, scoped to a rule, and resolved through their owner without requesting the internal scheme over HTTP.
