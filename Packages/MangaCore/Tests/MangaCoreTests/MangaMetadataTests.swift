import Foundation
import Testing
@testable import MangaCore

struct MangaMetadataTests {
    @Test func htmlMetadataUsesRulesAndPreservesSourceText() throws {
        let rule = try #require(DemoContent.bundledRules().first { $0.id == "manhuagui" })
        let key = ObjectKey(ruleID: rule.id, identityURL: URL(string: "https://www.manhuagui.com/comic/123/")!)
        for (status, rating) in [("连载中", "8.6"), ("已完结", "-")] {
            let html = """
            <h1>Series</h1><a href='/list/other/'>Unrelated navigation</a>
            <ul class='detail-list cf'>
              <li><span><strong>漫画剧情：</strong><a> 冒险 </a><a>科幻</a><a>冒险</a></span><span><strong>漫画作者：</strong><a>Author</a></span></li>
              <li class='status'><span><strong>漫画状态：</strong><span class='red'>\(status)</span> Recently <span class='red'>2026-10-13</span></span></li>
            </ul>
            <div id='scoreRes'><p class='score-avg'><em>\(rating)</em></p></div>
            """
            let objects = try RuleExtractor().extract(data: Data(html.utf8), responseURL: key.identityURL, key: key, kind: .manga, rule: rule)
            guard case .manga(let manga) = objects[0] else { Issue.record("Missing manga"); return }
            #expect(manga.rating == (rating == "-" ? nil : rating))
            #expect(manga.status == status)
            #expect(manga.tags == ["冒险", "科幻"])

            // A rule which omits metadata fields must not infer it from the same document.
            var json = try JSONSerialization.jsonObject(with: rule.exported()) as! [String: Any]
            var extractors = json["extractors"] as! [String: [String: Any]]
            var fields = extractors["manga"]!["fields"] as! [String: Any]
            for name in ["rating", "status", "tags"] { fields.removeValue(forKey: name) }
            extractors["manga"]!["fields"] = fields; json["extractors"] = extractors
            let legacyRule = try SiteRule.decode(JSONSerialization.data(withJSONObject: json))
            let legacyObjects = try RuleExtractor().extract(data: Data(html.utf8), responseURL: key.identityURL, key: key, kind: .manga, rule: legacyRule)
            guard case .manga(let legacy) = legacyObjects[0] else { Issue.record("Missing manga"); return }
            #expect(legacy.rating == nil && legacy.status == nil && legacy.tags == nil)
        }
    }

    @Test func jsonMetadataAndOlderSnapshotsRemainCompatible() throws {
        let base = try DemoContent.bundledRules().first { $0.id == "demo" }!
        var json = try JSONSerialization.jsonObject(with: base.exported()) as! [String: Any]
        var extractors = json["extractors"] as! [String: Any]
        extractors["manga"] = ["format": "json", "fields": ["title": ["path": "title"], "chapterLinks": ["path": "chapters.*"], "rating": ["path": "rating"], "status": ["path": "status"], "tags": ["path": "tags.*"]]]
        json["extractors"] = extractors
        let rule = try SiteRule.decode(JSONSerialization.data(withJSONObject: json))
        let key = ObjectKey(ruleID: rule.id, identityURL: URL(string: "https://demo.mangaviewer.local/series/metadata")!)
        for input in [#"{"title":"Series","rating":4.5,"status":" Ongoing ","tags":[" Adventure ","","Adventure","Sci-fi"]}"#,
                      #"{"title":"Series","rating":null,"status":"  ","tags":[" "]}"#] {
            let objects = try RuleExtractor().extract(data: Data(input.utf8), responseURL: key.identityURL, key: key, kind: .manga, rule: rule)
            guard case .manga(let manga) = objects[0] else { Issue.record("Missing manga"); return }
            if input.contains("4.5") {
                #expect(manga.rating == "4.5" && manga.status == "Ongoing" && manga.tags == ["Adventure", "Sci-fi"])
            } else { #expect(manga.rating == nil && manga.status == nil && manga.tags == nil) }
            let decoded = try JSONDecoder().decode(MangaObject.self, from: JSONEncoder().encode(manga))
            #expect(decoded.rating == manga.rating && decoded.status == manga.status && decoded.tags == manga.tags)

            var oldSnapshot = try JSONSerialization.jsonObject(with: JSONEncoder().encode(manga)) as! [String: Any]
            for name in ["rating", "status", "tags"] { oldSnapshot.removeValue(forKey: name) }
            let legacy = try JSONDecoder().decode(MangaObject.self, from: JSONSerialization.data(withJSONObject: oldSnapshot))
            #expect(legacy.title == "Series" && legacy.rating == nil && legacy.status == nil && legacy.tags == nil)
        }
    }
}
