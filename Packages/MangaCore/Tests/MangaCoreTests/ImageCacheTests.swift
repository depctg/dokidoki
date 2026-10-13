import Foundation
import CryptoKit
import Testing
@testable import MangaCore

struct ImageCacheTests {
    @Test func diskSurvivesRelaunchAndRecipeRevisionWithExplicitInvalidation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundled = try #require(DemoContent.bundledRules().first { $0.id == "demo" })
        var json = try JSONSerialization.jsonObject(with: bundled.exported()) as! [String: Any]
        json["allowedHosts"] = bundled.allowedHosts + ["cdn.example"]
        let rule = try SiteRule.decode(JSONSerialization.data(withJSONObject: json))
        let owner = ObjectKey(ruleID: rule.id, identityURL: DemoContent.directoryURL)
        let url = URL(string: "https://demo.mangaviewer.local/images/1.png")!
        let page = PageObject(key: .page(owner: owner, index: 0), ownerRef: owner, role: .cover,
            sourceIndex: nil, imageURL: url, refererURL: owner.identityURL)
        let fetcher = CacheProbe()
        // Upgrade an existing version-keyed cache without touching the sender.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let identity = "\(rule.id)|\(rule.version)|\(url.absoluteString)|\(owner.identityURL.absoluteString)"
        let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        let legacy = directory.appendingPathComponent("cover-\(digest).cache")
        try DemoContent.resource("1", extension: "png").write(to: legacy)
        let first = ImageLoader(sender: RequestSender(fetcher: fetcher), directory: directory)
        _ = try await first.image(for: page, rule: rule)
        #expect(await fetcher.lookups == 0)
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        await first.clear()
        _ = try await first.image(for: page, rule: rule)
        #expect(await fetcher.lookups == 1)

        json["version"] = rule.version + 1
        let revised = try SiteRule.decode(JSONSerialization.data(withJSONObject: json))
        // New loader and sender have no in-memory images or session resources.
        let reopened = ImageLoader(sender: RequestSender(fetcher: fetcher), directory: directory)
        _ = try await reopened.image(for: page, rule: revised)
        #expect(await fetcher.lookups == 1)
        _ = try await reopened.image(for: page, rule: revised, refresh: true)
        #expect(await fetcher.lookups == 2)
        let otherReferer = PageObject(key: page.key, ownerRef: owner, role: .cover, sourceIndex: nil,
            imageURL: url, refererURL: url)
        _ = try await reopened.image(for: otherReferer, rule: revised)
        #expect(await fetcher.lookups == 3)
        // The origin is still allowed, but a previous redirect destination is not.
        // Old bytes cannot bypass the changed redirect-host policy.
        json["allowedHosts"] = bundled.allowedHosts
        let restricted = try SiteRule.decode(JSONSerialization.data(withJSONObject: json))
        _ = try await reopened.image(for: page, rule: restricted)
        #expect(await fetcher.lookups == 4)
        json["allowedHosts"] = ["elsewhere.example"]
        json.removeValue(forKey: "browse"); json.removeValue(forKey: "searchURLTemplate")
        let blocked = try SiteRule.decode(JSONSerialization.data(withJSONObject: json))
        await #expect(throws: ReaderError.self) { try await reopened.image(for: page, rule: blocked) }
        #expect(await fetcher.lookups == 4)
        await reopened.clear()
        #expect(await reopened.diskUsage() == 0)
    }
}

private actor CacheProbe: SourceFetcher {
    var lookups = 0
    func cachedResource(_ url: URL, rule: SiteRule, owner: URL?, referer: URL?) async -> SourceResponse? {
        lookups += 1
        return try? DemoContent.response(for: url)
    }
    func fetch(_ url: URL, rule: SiteRule, kind: ContentKind, backgroundLoading: Bool) async throws -> SourceResponse {
        throw ReaderError.cacheMiss
    }
}
