import Foundation
import Testing
@testable import MangaCore

struct BrowseTests {
    @Test func listsAndSearchStayRuleScopedAndValidateURLs() async throws {
        let rule = try DemoContent.bundledRules()[0]
        let base = try JSONSerialization.jsonObject(with: rule.exported()) as! [String: Any]
        let list = try #require(rule.browse?.first)
        let store = try ObjectStore()
        let repository = try ObjectRepository(store: store, rules: [rule])
        let key = ObjectKey(ruleID: rule.id, identityURL: list.url)
        guard case .directory(let directory) = try await key.load(using: repository) else { Issue.record("Missing list"); return }
        #expect(directory.mangaRefs.count == 1)
        let query = "星 & title/?# +"
        let url = try #require(rule.searchURL(query: query))
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems == [URLQueryItem(name: "q", value: query)])
        #expect(try RuleRegistry(rules: [rule]).match(url).1 == .directory)
        #expect(try SiteRule.decode(rule.exported()).browse?.map(\.url) == [list.url])
        var legacy = base; legacy.removeValue(forKey: "browse"); legacy.removeValue(forKey: "searchURLTemplate")
        #expect(try SiteRule.decode(JSONSerialization.data(withJSONObject: legacy)).browse == nil)
        for invalid: [[String: String]] in [
            [["title": "Denied", "url": "https://outside.example/catalog"]],
            [["title": "Wrong kind", "url": "https://demo.mangaviewer.local/chapter/arrival"]],
            [["title": " ", "url": list.url.absoluteString]],
            [["title": "One", "url": list.url.absoluteString], ["title": "Duplicate", "url": list.url.absoluteString + "#duplicate"]],
            [["title": "Script", "url": list.url.absoluteString, "script": "execute()"]]
        ] {
            var json = base; json["browse"] = invalid
            #expect(throws: ReaderError.self) { try SiteRule.decode(JSONSerialization.data(withJSONObject: json)) }
        }
        var invalidSearch = base; invalidSearch["searchURLTemplate"] = "https://demo.mangaviewer.local/chapter/{query}"
        #expect(throws: ReaderError.self) { try SiteRule.decode(JSONSerialization.data(withJSONObject: invalidSearch)) }
    }

    @Test func ruleOrderSurvivesRestartAndRecipeReplacement() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try ObjectStore(path: path)
        let rules = try DemoContent.bundledRules()
        for rule in rules { try store.saveRule(rule) }
        let order = rules.map(\.id).reversed().map { $0 }
        try store.setRuleOrder(order)
        let reopened = try ObjectStore(path: path)
        #expect(try reopened.rules().map(\.id) == order)
        let top = try #require(reopened.rules().first)
        var json = try JSONSerialization.jsonObject(with: top.exported()) as! [String: Any]
        json["version"] = top.version + 1
        try reopened.saveRule(SiteRule.decode(JSONSerialization.data(withJSONObject: json)))
        #expect(try reopened.rules().map(\.id) == order)
        #expect(throws: ReaderError.self) { try reopened.setRuleOrder([top.id, top.id]) }
        try reopened.removeRule(top.id)
        try reopened.saveRule(top)
        #expect(try reopened.rules().map(\.id) == Array(order.dropFirst()) + [top.id])
    }
}
