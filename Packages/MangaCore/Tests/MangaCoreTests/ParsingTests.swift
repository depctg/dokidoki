import Foundation
import Testing
@testable import MangaCore

struct ParsingTests {
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
        var json = try JSONSerialization.jsonObject(with: DemoContent.bundledRules()[0].exported()) as! [String: Any]
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
