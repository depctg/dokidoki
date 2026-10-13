# Rule format (schema 1)

The bundled JSON in `Packages/MangaCore/Sources/MangaCore/Resources/Rules` is the canonical example. Every JSON file in that directory is loaded automatically. Import accepts at most 128 KiB. `id` is stable; increase `version` whenever an installed recipe changes so cached snapshots refresh. **All site-specific parsing must be here or in imported object-parsing JSON.** Swift, views, and injected bridges must never encode website selectors, filename extensions, URL construction, or site-dependent exceptions. The required development checklist is in AGENTS.md.

`allowedHosts` contains exact lowercase hosts, including image CDNs. Requests, redirects, and extracted URLs use HTTP(S), without user info, and default web ports. Apple's default App Transport Security policy still applies. Matchers are anchored regular expressions with integer `priority`; ties are errors. Matching preserves query parameters and strips fragments. A matcher may name an `extractor` key; omission selects its kind name. This supports, for example, an HTML catalog and a JSON search endpoint that both produce directories. Transport, rendered admission and parsing all use that same selection.

Each extractor has `fields` and an optional `format` (default `renderedHTML`):

- `html` / `renderedHTML`: XPath `path`; `read` is `text` (default) or `attr:name`, with optional `fallback` reader.
- `json` / `renderedJSON`: dotted `path`, numeric array indices, and `*` for ordered array traversal. Values are strings/numbers or `{ "url": "…", "title": "…" }` link objects. For differently shaped link objects, `read: "attr:property"` selects their value property and optional `titlePath` selects a relative dotted label path (default `title`). `fallback` can read an alternative property. URL templates apply to the selected value.
- Optional field `reverse: true` reverses selected entries before transformations; omitted/false preserves source order. Use it when a site's chapter list is newest first so `chapterLinks` follows reading order. The reversal decision belongs in JSON.
- Optional `regex` selects the first match from each extracted value. `group` selects a capture (default 1, or 0 when there are no captures). No match omits that value.
- Optional extractor `variables` maps names to the same selector/regex fields. Each takes its first value. Variables are independent: no nesting, dependencies, URL templates, or expressions.
- Optional field `urlTemplate` substitutes `{value}` (the selected/regex-filtered value), `{vars.name}`, and `{dotted.json.path}` scalar values. Missing placeholders fail extraction. There are no functions, operators, loops, or evaluation of code.
- Optional field `queryPath` names a JSON object whose scalar values are appended as URL query parameters using Foundation's URL encoding.

URLs resolve against the final response URL and must still pass the exact-host policy after substitutions. Templates do not confer network permissions. Extensions remain literal data: the engine never guesses image filename suffixes or CDN paths.

| Kind | Required fields | Optional fields |
| --- | --- | --- |
| directory | title, mangaLinks | next, totalCount, sortByLinks, sortOrderLinks, selectedSortBy, selectedSortOrder |
| manga | title, chapterLinks | author, summary, coverImage, rating, status, tags |
| chapter | title, pageImages | mangaLink, totalCount, pageNumber |
| page | image | title |

Manga `rating` and `status` use the first nonblank selected value; `tags` uses all nonblank selected values, deduplicated in source order. They use the existing XPath/JSON path and regex options. Rating and status remain source text (for example `4.5 / 5`, `Ongoing`, or `已完结`); Swift does not invent a scale, translate source labels, or infer a status. Omitted fields and unmatched selectors produce no metadata UI. Exclude site placeholders with a rule regex when necessary. Older manga snapshots without these keys remain readable.

Optional `browse` declares the Site object’s ordered directories as `{ "title": "Recent updates", "url": "https://reader.example/recent" }` entries. Each URL must be an allowed directory URL matched by this rule. Titles must be nonempty; URLs must be unique after normalization; at most 24 directories are accepted. Core normalizes these URLs into SiteObject.directoryRefs; each target parses as a single DirectoryObject list. The declared title is also the directory title when that exact URL is parsed. Browse previews up to eight manga per shelf and opens the full directory when its heading is selected. Omission remains valid for older imported rules.

Directory sorting is optional and uses the existing `Field` language. `sortByLinks` and `sortOrderLinks` select titled links to directory URLs; `selectedSortBy` and `selectedSortOrder` select the active links. HTML normally uses XPath plus `read: "attr:href"`; JSON can select `{ "url": "…", "title": "…" }` objects. Each axis is independent: missing or empty links produce no picker, and both missing means no sort control. The app keeps source order and does not invent local title sorting or reverse a single fetched page.

```json
"sortByLinks": { "path": "//nav[@id='sort-by']/a", "read": "attr:href" },
"selectedSortBy": { "path": "//nav[@id='sort-by']/a[@aria-current='true']", "read": "attr:href" },
"sortOrderLinks": { "path": "//nav[@id='sort-order']/a", "read": "attr:href" },
"selectedSortOrder": { "path": "//nav[@id='sort-order']/a[@aria-current='true']", "read": "attr:href" }
```

Sort links must retain the desired search/filter context and point to the desired first page. The app follows them as supplied, replacing the displayed directory through core object loading. It never constructs site-specific sort parameters. URLs must satisfy the rule's exact-host policy and match directory objects; repeated destinations are deduplicated. Selected options are matched by object key; if omitted, the current directory key can identify an active option. Labels are source data. Pagination follows the `next` URL as a normalized directory reference, preserving whatever sorting the source encodes. DirectoryObject.load(_:using:) delegates to the core range session, which appends references in source order, removing duplicate keys while retaining the first page identity and sorting. The core range session rejects repeated next-page keys. Links matching another content kind are omitted; off-host links fail extraction. Older rules and snapshots without these fields remain valid.

For a JSON directory API that provides counters instead of a next URL, an extractor may declare:

```json
"pagination": { "offset": "results.offset", "limit": "results.limit", "total": "results.total", "parameter": "offset" }
```

The first three values are scalar JSON paths; `parameter` names the URL query item to replace with `offset + limit`. Other query items are preserved. Counters must be integers, offset/total nonnegative and limit positive; overflow is rejected. No next reference is emitted once the next offset reaches total. The resulting URL must remain an allowed directory in the same rule. This option is JSON-directory-only and cannot accompany a `next` field. There are no custom arithmetic expressions or pagination scripts. Verify the endpoint and counters against normal website requests; do not infer them from a UI page number.

`searchURLTemplate` uses `{query}`, escaped as one URL component, and must resolve to an allowed directory URL in the same rule. SiteObject owns query escaping and revalidates the actual result URL against its own host policy and directory matchers. Search returns a directory reference loaded through the same core object/repository/sender path as other lists. Search is submitted explicitly rather than requesting on every keystroke. `processors` selects compiled `identity`, `marginAlign`, `spreadDetect`, and `layout` page processors. These affect display planning, not site parsing.

## Rendered sources

Rendered formats run the website's own scripts in an ephemeral, hidden WebKit session, admitted by the same core request sender. Optional `rendering.contentMode` is `recommended`, `desktop`, or `mobile`. `renderedHTML` returns the DOM for XPath extraction. Optional `rendering.readyXPath` waits for a site-created DOM node, including an explicit empty-result marker, before taking a snapshot. It must select nodes, not return a scalar. Without it, HTML waits for navigation completion; asynchronous lists usually need it. Waiting is bounded to 30 seconds and snapshots to 8 MiB.

Background resource loading defaults to **on**. Every rendered object-kind extractor can set `rendering.loadAds: false` to block images/media/fonts within its hidden metadata session. Omitted/true allows normal loads to the exact declared hosts; Settings → Website loading → Background resource loading can disable them globally and takes precedence. This setting does not block native manga image downloads, scripts or documents. Changing it cancels old object requests; cached content remains usable and future rendered loads use the new policy. No ad view is presented, no clicks or other ad interactions are synthesized, automatic media playback/popups are disabled, and sessions close on cancellation, refresh, invalidation or idle expiry. There is no persistent background task. Hosts, redirects and final URLs remain restricted in either mode; WebKit manages subresources in up to four retained contexts; the sender admits one rendered operation at a time.

### Persistent session actions and partial chapters

The manager indexes hidden sessions by logical URL (including query), full rule policy, selected extractor and background preference. It retains up to four contexts with a 60-second idle expiry. Directory link continuation may reuse the original list context. Cookies and browser state are ephemeral and never serialized into content objects. Cached content survives browser disposal.

An optional `session` object supports three strategies:

| mode | Behavior | Required options |
| --- | --- | --- |
| `load` (also the behavior when omitted) | Load/read the document; no continuation action | none |
| `page` | Click the selected page/next/load button, or select an OPTION and dispatch its change event | `actionXPath` |
| `scroll` | Scroll the selected element into view and notify scroll listeners | `actionXPath` |

Page/scroll strategies require rendered HTML and a chapter or directory extractor. `actionXPath` and optional `endXPath` select DOM nodes; no imported scripts or arbitrary expressions execute. For chapter targets only, `{index}` substitutes the requested one-based source page (for example `//select/option[@value='{index}']`). Directories use an ordinary next/load control, not indexed targets. A sequential chapter next button can replay from the initial document for an uncached backward request.

For lazy chapters, `fields.totalCount` selects the full nonnegative integer page count, up to 100,000. Core creates identities for all pages while caching only image URLs actually present. `fields.pageNumber` optionally selects the one-based index of the first image currently in the DOM (default 1); following images are consecutive. Unknown URLs are never guessed. `ChapterObject.pages` returns descriptors, `load(range)` resolves a zero-based range, and each page's image method resolves its own missing URL. Resolved siblings remain cached when another range arrives. Declare a total for a partial chapter: otherwise the currently extracted images are the entire chapter.

Directories return a cumulative known prefix. The manager replays normal actions past cached item keys when its browser was disposed; no cursor lives in the object or UI. `totalCount` compares against that merged prefix, while `endXPath` can identify a source end marker (including an empty element). No declared end means the next unsuccessful action reports an error rather than falsely declaring completion. Traversal is bounded to 100 returned batches, 1,000 browser actions, 30 seconds per rendered read and five seconds without changed items. Hidden views do not wait for animation frames.

Example lazy chapter extractor (all selectors are illustrative):

```json
{
  "rendering": { "readyXPath": "//*[@id='count']" },
  "session": { "mode": "scroll", "actionXPath": "//*[@id='load-target']" },
  "fields": {
    "title": { "path": "//h1" },
    "totalCount": { "path": "//*[@id='count']" },
    "pageImages": { "path": "//main/img", "read": "attr:data-src", "fallback": "attr:src" }
  }
}
```

Session resource lookup is passive: first reuse already acquired bytes or readable pixels of already-loaded browser images. A miss uses a normal centralized HTTP/rendered request according to the rule, never a new fetch inside the old document. Native WebKit does not expose all cross-origin response bytes; tainted canvas/absent images fall back to HTTP. Buffers are bounded to four logical contexts × 24 MiB, isolated by rule, owner URL and referer, and backed by the shared durable image cache.

For the explicit compatibility format `renderedJSON`, `rendering.captureFunction` names a simple dotted function path. A fixed generic observer preserves that function's normal calls and captures the first argument, or its return value with `captureResult: true`. `rendering.readyImageXPath` must select an image the website created. Only after that image has a `src` does the adapter return `{ "data": <captured value>, "imageURL": <rendered image URL>, "title": <document title>, "url": <document URL> }` for normal JSON extraction. An optional `readyXPath` adds another readiness condition. The observer never invokes the named function, changes access gates/cookies, decrypts payloads itself, or executes rule-supplied code. Unsupported scripts/options and prototype-path components are rejected. Prefer a specific site function; when observing a shared function, verify that its last completed call at readiness contains the intended data.

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

MangaCopy v4 requests desktop content and uses rendered DOM lists, metadata and chapters. Its initial chapter DOM contains three lazy images; the DOM supplies the complete count, and the JSON scroll target exposes later image URLs as requested. No chapter JavaScript capture is needed. The iPhone `/h5` redirect, desktop choice, chapter order and all selectors remain JSON-only. Search retains its named public JSON extractor with offset/limit/total counters; catalogs expose real next/sort links. Native pull gesture verification remains deferred; see DEV_STATE. Manhuagui retains its explicit rendered-JSON compatibility recipe until live connectivity permits a verified DOM migration; do not invent selectors from a failed connection.

Use `swift run --package-path Packages/MangaCore manga-probe --rendered <URL>` for WebKit sources. Without `--rendered`, the probe reports the adapter requirement. `--rule /path/rule.json` validates and uses an unbundled recipe (replacing the same ID for this process). `--range start:count` resolves a zero-based chapter range (or requests it before a diagnostic snapshot); test a late page, not only the initial lazy images. `--no-background` tests the global off policy. `--references` prints manga chapter titles/URLs for order checks. `--diagnostics` fetches once and lists hosts found in source text; they can include unrelated links, so this is not an allowlist generator. `--snapshot /tmp/source.html` instead/also saves that source response for local inspection and returns without extraction. Snapshots may contain private/signed data or copyrighted content; keep them temporary and out of commits/log reports. See the external [authoring guide](../rule-authoring/GUIDE.md) and [AI prompt](../rule-authoring/PROMPT.md); neither is an app/package resource.

## Exchange and identity

Rules never export scripts, credentials, or custom request headers. Settings exports canonical compact JSON. QR export uses that JSON up to a conservative 1200-byte limit; larger rules use files. No multi-code transport is supported.

Reading state uses original source-page identities. Internal `reader://page/…?owner=…` keys are deterministic, scoped to a rule, and resolved through their owner without requesting the internal scheme over HTTP.

The Settings rule order is a local preference, independent of JSON matcher priority and exported recipes. The first installed rule is Browse's default; switching sites lasts for the session. Reordering does not invalidate caches or restart the reader. Allowed hosts remain enforced even though Settings rows hide them.

Bundled filenames determine initial order. `00-mangacopy.json` makes MangaCopy the shipped default. A core preference records adoption of the first bundled rule once, including existing installations; later user reordering/removal survives launches and recipe upgrades. Other removed rules are not restored automatically. Restore bundled rules remains an explicit Settings action.
