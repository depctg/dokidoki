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

    @Test func secondLiveRecipeParsesDOMAndObservedResultWithoutSiteCode() throws {
        let rule = try #require(DemoContent.bundledRules().first { $0.id == "mangacopy" })
        let mangaKey = ObjectKey(ruleID: rule.id, identityURL: URL(string: "https://www.mangacopy.com/comic/example")!)
        // Original synthetic markup matching the observed DOM shape; no downloaded artwork/content.
        let html = """
        <h6 title="Example">Example</h6><div class="comicParticulars-left-img"><img data-src="https://sy.mangafunb.fun/cover.png"></div>
        <li><span>狀態</span><span class="comicParticulars-right-txt">連載中</span></li>
        <span class="comicParticulars-tag"><a>#Adventure</a></span>
        <div class="upLoop"><a href="/comic/example/chapter/2">Latest shortcut</a>
        <div class="tab-content"><ul><a href="/comic/example/chapter/1">One</a><a href="/comic/example/chapter/2">Two</a></ul></div></div>
        """
        let objects = try RuleExtractor().extract(data: Data(html.utf8), responseURL: mangaKey.identityURL, key: mangaKey, kind: .manga, rule: rule)
        guard case .manga(let manga) = objects[0] else { Issue.record("Missing manga"); return }
        #expect(manga.chapterRefs.map(\.title) == ["One", "Two"])
        #expect(manga.status == "連載中"); #expect(manga.tags == ["Adventure"])
        let chapterKey = manga.chapterRefs[0].key
        let snapshot: [String: Any] = ["title": "Example - One - Site", "url": chapterKey.identityURL.absoluteString,
            "imageURL": "https://s3.mangafunb.fun/loading.png", "data": [["url": "https://sy.mangafunb.fun/1.png"], ["url": "https://sy.mangafunb.fun/2.webp"]]]
        let result = try RuleExtractor().extract(data: JSONSerialization.data(withJSONObject: snapshot), responseURL: chapterKey.identityURL, key: chapterKey, kind: .chapter, rule: rule)
        guard case .chapter(let chapter) = result[0], case .page(let first) = result[1] else { Issue.record("Missing chapter"); return }
        #expect(chapter.title == "One"); #expect(chapter.mangaRef == manga.key); #expect(chapter.pageRefs.count == 2)
        #expect(first.imageURL.absoluteString == "https://sy.mangafunb.fun/1.png")
        #expect(rule.extractors["chapter"]?.rendering?.captureResult == true)
        for container in ["class='exemptComic-box'", "id='comic'"] {
            let listKey = ObjectKey(ruleID: rule.id, identityURL: URL(string: "https://www.mangacopy.com/comics")!)
            let listHTML = "<title>List</title><div \(container)><a href='/comic/example'><img src='/cover'></a><a href='/comic/example'><p>Readable title</p></a></div>"
            let list = try RuleExtractor().extract(data: Data(listHTML.utf8), responseURL: listKey.identityURL, key: listKey, kind: .directory, rule: rule)
            guard case .directory(let directory) = list[0] else { Issue.record("Missing directory"); return }
            #expect(directory.mangaRefs.map(\.title) == ["Readable title"])
        }
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
        #expect(first.imageURL.path == "/chapter/first.jpg")
        #expect(second.imageURL.path == "/chapter/second.png.webp")
        #expect(URLComponents(url: first.imageURL, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "m" }?.value == "a&b=c")
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
        #expect(page.imageURL.absoluteString == "https://demo.mangaviewer.local/images/1.png")
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
