import Foundation
import Testing
import os
@testable import MangaCore

@Suite(.serialized) struct RequestSenderTests {
    private func rule(rendered: Bool = false) throws -> SiteRule {
        var json = try JSONSerialization.jsonObject(with: DemoContent.bundledRules().first { $0.id == "demo" }!.exported()) as! [String: Any]
        json["allowedHosts"] = ["a.sender.test", "b.sender.test", "c.sender.test"]
        json.removeValue(forKey: "browse"); json.removeValue(forKey: "searchURLTemplate")
        if rendered {
            var extractors = json["extractors"] as! [String: [String: Any]]
            extractors["directory"]?["format"] = "renderedHTML"
            json["extractors"] = extractors
        }
        return try SiteRule.decode(JSONSerialization.data(withJSONObject: json))
    }
    private func source(_ path: String, rule: SiteRule, host: String = "a.sender.test") -> ContentRequest {
        .source(ObjectKey(ruleID: rule.id, identityURL: URL(string: "https://\(host)/\(path)")!), kind: .directory, rule: rule)
    }
    private func sender(maxConcurrent: Int = 4, burst: Int = 8, hostBurst: Int = 4, window: Duration = .seconds(1)) -> RequestSender {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SenderFixture.self]
        let client = HTTPClient(configuration: config)
        return RequestSender(fetcher: FixtureFetcher(client: client), client: client, maxConcurrent: maxConcurrent,
                             burst: burst, hostBurst: hostBurst, burstWindow: window)
    }
    private func waitForStarts(_ count: Int) async throws {
        for _ in 0..<400 {
            if SenderFixture.state.withLock({ $0.paths.count >= count }) { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw ReaderError.extraction("Fixture requests did not start")
    }

    @Test func documentsImagesAndRenderedSessionsShareCapacity() async throws {
        SenderFixture.reset()
        let sender = sender(), plain = try rule(), rendered = try self.rule(rendered: true)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for host in plain.allowedHosts {
                for index in 0..<6 {
                    let request: ContentRequest
                    if index.isMultiple(of: 3) {
                        let owner = ObjectKey(ruleID: plain.id, identityURL: URL(string: "https://\(host)/owner")!)
                        let page = PageObject(key: .page(owner: owner, index: index), ownerRef: owner, sourceIndex: index,
                            imageURL: URL(string: "https://\(host)/image/\(index)")!, refererURL: owner.identityURL)
                        request = .image(page, rule: plain)
                    } else { request = source("\(index.isMultiple(of: 2) ? "rendered" : "document")/\(index)", rule: index.isMultiple(of: 2) ? rendered : plain, host: index == 1 ? host.uppercased() : host) }
                    group.addTask { _ = try await sender.send(request) }
                }
            }
            try await group.waitForAll()
        }
        let stats = SenderFixture.state.withLock { $0 }
        #expect(stats.paths.count == 18)
        #expect(stats.peak == 4)
        #expect(stats.hostPeaks.values.allSatisfy { $0 == 2 })
        #expect(stats.renderedPeak == 1)
        #expect(stats.active == 0)
    }

    @Test func sharedConsumersReceiveResultAndCancelIndependently() async throws {
        SenderFixture.reset()
        let sender = sender(), rule = try rule()
        let request = source("shared", rule: rule)
        let first = Task { try await sender.send(request) }
        let second = Task { try await sender.send(request) }
        try await waitForStarts(1)
        // Both callers are queued before cancellation; the transport stays pending for 150 ms.
        try await Task.sleep(for: .milliseconds(30))
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(try await second.value.data == Data("okay".utf8))
        #expect(SenderFixture.state.withLock { $0.paths } == ["/shared"])
        #expect(SenderFixture.state.withLock { $0.cancellations } == 0)
    }

    @Test func abandonedQueueAndTransportReleaseCapacityForRetry() async throws {
        SenderFixture.reset()
        let sender = sender(maxConcurrent: 1), rule = try rule()
        let request = source("retry", rule: rule)
        let active = Task { try await sender.send(request) }
        try await waitForStarts(1)
        let queued = Task { try await sender.send(source("abandoned", rule: rule)) }
        try await Task.sleep(for: .milliseconds(30))
        queued.cancel()
        await #expect(throws: CancellationError.self) { try await queued.value }
        active.cancel()
        await #expect(throws: CancellationError.self) { try await active.value }
        #expect(try await sender.send(request).data == Data("okay".utf8))
        #expect(SenderFixture.state.withLock { $0.paths } == ["/retry", "/retry"])
        #expect(SenderFixture.state.withLock { $0.cancellations } == 1)
        #expect(SenderFixture.state.withLock { $0.peak } == 1)
        await #expect(throws: ReaderError.self) { try await sender.send(source("fail", rule: rule)) }
        #expect(try await sender.send(source("after-error", rule: rule)).data == Data("okay".utf8))
    }

    @Test func requestIdentityIncludesRuleAndRefererAndBlocksUnknownHosts() async throws {
        SenderFixture.reset()
        let sender = sender(), rule = try rule(), rendered = try self.rule(rendered: true)
        // Same rule ID/version/URL, different extraction policy: they must remain separate.
        async let plainResult = sender.send(source("policy", rule: rule))
        async let renderedResult = sender.send(source("policy", rule: rendered))
        _ = try await (plainResult, renderedResult)
        let owner = ObjectKey(ruleID: rule.id, identityURL: URL(string: "https://a.sender.test/owner")!)
        func image(_ referer: URL) -> ContentRequest {
            .image(PageObject(key: .page(owner: owner, index: 0), ownerRef: owner, sourceIndex: 0,
                imageURL: URL(string: "https://a.sender.test/referer")!, refererURL: referer), rule: rule)
        }
        async let first = sender.send(image(owner.identityURL))
        async let duplicate = sender.send(image(owner.identityURL))
        async let second = sender.send(image(owner.identityURL.appendingPathComponent("other")))
        let results = try await (first, second, duplicate)
        #expect(results.0.data == Data(owner.identityURL.absoluteString.utf8))
        #expect(results.0.data == results.2.data)
        #expect(results.1.data == Data(owner.identityURL.appendingPathComponent("other").absoluteString.utf8))
        #expect(SenderFixture.state.withLock { $0.paths.count } == 4)
        async let enabled = sender.send(source("background", rule: rule))
        async let disabled = sender.send(.source(ObjectKey(ruleID: rule.id, identityURL: URL(string: "https://a.sender.test/background")!), kind: .directory, rule: rule, backgroundLoading: false))
        _ = try await (enabled, disabled)
        #expect(SenderFixture.state.withLock { $0.paths.filter { $0 == "/background" }.count } == 2)
        await #expect(throws: ReaderError.self) { try await sender.send(source("blocked", rule: rule, host: "unknown.test")) }
        #expect(SenderFixture.state.withLock { $0.paths.count } == 6)
    }

    @Test func burstBudgetIsSharedByDocumentsImagesAndRenderedSessions() async throws {
        SenderFixture.reset()
        let sender = sender(burst: 3, hostBurst: 2, window: .milliseconds(400))
        let plain = try rule(), rendered = try rule(rendered: true)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for host in plain.allowedHosts {
                for index in 0..<4 {
                    let owner = ObjectKey(ruleID: plain.id, identityURL: URL(string: "https://\(host)/owner")!)
                    let request: ContentRequest = index == 0
                        ? .image(PageObject(key: .page(owner: owner, index: 0), ownerRef: owner, sourceIndex: 0,
                                            imageURL: URL(string: "https://\(host)/image/0")!, refererURL: nil), rule: plain)
                        : source("\(index == 1 ? "rendered" : "document")/\(index)", rule: index == 1 ? rendered : plain, host: host)
                    group.addTask { _ = try await sender.send(request) }
                }
            }
            try await group.waitForAll()
        }
        let starts = SenderFixture.state.withLock { $0.starts }
        #expect(starts.count == 12)
        // Measure actual transport starts, allowing only small URLSession scheduling jitter.
        for index in 3..<starts.count { #expect(starts[index - 3].time.duration(to: starts[index].time) >= .milliseconds(375)) }
        for host in plain.allowedHosts {
            let times = starts.filter { $0.host == host }.map(\.time)
            for index in 2..<times.count { #expect(times[index - 2].duration(to: times[index]) >= .milliseconds(375)) }
        }
    }

    @Test func rateDelayedCancellationDoesNotSpendBudgetOrBlockAnotherHost() async throws {
        SenderFixture.reset()
        let sender = sender(burst: 3, hostBurst: 1, window: .milliseconds(600)), rule = try rule()
        _ = try await sender.send(source("first", rule: rule))
        let cancelled = Task { try await sender.send(source("cancelled", rule: rule)) }
        try await Task.sleep(for: .milliseconds(30))
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        async let delayed = sender.send(source("delayed", rule: rule))
        async let other = sender.send(source("other", rule: rule, host: "b.sender.test"))
        _ = try await (delayed, other)
        let stats = SenderFixture.state.withLock { $0 }
        #expect(stats.paths == ["/first", "/other", "/delayed"])
        #expect(stats.starts[0].time.duration(to: stats.starts[1].time) < .milliseconds(500))
        #expect(stats.starts[0].time.duration(to: stats.starts[2].time) >= .milliseconds(575))
        #expect(stats.starts[0].time.duration(to: stats.starts[2].time) < .seconds(1))
    }
}

private struct FixtureFetcher: SourceFetcher {
    let client: HTTPClient
    func fetch(_ url: URL, rule: SiteRule, kind: ContentKind, backgroundLoading: Bool) async throws -> SourceResponse {
        try await client.download(url, rule: rule)
    }
}

/// Delayed URLProtocol records actual transport overlap, including images and cancellation.
private final class SenderFixture: URLProtocol, @unchecked Sendable {
    struct Stats {
        var paths: [String] = []
        var starts: [(host: String, time: ContinuousClock.Instant)] = []
        var active = 0, peak = 0, rendered = 0, renderedPeak = 0, cancellations = 0
        var hosts: [String: Int] = [:], hostPeaks: [String: Int] = [:]
    }
    static let state = OSAllocatedUnfairLock(initialState: Stats())
    private let work = OSAllocatedUnfairLock(initialState: (task: Optional<Task<Void, Never>>.none, ended: false))
    static func reset() { state.withLock { $0 = Stats() } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        Self.state.withLock { stats in
            stats.paths.append(url.path); stats.active += 1; stats.peak = max(stats.peak, stats.active)
            let host = url.host!.lowercased()
            stats.starts.append((host, .now))
            stats.hosts[host, default: 0] += 1
            stats.hostPeaks[host] = max(stats.hostPeaks[host, default: 0], stats.hosts[host]!)
            if url.path.hasPrefix("/rendered/") { stats.rendered += 1; stats.renderedPeak = max(stats.renderedPeak, stats.rendered) }
        }
        work.withLock { state in
            state.task = Task { @Sendable [self, url] in
                do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
                guard end(cancelled: false) else { return }
                let response = HTTPURLResponse(url: url, statusCode: url.path == "/fail" ? 503 : 200, httpVersion: "HTTP/1.1", headerFields: nil)!
                let body = url.path == "/referer" ? request.value(forHTTPHeaderField: "Referer")! : "okay"
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data(body.utf8))
                client?.urlProtocolDidFinishLoading(self)
            }
        }
    }
    private func end(cancelled: Bool) -> Bool {
        let first = work.withLock { state in
            guard !state.ended else { return false }
            state.ended = true
            if cancelled { state.task?.cancel() }
            state.task = nil
            return true
        }
        if first, let url = request.url {
            Self.state.withLock { stats in
                stats.active -= 1; stats.hosts[url.host!.lowercased(), default: 1] -= 1
                if url.path.hasPrefix("/rendered/") { stats.rendered -= 1 }
                if cancelled { stats.cancellations += 1 }
            }
        }
        return first
    }
    override func stopLoading() { _ = end(cancelled: true) }
}
