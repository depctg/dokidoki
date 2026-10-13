import Foundation
import Testing
@testable import MangaCore

struct PagePreparationTests {
    private func context() throws -> (PageObject, ObjectRepository, RequestSender, TestFetcher) {
        let rule = try #require(DemoContent.bundledRules().first { $0.id == "demo" })
        let owner = ObjectKey(ruleID: rule.id, identityURL: DemoContent.directoryURL)
        // Each test uses an uncached resource identity, without clearing other tests' caches.
        let url = URL(string: "https://demo.mangaviewer.local/images/1.png?preparation=\(UUID())")!
        let page = PageObject(key: .page(owner: owner, index: 0), ownerRef: owner, sourceIndex: 0, imageURL: url, refererURL: owner.identityURL)
        let fetcher = TestFetcher(delay: .milliseconds(180), resource: { try DemoContent.response(for: $0) },
                                  response: { _ in throw ReaderError.invalidResponse }), sender = RequestSender(fetcher: fetcher)
        return (page, try ObjectRepository(store: ObjectStore(), rules: [rule], sender: sender), sender, fetcher)
    }

    @Test func preparedImageSurvivesThePrefetchCallerAndSession() async throws {
        let (page, repository, sender, fetcher) = try context()
        let analysis = try await page.prepare(using: repository)
        await sender.invalidateResources()
        let displayed = try await page.image(using: repository)
        #expect(displayed.width == analysis.width && displayed.height == analysis.height)
        #expect(await fetcher.lookups == 1)
    }

    @Test func visibleImageKeepsSharedWorkWhenPrefetchIsCancelled() async throws {
        let (page, repository, _, fetcher) = try context()
        let prefetch = Task { try await page.prepare(using: repository) }
        for _ in 0..<200 where await fetcher.lookups == 0 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await fetcher.lookups == 1)
        let visible = Task { try await page.image(using: repository) }
        // The resource remains pending while both independent consumers attach.
        try await Task.sleep(for: .milliseconds(30))
        prefetch.cancel()
        await #expect(throws: CancellationError.self) { try await prefetch.value }
        #expect(try await visible.value.height > 0)
        #expect(await fetcher.lookups == 1)
        #expect(await fetcher.cancellations == 0)
    }
}
