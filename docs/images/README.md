# README images

These are native app captures using the original, repository-owned Bundled reading room artwork. They contain no downloaded manga or third-party website artwork.

- `app-icon.png`: 256 × 256 native Icon Composer export of `App/AppIcon.icon`, iOS Default rendition.
- `library.png`, `manga.png`, `reader.png`: full-resolution iPhone 18 Pro simulator captures. README uses display widths only; the PNGs retain their original resolution and aspect ratio.

To refresh, use an isolated simulator, open the bundled example manga through the normal app, and capture Library, manga details and immersive reading. Preserve the user's real library. Export the icon with the `ictool` workflow in [ICON.md](../ICON.md); capture app screens with native XCTest or `simctl io <device> screenshot`.

These documentation assets are outside the app and package resources.
