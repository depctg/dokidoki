import Foundation
import Testing
@testable import MangaCore

/// Per-test transport spy. Vary responses/delay as data; never share mutable fixture state.
actor TestFetcher: SourceFetcher {
    struct Request: Sendable {
        let url: URL
        let kind: ContentKind
        let backgroundLoading: Bool
    }
    private(set) var requests: [Request] = []
    private(set) var lookups = 0
    private(set) var cancellations = 0
    var count: Int { requests.count }
    var kinds: [ContentKind] { requests.map(\.kind) }
    var backgroundPolicies: [Bool] { requests.map(\.backgroundLoading) }
    let delay: Duration
    let response: @Sendable (URL) async throws -> SourceResponse
    let resource: (@Sendable (URL) throws -> SourceResponse?)?

    init(delay: Duration = .zero,
         resource: (@Sendable (URL) throws -> SourceResponse?)? = nil,
         response: @escaping @Sendable (URL) async throws -> SourceResponse = { try #require(try DemoContent.response(for: $0)) }) {
        self.delay = delay; self.response = response; self.resource = resource
    }
    func fetch(_ url: URL, rule: SiteRule, kind: ContentKind, backgroundLoading: Bool) async throws -> SourceResponse {
        requests.append(Request(url: url, kind: kind, backgroundLoading: backgroundLoading))
        try await pause()
        return try await response(url)
    }
    func cachedResource(_ url: URL, rule: SiteRule, owner: URL?, referer: URL?) async -> SourceResponse? {
        guard let resource else { return nil }
        lookups += 1
        do { try await pause(); return try resource(url) }
        catch { return nil }
    }
    private func pause() async throws {
        do { try await Task.sleep(for: delay) }
        catch { cancellations += 1; throw error }
    }
}
