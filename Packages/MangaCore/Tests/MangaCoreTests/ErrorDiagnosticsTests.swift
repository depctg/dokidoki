import Foundation
import OSLog
import Testing
@testable import MangaCore

struct ErrorDiagnosticsTests {
    @Test func reportsOnlySafeContextAndSuppressesCancellation() throws {
        let url = try #require(URL(string: "https://username:password@reader.example/private-title?token=secret#fragment"))
        let message = try #require(ErrorDiagnostics.message(ReaderError.httpStatus(503), operation: .loadImage, url: url))
        #expect(message == "loadImage: HTTP 503 [reader.example]")
        let sensitive = "https://private.example/title?token=secret /Users/private/library.json"
        for error: any Error in [ReaderError.extraction(sensitive), ReaderError.invalidRule(sensitive),
                                NSError(domain: sensitive, code: 7, userInfo: [NSLocalizedDescriptionKey: sensitive])] {
            let result = try #require(ErrorDiagnostics.message(error, operation: .loadContent, url: url))
            #expect(!result.contains("private"))
            #expect(!result.contains("secret"))
            #expect(!result.contains("username"))
            #expect(!result.contains("password"))
        }
        for error: any Error in [CancellationError(), URLError(.cancelled), CocoaError(.userCancelled)] {
            #expect(ErrorDiagnostics.message(error, operation: .loadImage) == nil)
        }
    }

    @Test func nativeCollectionCapturesFailedObjectAndImageLoadsOnly() async throws {
        let host = "diagnostics-\(UUID().uuidString.lowercased()).invalid"
        let url = try #require(URL(string: "https://\(host)/private-title?token=secret"))
        let repository = try ObjectRepository(store: ObjectStore(), rules: DemoContent.bundledRules())
        let key = ObjectKey(ruleID: "missing", identityURL: url)
        await #expect(throws: ReaderError.self) { try await key.load(using: repository) }
        let page = PageObject(key: .page(owner: key, index: 0), ownerRef: key, sourceIndex: 0, imageURL: url, refererURL: nil)
        await #expect(throws: ReaderError.self) { try await page.image(using: repository) }
        ErrorDiagnostics.record(URLError(.cancelled), operation: .loadImage, url: url)
        let logger = Logger(subsystem: ErrorDiagnostics.subsystem, category: ErrorDiagnostics.category)
        logger.notice("\(host, privacy: .public) success must not appear")
        // Unified logging ingestion is asynchronous. Exercise the real native reader, not a mock.
        var messages: [String] = []
        for _ in 0..<20 {
            messages = try await ErrorDiagnostics.entries().map(\.message).filter { $0.contains(host) }
            if messages.count >= 2 { break }
            try await Task.sleep(for: .milliseconds(250))
        }
        #expect(messages.sorted() == ["loadContent: missing_rule [\(host)]", "loadImage: missing_rule [\(host)]"])
    }
}
