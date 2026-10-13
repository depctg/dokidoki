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
        #expect(directory.mangaRefs.count == 2)
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

    @Test func directorySortLinksLoadSourceOrderAndPreserveLegacySnapshots() async throws {
        let rule = try DemoContent.bundledRules()[0]
        let repository = try ObjectRepository(store: ObjectStore(), rules: [rule])
        let key = ObjectKey(ruleID: rule.id, identityURL: DemoContent.directoryURL)
        guard case .directory(let original) = try await key.load(using: repository) else { Issue.record("Missing directory"); return }
        #expect(original.mangaRefs.map(\.title) == ["The Observatory", "Aster House"])
        #expect(original.sortOrder == nil)
        #expect(original.selectedSortBy == key)
        let byTitle = try #require(original.sortBy?.first(where: { $0.title == "Title" }))
        guard case .directory(let ascending) = try await byTitle.load(using: repository) else { Issue.record("Missing sorted directory"); return }
        #expect(ascending.mangaRefs.map(\.title) == ["Aster House", "The Observatory"])
        #expect(ascending.selectedSortBy == byTitle.key)
        #expect(ascending.selectedSortOrder == byTitle.key)
        let descending = try #require(ascending.sortOrder?.first(where: { $0.title == "Descending" }))
        guard case .directory(let reversed) = try await descending.load(using: repository) else { Issue.record("Missing reverse directory"); return }
        #expect(reversed.mangaRefs == original.mangaRefs)
        #expect(reversed.selectedSortOrder == descending.key)
        #expect(reversed.key != original.key) // Sort URLs are distinct cache identities.
        #expect(try JSONDecoder().decode(DirectoryObject.self, from: JSONEncoder().encode(reversed)).sortOrder == reversed.sortOrder)

        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
        for field in ["sortBy", "sortOrder", "selectedSortBy", "selectedSortOrder"] { legacy.removeValue(forKey: field) }
        let decoded = try JSONDecoder().decode(DirectoryObject.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(decoded.sortBy == nil && decoded.sortOrder == nil)

        let html = "<html><h1>List</h1><nav id='sortBy'><a href='https://outside.example/list'>Denied</a></nav></html>"
        do {
            _ = try RuleExtractor().extract(data: Data(html.utf8), responseURL: key.identityURL, key: key, kind: .directory, rule: rule)
            Issue.record("Off-host sort destination accepted")
        } catch ReaderError.blockedHost {}
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
