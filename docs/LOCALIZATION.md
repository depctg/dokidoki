# Localization

The app uses Apple's native resources and language selection. English is the development language; Simplified Chinese (`zh-Hans`) is also included. The app follows the system or per-app language setting. There is no custom language manager or in-app override.

- `App/Localizable.xcstrings` contains app UI and accessibility text. SwiftUI literal labels are localizable automatically. Use `String(localized:)` for stored/composed Strings, conditional labels, fallback text and app-created errors. Never pass an already interpolated ordinary String as a localization key.
- `App/InfoPlist.xcstrings` contains localized bundle display/copyright text. The MangaViewer brand remains unchanged.
- `Packages/MangaCore/Sources/MangaCore/Localization/{en,zh-Hans}.lproj/Localizable.strings` contains core error messages, detailed rule/extraction errors and generated labels. Calls use `String(localized: ..., bundle: .module)`. Native `.strings` package resources work in both command-line SwiftPM and Xcode; they do not require a catalog compilation step for `swift test` or `manga-probe`.

The package copies `Resources/Rules` and `Resources/Fixtures` as separate bundle folders. A copied root folder literally named `Resources` makes Foundation ignore sibling `.lproj` folders; do not reintroduce it. The localization test checks native bundle language discovery as well as the translations.

Translate complete messages and retain their typed placeholders. Catalog entries for chapter counts and last-read hours/days use native plural variations. Number and byte-count formatting uses Foundation/SwiftUI. Source titles, authors, descriptions, ratings, statuses, tags, site names and list names remain as captured from site rules. Diagnostic CLI output is developer tooling; the underlying errors use the package translations.

Reader preferences retain their original Codable raw values. Localized display labels are separate properties. Never translate object keys, file paths, URLs, source selectors, accessibility identifiers, or persistence values. Existing user data needs no migration. The rare generated “Untitled” source fallback is stored with its extracted snapshot and retains that language until the source is refreshed; actual source titles always remain verbatim.

## Adding or updating translations

Open the app catalog in Xcode and edit the desired language. Xcode's compiler string extraction is enabled for Debug and Release (`SWIFT_EMIT_LOC_STRINGS`). Build before reviewing new strings; the Xcode editor can synchronize extracted entries. With CLI builds, use Apple's `xcstringstool sync` on the catalog with the app target's generated `.stringsdata` files under the relevant `build/Build/Intermediates.noindex/.../Objects-normal/<arch>` directory. Add package translations in the matching `.lproj/Localizable.strings` files, preserving identical key sets and format specifiers.

For another language, add it to the catalog/project localizations and the package resource directory. Use Xcode's Export Localizations/Import Localizations workflow for translator exchange. Check long text, native layout direction, plural forms and VoiceOver labels on a simulator. System controls such as Edit, file panels and sharing use the platform's localization.

The two main UI journeys explicitly run in English to keep gesture/navigation assertions deterministic across simulator languages. Localization changes also need a native non-English launch check, including a core error, input sheets, reader labels and source text preservation. Core tests verify resource loading, format placeholders and stored preference compatibility.

Apple references: [String Catalogs](https://developer.apple.com/documentation/xcode/localizing-and-varying-text-with-a-string-catalog), [preparing text](https://developer.apple.com/documentation/xcode/preparing-your-apps-text-for-translation), and [package resources](https://developer.apple.com/documentation/xcode/localizing-package-resources).
