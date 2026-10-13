# Error diagnostics

`ErrorDiagnostics` in MangaCore uses Apple's [Logger](https://developer.apple.com/documentation/os/logging/) at error severity. Settings → Error report reads [OSLogStore](https://developer.apple.com/documentation/oslog/oslogstore) with `currentProcessIdentifier` scope and offers native sharing/text-file export. There is no telemetry service or automatic upload, extra dependency, log database, or custom crash handler.

## Coverage and ownership

- Core `ObjectKey.load` and `PageObject.image` record failed object/image loads, including covers, prefetch and rendered-source failures. UI catches display those errors without recording them again. A later failed retry is a new error; separate failed callers may produce separate entries even when transport is shared.
- App startup, library/preferences persistence, rule import/export/update, image-cache create/write/remove failures, processor errors and report failures use the same recorder. Best-effort cache lookups, successful fallback operations and missing optional content are not errors.
- Swift task cancellation, URLSession cancellation and native user cancellation are excluded. A deliberate offline-only cache miss is excluded. Do not add request-start/success, navigation, debug or performance events to this logger.

## Report data

Each entry contains its time, fixed operation/reason codes, HTTP or native error code when applicable, and an optional hostname. Raw error descriptions/userInfo are deliberately not logged: these can contain signed URLs, credentials, page text, imported JSON or local paths. URL paths, queries, fragments, headers and content titles are excluded. Unknown NSError domains are represented as `other` plus their numeric code. Technical codes remain stable across languages; the report interface is localized in English and Simplified Chinese.

Reports include app/build and OS versions, plus the latest 200 error/fault entries in the app's `com.mangaviewer.reader` / `errors` category within the last 24 hours. Filtering excludes messages from other frameworks and non-error levels. The system owns retention, and log ingestion can take a moment; Refresh reads a new snapshot. Collection runs off the main actor.

The native current-process scope means in-app reports cover the current launch, not previous launches or crash archives. Reproduce an issue and export before quitting. Apple's Console/Xcode tools retain their normal system-log capabilities. The app does not attempt to erase Apple's log store.

## Verification

Core tests exercise real native log retrieval after failed object/image loads, severity filtering, cancellation suppression and sensitive-data exclusion. The existing shell UI journey opens a failing offline fixture, reviews its sanitized report and opens native export. Reader gesture coverage remains in its separate journey.
