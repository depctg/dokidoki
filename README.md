# MangaViewer

A native SwiftUI manga reader for iOS, macOS, and visionOS 26+, with a standalone URL-to-object engine.

Implementation follows [the design](docs/MangaViewer_DESIGN.md). Progress and verification are in [DEV_STATE](docs/DEV_STATE.md); development conventions are in [AGENTS.md](AGENTS.md).

The core uses Foundation networking, native XPath (libxml2), and [GRDB](https://github.com/groue/GRDB.swift) for SQLite. Rules are versioned data, never executable scripts.

Build and test the core with Xcode 26 or later:

```sh
swift test --package-path Packages/MangaCore
```
