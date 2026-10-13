import Foundation
import Testing
@testable import MangaCore

struct PaginationTests {
    @Test func jsonSearchKeepsTitlesContextAndStopsAtTheEnd() throws {
        let rule = try #require(DemoContent.bundledRules().first { $0.id == "mangacopy" })
        let ref = try #require(try SiteObject(rule: rule).search("one & two"))
        #expect(rule.extraction(for: .directory, at: ref.key.identityURL)?.format == .json)
        #expect(rule.extraction(for: .directory, at: rule.browse![0].url)?.format == .renderedHTML)
        func parse(offset: Any = 0, limit: Any = 2, total: Any = 3, data: [[String: Any]] = [["path_word": "a", "name": "First title"], ["path_word": "b", "name": "Second title"]]) throws -> DirectoryObject {
            let input: [String: Any] = ["message": "Results", "results": ["offset": offset, "limit": limit, "total": total, "list": data]]
            let objects = try RuleExtractor().extract(data: JSONSerialization.data(withJSONObject: input), responseURL: ref.key.identityURL, key: ref.key, kind: .directory, rule: rule)
            guard case .directory(let list) = objects[0] else { throw ReaderError.invalidResponse }
            return list
        }
        let first = try parse()
        #expect(first.mangaRefs.map(\.title) == ["First title", "Second title"])
        #expect(first.mangaRefs[0].key.identityURL.path == "/comic/a")
        let next = try #require(first.nextPage)
        let items = URLComponents(url: next.key.identityURL, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(items.filter { $0.name == "offset" }.map(\.value) == ["2"])
        #expect(items.first { $0.name == "q" }?.value == "one & two")
        #expect(next.key.ruleID == rule.id)
        #expect(try parse(offset: 2).nextPage == nil)
        #expect(try parse(total: 0, data: []).nextPage == nil)
        for (offset, limit, total): (Any, Any, Any) in [(-1, 2, 3), (0, 0, 3), (0, 1.5, 3), (0, 2, "missing"), (Int.max, 2, Int.max)] {
            #expect(throws: ReaderError.self) { try parse(offset: offset, limit: limit, total: total) }
        }
        var json = try JSONSerialization.jsonObject(with: rule.exported()) as! [String: Any]
        var matchers = json["matchers"] as! [[String: Any]]
        matchers[1]["extractor"] = "missing"; json["matchers"] = matchers
        #expect(throws: ReaderError.self) { try SiteRule.decode(JSONSerialization.data(withJSONObject: json)) }
        var hostile = rule
        // URL templates still pass exact-host checking after selecting JSON object fields.
        json = try JSONSerialization.jsonObject(with: rule.exported()) as! [String: Any]
        var extractors = json["extractors"] as! [String: [String: Any]]
        var fields = extractors["search"]!["fields"] as! [String: [String: Any]]
        fields["mangaLinks"]!["urlTemplate"] = "https://outside.example/{value}"
        extractors["search"]!["fields"] = fields; json["extractors"] = extractors
        hostile = try SiteRule.decode(JSONSerialization.data(withJSONObject: json))
        let data = Data(#"{"message":"Results","results":{"offset":0,"limit":2,"total":1,"list":[{"path_word":"a","name":"Title"}]}}"#.utf8)
        #expect(throws: ReaderError.self) { try RuleExtractor().extract(data: data, responseURL: ref.key.identityURL, key: ref.key, kind: .directory, rule: hostile) }
    }

    @Test func directoryOwnsAppendingAndDeduplicatesAcrossPages() async throws {
        let rules = try DemoContent.bundledRules()
        let rule = try #require(rules.first { $0.id == "demo" })
        let repository = try ObjectRepository(store: ObjectStore(), rules: rules)
        let firstRef = try #require(try SiteObject(rule: rule).search("story"))
        guard case .directory(let first) = try await firstRef.load(using: repository) else { throw ReaderError.invalidResponse }
        #expect(first.mangaRefs.count == 1)
        let joined = try await first.loadingNext(using: repository)
        #expect(joined.key == first.key && joined.sourceURL == first.sourceURL)
        #expect(joined.sortBy == first.sortBy)
        #expect(joined.mangaRefs.map(\.title) == ["The Observatory", "Aster House"])
        #expect(joined.nextPage == nil)
        #expect(try await joined.loadingNext(using: repository).mangaRefs == joined.mangaRefs)
    }

    @Test func shippedDefaultIsAdoptedOnceAndRespectsLaterUserChoices() throws {
        let bundled = try DemoContent.bundledRules(), first = try #require(bundled.first)
        #expect(first.id == "mangacopy")
        let store = try ObjectStore()
        // Existing installation with an intentionally missing non-default rule.
        let old = try #require(bundled.first { $0.id == "demo" })
        try store.saveRule(old); try store.setPreference("seeded", value: true)
        try store.setPreference("backgroundLoading", value: false)
        try store.applyBundledRules(bundled)
        #expect(try store.rules().map(\.id) == [first.id, old.id])
        #expect(try store.preference("backgroundLoading", as: Bool.self) == false)
        try store.setRuleOrder([old.id, first.id])
        try store.applyBundledRules(bundled)
        #expect(try store.rules().map(\.id) == [old.id, first.id])
        try store.removeRule(first.id)
        try store.applyBundledRules(bundled)
        #expect(try store.rules().map(\.id) == [old.id])
        let fresh = try ObjectStore()
        try fresh.applyBundledRules(bundled)
        #expect(try fresh.rules().map(\.id) == bundled.map(\.id))
    }
}
