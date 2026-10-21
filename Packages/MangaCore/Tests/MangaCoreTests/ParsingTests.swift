import Foundation
import Testing
@testable import MangaCore

struct ParsingTests {
    @Test func renderedReadinessAndResourceOptionsRemainDataOnly() throws {
        var json = try JSONSerialization.jsonObject(with: DemoContent.bundledRules().first { $0.id == "demo" }!.exported()) as! [String: Any]
        var extractors = json["extractors"] as! [String: [String: Any]]
        extractors["directory"]!["format"] = "renderedHTML"
        extractors["directory"]!["rendering"] = ["readyXPath": "//main[@data-ready='true']", "loadAds": false]
        json["extractors"] = extractors
        let rule = try SiteRule.decode(JSONSerialization.data(withJSONObject: json))
        #expect(rule.extractors["directory"]?.rendering?.loadAds == false)
        #expect(rule.extractors["manga"]?.rendering?.loadAds == nil)
        #expect(try SiteRule.decode(rule.exported()).exported() == rule.exported())
        for rendering: [String: Any] in [["readyXPath": "//["], ["loadAds": "yes"], ["readyXPath": "//main", "script": "load()"]] {
            extractors["directory"]!["rendering"] = rendering; json["extractors"] = extractors
            #expect(throws: (any Error).self) { try SiteRule.decode(JSONSerialization.data(withJSONObject: json)) }
        }
    }

    @Test func secondLiveRecipeParsesPartialDOMWithoutSiteCode() throws {
        let rule = try #require(DemoContent.bundledRules().first { $0.id == "mangacopy" })
        let mangaKey = ObjectKey(ruleID: rule.id, identityURL: URL(string: "https://www.mangacopy.com/comic/example")!)
        // Original synthetic markup matching the observed DOM shape; no downloaded artwork/content.
        let html = """
        <h6 title="Example">Example</h6><div class="comicParticulars-left-img"><img data-src="https://sy.mangafunb.fun/cover.png"></div>
        <li><span>狀態</span><span class="comicParticulars-right-txt">連載中</span></li>
        <span class="comicParticulars-tag"><a>#Adventure</a></span>
        <div class="upLoop"><a href="/comic/example/chapter/2">Latest shortcut</a>
        <span>Default</span><div class="table-default"><div class="tab-content"><div role="tabpanel" id="default話"><ul><a href="/comic/example/chapter/1">One</a><a href="/comic/example/chapter/2">Two</a></ul></div></div></div></div>
        """
        let objects = try RuleExtractor().extract(data: Data(html.utf8), responseURL: mangaKey.identityURL, key: mangaKey, kind: .manga, rule: rule)
        guard case .manga(let manga) = objects[0] else { Issue.record("Missing manga"); return }
        #expect(manga.chapterRefs.map(\.title) == ["One", "Two"])
        #expect(manga.status == "連載中"); #expect(manga.tags == ["Adventure"])
        let chapterKey = manga.chapterRefs[0].key
        let snapshot = "<title>Example - One - Site</title><span class='comicCount'>2</span><div class='comicContent-prev list'><a href='/comic/example'>Series</a></div><ul class='comicContent-list'><li><img data-src='https://sy.mangafunb.fun/1.png'></li><li><img data-src='https://sy.mangafunb.fun/2.webp'></li></ul>"
        let result = try RuleExtractor().extract(data: Data(snapshot.utf8), responseURL: chapterKey.identityURL, key: chapterKey, kind: .chapter, rule: rule)
        guard case .chapter(let chapter) = result[0], case .page(let first) = result[1] else { Issue.record("Missing chapter"); return }
        #expect(chapter.title == "One"); #expect(chapter.mangaRef == manga.key); #expect(chapter.pageRefs.count == 2)
        #expect(first.imageURL?.absoluteString == "https://sy.mangafunb.fun/1.png")
        #expect(rule.extractors["chapter"]?.format == .renderedHTML)
        #expect(rule.extractors["chapter"]?.session?.mode == .scroll)
        for container in ["class='exemptComic-box'", "id='comic'"] {
            let listKey = ObjectKey(ruleID: rule.id, identityURL: URL(string: "https://www.mangacopy.com/comics")!)
            let listHTML = "<title>List</title><div \(container)><div class='col-auto exemptComic_Item'><a href='/comic/example'><img src='/cover'></a><a href='/comic/example'><p title='Readable title'>Readable title</p></a></div></div>"
            let list = try RuleExtractor().extract(data: Data(listHTML.utf8), responseURL: listKey.identityURL, key: listKey, kind: .directory, rule: rule)
            guard case .directory(let directory) = list[0] else { Issue.record("Missing directory"); return }
            #expect(directory.mangaRefs.map(\.title) == ["Readable title"])
        }
    }
    @Test func directoryRecipeSeedsCoversWithoutDetailRequests() async throws {
        let rule = try #require(DemoContent.bundledRules().first { $0.id == "manhuagui" })
        let url = URL(string: "https://www.manhuagui.com/list/")!
        // Original synthetic catalog/update/search shapes; never downloaded source content.
        let html = """
        <title>List</title><ul>
        <li><a class="bcover" href="/comic/123/" title="First"><img src="//cf.mhgui.com/first.png"></a>
        <a href="/comic/123/">Duplicate title</a><span class="updateon">Today<em>8.5</em></span></li>
        <li><a class="cover" href="/comic/124/" title="Second"><img data-src="//cf.mhgui.com/second.png" src="/placeholder"></a>
        <span class="dt"><em>2026-10-21</em></span></li>
        <li><div class="book-cover"><a class="bcover" href="/book/125/" title="Third"><img src="//cf.mhgui.com/third.png"></a></div>
        <div class="book-detail"><dd class="tags status"><span><strong>状态：</strong><span>连载中</span><span>2026</span></span></dd>
        <span><strong>类型：</strong><a>Adventure</a></span><span><strong>作者：</strong><a>Author</a></span>
        <a href="/comic/123/456.html">Read</a></div><p class="score-avg"><strong>9.1</strong></p></li></ul>
        """
        let fetcher = TestFetcher(response: { requested in
            #expect(requested == url)
            return SourceResponse(data: Data(html.utf8), url: requested)
        })
        let repository = try ObjectRepository(store: ObjectStore(), rules: [rule], sender: RequestSender(fetcher: fetcher))
        let key = ObjectKey(ruleID: rule.id, identityURL: url)
        guard case .directory(let directory) = try await key.load(using: repository) else { throw ReaderError.invalidResponse }
        #expect(directory.mangaRefs.map(\.title) == ["First", "Second", "Third"])
        var previews: [MangaObject] = []
        for reference in directory.mangaRefs {
            guard case .manga(let manga) = try await reference.preview(using: repository) else { throw ReaderError.invalidResponse }
            #expect(manga.chapters == nil)
            let cover = try #require(try await manga.coverPage(using: repository))
            #expect(cover.imageURL?.host == "cf.mhgui.com")
            #expect(cover.ownerRef == manga.key && cover.sessionURL == url && cover.refererURL == url)
            previews.append(manga)
        }
        #expect(previews.map(\.rating) == ["8.5", nil, "9.1"])
        #expect(previews.last?.status == "连载中" && previews.last?.tags == ["Adventure"])
        #expect(await fetcher.kinds == [.directory])
        let empty = try RuleExtractor().extract(data: Data("<title>No results</title>".utf8), responseURL: url, key: key, kind: .directory, rule: rule)
        guard case .directory(let result) = empty.first else { throw ReaderError.invalidResponse }
        #expect(result.mangaRefs.isEmpty && result.hasMore == false)
    }

    @Test func chapterReadingOrderComesFromJSONRules() throws {
        let rule = try DemoContent.bundledRules().first { $0.id == "manhuagui" }!
        let key = ObjectKey(ruleID: rule.id, identityURL: URL(string: "https://www.manhuagui.com/comic/123/")!)
        let html = "<h1>Series</h1><div class='chapter-list'><a href='/comic/123/2.html'>Second</a><a href='/comic/123/1.html'>First</a></div>"
        let objects = try RuleExtractor().extract(data: Data(html.utf8), responseURL: key.identityURL, key: key, kind: .manga, rule: rule)
        guard case .manga(let manga) = objects[0] else { Issue.record("Missing manga"); return }
        #expect(manga.chapterRefs.map(\.title) == ["First", "Second"])
        #expect(manga.chapterRefs.map { $0.key.identityURL.lastPathComponent } == ["1.html", "2.html"])

        // The same data-only option works on JSON lists; omission keeps source order.
        for reverse in [false, true] {
            var json = try JSONSerialization.jsonObject(with: rule.exported()) as! [String: Any]
            var extractors = json["extractors"] as! [String: Any]
            var links: [String: Any] = ["path": "chapters.*"]
            if reverse { links["reverse"] = true }
            extractors["manga"] = ["format": "json", "fields": ["title": ["path": "title"], "chapterLinks": links]]
            json["extractors"] = extractors
            let changed = try SiteRule.decode(JSONSerialization.data(withJSONObject: json))
            let input = Data(#"{"title":"Series","chapters":[{"url":"/comic/123/2.html","title":"Second"},{"url":"/comic/123/1.html","title":"First"}]}"#.utf8)
            let result = try RuleExtractor().extract(data: input, responseURL: key.identityURL, key: key, kind: .manga, rule: changed)
            guard case .manga(let manga) = result[0] else { Issue.record("Missing manga"); return }
            #expect(manga.chapterRefs.map(\.title) == (reverse ? ["First", "Second"] : ["Second", "First"]))
        }
    }
    @Test func renderedJSONUsesRuleVariablesTemplatesAndQueries() throws {
        let rule = try DemoContent.bundledRules().first { $0.id == "manhuagui" }!
        let key = ObjectKey(ruleID: rule.id, identityURL: URL(string: "https://www.manhuagui.com/comic/123/456.html")!)
        let input: [String: Any] = ["data": ["cname": "第2话", "bid": 123, "path": "/chapter/", "files": ["first.jpg", "second.png.webp"], "sl": ["e": 12345, "m": "a&b=c"]], "imageURL": "https://i.hamreus.com/chapter/first.jpg?e=12345"]
        let objects = try RuleExtractor().extract(data: JSONSerialization.data(withJSONObject: input), responseURL: key.identityURL, key: key, kind: .chapter, rule: rule)
        guard case .chapter(let chapter) = objects[0], case .page(let first) = objects[1], case .page(let second) = objects[2] else { Issue.record("Missing graph"); return }
        #expect(chapter.title == "第2话")
        #expect(chapter.mangaRef?.identityURL.absoluteString == "https://www.manhuagui.com/comic/123/")
        #expect(first.imageURL?.path == "/chapter/first.jpg")
        #expect(second.imageURL?.path == "/chapter/second.png.webp")
        #expect(URLComponents(url: first.imageURL!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "m" }?.value == "a&b=c")
        var blocked = input; blocked["imageURL"] = "https://undeclared.example/chapter/first.jpg"
        #expect(throws: ReaderError.self) { try RuleExtractor().extract(data: JSONSerialization.data(withJSONObject: blocked), responseURL: key.identityURL, key: key, kind: .chapter, rule: rule) }
    }
    @Test func xpathRegexAndNamedVariableComposeWithoutSiteCode() throws {
        var json = try JSONSerialization.jsonObject(with: DemoContent.bundledRules().first { $0.id == "demo" }!.exported()) as! [String: Any]
        var extractors = json["extractors"] as! [String: Any]
        extractors["chapter"] = ["format": "html", "variables": ["base": ["path": "//script[@id='metadata']", "regex": "base='([^']+)'", "group": 1]], "fields": ["title": ["path": "//h2", "regex": "Chapter ([0-9]+)", "group": 0], "pageImages": ["path": "//img", "read": "attr:data-page", "regex": "file:(.+)", "urlTemplate": "{vars.base}{value}"]]]
        json["extractors"] = extractors
        let rule = try SiteRule.decode(JSONSerialization.data(withJSONObject: json))
        let key = ObjectKey(ruleID: rule.id, identityURL: URL(string: "https://demo.mangaviewer.local/chapter/arrival")!)
        let html = "<h2>Example — Chapter 12 — site</h2><script id='metadata'>base='https://demo.mangaviewer.local/images/'</script><img data-page='file:1.png'><img data-page='no-match'>"
        let objects = try RuleExtractor().extract(data: Data(html.utf8), responseURL: key.identityURL, key: key, kind: .chapter, rule: rule)
        guard case .chapter(let chapter) = objects[0], case .page(let page) = objects[1] else { Issue.record("Missing graph"); return }
        #expect(chapter.title == "Chapter 12")
        #expect(chapter.pageRefs.count == 1)
        #expect(page.imageURL?.absoluteString == "https://demo.mangaviewer.local/images/1.png")
    }
    @Test func invalidParsingInstructionsAreRejected() throws {
        let base = try JSONSerialization.jsonObject(with: DemoContent.bundledRules().first { $0.id == "manhuagui" }!.exported()) as! [String: Any]
        for rendering in [
            ["captureFunction": "SMH.imgData();evil()", "readyImageXPath": "//img"],
            ["captureFunction": "SMH.__proto__.imgData", "readyImageXPath": "//img"],
            ["captureFunction": "SMH.imgData", "readyImageXPath": "//img", "script": "alert(1)"]
        ] {
            var json = base; var extractors = json["extractors"] as! [String: [String: Any]]
            extractors["chapter"]!["rendering"] = rendering; json["extractors"] = extractors
            #expect(throws: ReaderError.self) { try SiteRule.decode(JSONSerialization.data(withJSONObject: json)) }
        }
        for field: [String: Any] in [["path": "data.cname", "regex": "("], ["path": "data.cname", "regex": "(.*)", "group": 2]] {
            var json = base; var extractors = json["extractors"] as! [String: [String: Any]]
            var fields = extractors["chapter"]!["fields"] as! [String: Any]; fields["title"] = field
            extractors["chapter"]!["fields"] = fields; json["extractors"] = extractors
            #expect(throws: ReaderError.self) { try SiteRule.decode(JSONSerialization.data(withJSONObject: json)) }
        }
    }
}
