import Foundation
import CoreImage
import Testing
@testable import MangaCore

struct ExchangeTests {
    @Test func smallRuleQRDecodesAndLargeRuleFallsBack() async throws {
        // Keep the small-payload check independent of the expanding bundled demo recipe.
        let rule = try SiteRule.decode(Data(#"""
        {"schemaVersion":1,"id":"qr-test","name":"Small rule","version":1,
         "allowedHosts":["reader.example"],
         "matchers":[{"kind":"directory","pattern":"^https://reader\\.example/list$","priority":0}],
         "extractors":{"directory":{"format":"html","fields":{"title":{"path":"//h1"},"mangaLinks":{"path":"//a","read":"attr:href"}}}}}
        """#.utf8))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try rule.exported().write(to: file)
        #expect(try await RuleExchange.read(from: file) == rule)
        let image = try #require(try await RuleExchange.qrImage(for: rule))
        let detector = try #require(CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        let decoded = try #require((detector.features(in: CIImage(cgImage: image)).first as? CIQRCodeFeature)?.messageString)
        #expect(try SiteRule.decode(Data(decoded.utf8)).exported() == rule.exported())
        var json = try JSONSerialization.jsonObject(with: rule.exported()) as! [String: Any]
        json["name"] = String(repeating: "large rule ", count: 200)
        let large = try SiteRule.decode(JSONSerialization.data(withJSONObject: json))
        #expect(try await RuleExchange.qrImage(for: large) == nil)
        #expect(try SiteRule.decode(large.exported()).name == large.name)
    }
    @Test func ambiguousMatchesAndUnsupportedProcessorsAreRejected() throws {
        let rule = try DemoContent.bundledRules().first { $0.id == "demo" }!
        var json = try JSONSerialization.jsonObject(with: rule.exported()) as! [String: Any]
        json["id"] = "second-demo"
        let other = try SiteRule.decode(JSONSerialization.data(withJSONObject: json))
        let registry = try RuleRegistry(rules: [rule, other])
        #expect(throws: ReaderError.self) { try registry.match(DemoContent.directoryURL) }
        json["processors"] = ["download-script"]
        #expect(throws: ReaderError.self) { try SiteRule.decode(JSONSerialization.data(withJSONObject: json)) }
    }
    @Test func deletingRulesPreservesPersonalState() async throws {
        let rule = try DemoContent.bundledRules().first { $0.id == "demo" }!; let store = try ObjectStore()
        let repository = try ObjectRepository(store: store, rules: [rule])
        try await repository.install(rule)
        let directoryKey = try await repository.key(for: DemoContent.directoryURL)
        _ = try await repository.resolve(directoryKey)
        let key = ObjectKey(ruleID: rule.id, identityURL: URL(string: "https://demo.mangaviewer.local/series/observatory")!)
        try store.setSaved(SavedManga(key: key, title: "Saved"), saved: true)
        var preferences = ReaderPreferences(); preferences.trimMargins = true
        try store.setPreference("reader", value: preferences)
        try await repository.removeRule(rule.id)
        #expect(try store.rules().isEmpty)
        #expect(try store.snapshot(directoryKey) == nil)
        #expect(try store.savedManga().count == 1)
        #expect(try store.preference("reader", as: ReaderPreferences.self)?.trimMargins == true)
        await #expect(throws: ReaderError.self) { try await repository.resolve(key) }
        try await repository.install(rule)
        await #expect(throws: ReaderError.self) { try await repository.resolve(directoryKey, hint: .offlineOnly) }
    }
}
