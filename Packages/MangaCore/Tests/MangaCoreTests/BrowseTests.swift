import Foundation
import Testing
@testable import MangaCore

struct BrowseTests {
    @Test func listsAndSearchStayRuleScopedAndValidateURLs() async throws {
        let rule = try DemoContent.bundledRules().first { $0.id == "demo" }!
        let base = try JSONSerialization.jsonObject(with: rule.exported()) as! [String: Any]
        let list = try #require(rule.browse?.first)
        let store = try ObjectStore()
        let repository = try ObjectRepository(store: store, rules: [rule])
        let site = try SiteObject(rule: rule)
        #expect(site.id == rule.id && site.name == rule.name && site.version == rule.version)
        #expect(site.supportsSearch && site.browseRefs.first?.title == list.title)
        let previews = try await site.load(using: repository)
        let preview = try #require(previews.first)
        let reference = ContentReference(key: preview.key, title: preview.title)
        guard case .directory(let directory) = try await reference.load(using: repository) else { Issue.record("Missing list"); return }
        #expect(directory.mangaRefs.count == 2)
        #expect(directory.title == reference.title)
        let query = "星 & title/?# +"
        let search = try #require(try site.search(query))
        let url = search.key.identityURL
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems == [URLQueryItem(name: "q", value: query)])
        guard case .directory(let results) = try await search.load(using: repository) else { Issue.record("Missing search list"); return }
        #expect(results.key.ruleID == site.id && results.key != directory.key)
        #expect(try site.search("  \n") == nil)
        #expect(try RuleRegistry(rules: [rule]).match(url).1 == .directory)
        #expect(try SiteRule.decode(rule.exported()).browse?.map(\.url) == [list.url])
        var legacy = base; legacy.removeValue(forKey: "browse"); legacy.removeValue(forKey: "searchURLTemplate")
        #expect(try SiteRule.decode(JSONSerialization.data(withJSONObject: legacy)).browse == nil)
        let legacySite = try SiteObject(rule: SiteRule.decode(JSONSerialization.data(withJSONObject: legacy)))
        #expect(legacySite.browseRefs.isEmpty && !legacySite.supportsSearch)
        #expect(try legacySite.search("title") == nil)
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

    @Test func siteReferencesNormalizeAndSearchRevalidatesTheActualQuery() async throws {
        var json = try JSONSerialization.jsonObject(with: DemoContent.bundledRules().first { $0.id == "demo" }!.exported()) as! [String: Any]
        json["browse"] = [["title": "One list", "url": "https://DEMO.mangaviewer.local:443/catalog#section"]]
        var matchers = json["matchers"] as! [[String: Any]]
        matchers.append(["kind": "chapter", "pattern": "^https://demo\\.mangaviewer\\.local/catalog\\?q=blocked$", "priority": 10])
        json["matchers"] = matchers
        let rule = try SiteRule.decode(JSONSerialization.data(withJSONObject: json))
        let site = try SiteObject(rule: rule)
        #expect(site.browseRefs.first?.key.identityURL == DemoContent.directoryURL)
        #expect(throws: ReaderError.self) { try site.search("blocked") }
        json["id"] = "other-rule"
        let other = try SiteRule.decode(JSONSerialization.data(withJSONObject: json))
        let repository = try ObjectRepository(store: ObjectStore(), rules: [rule, other])
        let reference = try #require(try site.search("title"))
        #expect(try await reference.load(using: repository).key.ruleID == site.id)

        // Pagination is another directory reference, normalized and checked by the same parser.
        json["extractors"] = (json["extractors"] as! [String: [String: Any]]).merging([
            "directory": ["format": "html", "fields": ["title": ["path": "//h1"], "mangaLinks": ["path": "//a[@class='manga']", "read": "attr:href"],
                "next": ["path": "//a[@rel='next']", "read": "attr:href"]]]
        ], uniquingKeysWith: { _, new in new })
        let pagingRule = try SiteRule.decode(JSONSerialization.data(withJSONObject: json))
        let key = try #require(try SiteObject(rule: pagingRule).browseRefs.first?.key)
        func parse(_ next: String) throws -> DirectoryObject {
            let html = "<h1>Source title</h1><a rel='next' href='\(next)'>Next</a>"
            let objects = try RuleExtractor().extract(data: Data(html.utf8), responseURL: key.identityURL, key: key, kind: .directory, rule: pagingRule)
            guard case .directory(let directory) = objects[0] else { throw ReaderError.invalidResponse }
            return directory
        }
        let directory = try parse("/catalog?page=2#items")
        #expect(directory.title == "One list")
        #expect(directory.nextPage?.key == ObjectKey(ruleID: pagingRule.id, identityURL: URL(string: "https://demo.mangaviewer.local/catalog?page=2")!))
        #expect(try parse("/chapter/arrival").nextPage == nil)
        #expect(throws: ReaderError.self) { try parse("https://outside.example/catalog") }
    }

    @Test func directorySortLinksLoadSourceOrderAndPreserveLegacySnapshots() async throws {
        let rule = try DemoContent.bundledRules().first { $0.id == "demo" }!
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

    @Test func ruleOrderSurvivesRestartAndRecipeReplacement() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try await ObjectRepository.open(directory: directory)
        let order = await repository.installedRules().map(\.id).reversed().map { $0 }
        try await repository.setRuleOrder(order)
        try await repository.setPreference("jumpToLastChapter", value: false)
        let reopened = try await ObjectRepository.open(directory: directory)
        #expect(await reopened.installedRules().map(\.id) == order)
        #expect(try await reopened.preference("jumpToLastChapter", as: Bool.self) == false)
        let top = try #require(await reopened.installedRules().first)
        var json = try JSONSerialization.jsonObject(with: top.exported()) as! [String: Any]
        json["version"] = top.version + 1
        try await reopened.install(SiteRule.decode(JSONSerialization.data(withJSONObject: json)))
        #expect(await reopened.installedRules().map(\.id) == order)
        await #expect(throws: ReaderError.self) { try await reopened.setRuleOrder([top.id, top.id]) }
        try await reopened.removeRule(top.id)
        try await reopened.install(top)
        #expect(await reopened.installedRules().map(\.id) == Array(order.dropFirst()) + [top.id])
        for id in ["z-import", "a-import"] {
            json["id"] = id
            try await reopened.install(SiteRule.decode(JSONSerialization.data(withJSONObject: json)))
        }
        let again = try await ObjectRepository.open(directory: directory)
        #expect(await again.installedRules().map(\.id) == reopened.installedRules().map(\.id))
        // Older releases left imported IDs out of this preference.
        try await again.setPreference("ruleOrder", value: order)
        let legacy = try await ObjectRepository.open(directory: directory)
        json["id"] = "next-import"
        try await legacy.install(SiteRule.decode(JSONSerialization.data(withJSONObject: json)))
        let updated = try await ObjectRepository.open(directory: directory)
        #expect(await updated.installedRules().map(\.id) == legacy.installedRules().map(\.id))
    }
}
