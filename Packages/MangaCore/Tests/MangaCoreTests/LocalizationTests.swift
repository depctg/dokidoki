import Foundation
import Testing
@testable import MangaCore

struct LocalizationTests {
    @Test func packageTranslationsPreserveFormatsAndStoredPreferences() throws {
        // A copied folder named Resources can hide root localizations from Foundation.
        #expect(Set(Bundle.module.localizations).isSuperset(of: ["en", "zh-Hans"]))
        let englishURL = try #require(Bundle.module.url(forResource: "en", withExtension: "lproj"))
        let chineseURL = try #require(Bundle.module.url(forResource: "zh-Hans", withExtension: "lproj"))
        let english = try #require(Bundle(url: englishURL))
        let chinese = try #require(Bundle(url: chineseURL))
        #expect(String(localized: "This URL is not supported by an installed rule.", bundle: chinese) == "已安装的规则不支持此 URL。")
        let code = 403
        #expect(String(localized: "The server returned HTTP \(code). Try refreshing the chapter or opening the source website.", bundle: chinese).contains("HTTP 403"))
        let reason = "XPath"
        #expect(String(localized: "Invalid rule: \(reason)", bundle: chinese) == "规则无效：XPath")
        #expect(String(localized: "Invalid rule: \(reason)", bundle: english) == "Invalid rule: XPath")

        func strings(_ url: URL) throws -> [String: String] {
            let data = try Data(contentsOf: url.appendingPathComponent("Localizable.strings"))
            return try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
        }
        let en = try strings(englishURL), zh = try strings(chineseURL)
        #expect(Set(en.keys) == Set(zh.keys))
        let pattern = try NSRegularExpression(pattern: "%(@|lld)")
        func placeholders(_ text: String) -> [String] {
            pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { String(text[Range($0.range, in: text)!]) }.sorted()
        }
        for (key, value) in en {
            #expect(zh[key]?.isEmpty == false)
            #expect(placeholders(value) == placeholders(zh[key] ?? ""))
        }
        // Localization must not rename values previously persisted in user preferences.
        #expect(try JSONDecoder().decode(ReadingMode.self, from: Data(#""Paged""#.utf8)) == .paged)
        #expect(try JSONDecoder().decode(ReadingDirection.self, from: Data(#""Right to left""#.utf8)) == .rightToLeft)
        #expect(try JSONDecoder().decode(SpreadOverride.self, from: Data(#""Keep original""#.utf8)) == .keep)
    }
}
