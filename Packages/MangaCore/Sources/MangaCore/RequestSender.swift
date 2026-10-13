import Foundation

public enum ContentRequest: Sendable {
    case source(ObjectKey, kind: ContentKind, rule: SiteRule)
    case image(PageObject, rule: SiteRule)

    fileprivate var rule: SiteRule {
        switch self { case .source(_, _, let rule), .image(_, let rule): rule }
    }
    fileprivate var url: URL {
        switch self { case .source(let key, _, _): key.identityURL; case .image(let page, _): page.imageURL }
    }
    fileprivate var rendered: Bool {
        if case .source(_, let kind, let rule) = self { return rule.extractors[kind.rawValue]?.format.isRendered == true }
        return false
    }
}

/// One admission queue for source documents, rendered sessions and image downloads.
/// Awaiting callers are notified independently; only the last cancellation stops shared work.
public actor RequestSender {
    private struct Key: Hashable {
        let url: URL
        let policy: Data
        let purpose: String
        let referer: URL?
    }
    private struct Flight {
        let id = UUID()
        let request: ContentRequest
        var waiters: [UUID: CheckedContinuation<SourceResponse, Error>]
        var task: Task<Void, Never>?
    }
    private let fetcher: any SourceFetcher
    private let client: HTTPClient
    private let maxConcurrent: Int
    private let perHost: Int
    private var flights: [Key: Flight] = [:]
    private var queue: [Key] = []
    private var active = 0
    private var activeHosts: [String: Int] = [:]
    private var activeRendered = 0

    public init(fetcher: any SourceFetcher = DefaultSourceFetcher(), client: HTTPClient = HTTPClient(), maxConcurrent: Int = 4, perHost: Int = 2) {
        self.fetcher = fetcher; self.client = client
        self.maxConcurrent = max(1, maxConcurrent); self.perHost = max(1, perHost)
    }
    public func send(_ request: ContentRequest) async throws -> SourceResponse {
        try Task.checkCancellation()
        guard request.rule.permits(request.url) else { throw ReaderError.blockedHost }
        let purpose: String
        let referer: URL?
        switch request {
        case .source(_, let kind, _): purpose = kind.rawValue; referer = nil
        case .image(let page, _): purpose = "image"; referer = page.refererURL
        }
        let key = Key(url: request.url, policy: try request.rule.exported(), purpose: purpose, referer: referer)
        let consumer = UUID()
        let response: SourceResponse = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SourceResponse, Error>) in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                if var flight = flights[key] {
                    flight.waiters[consumer] = continuation; flights[key] = flight
                } else {
                    flights[key] = Flight(request: request, waiters: [consumer: continuation])
                    queue.append(key)
                }
                startReadyRequests()
            }
        } onCancel: {
            Task { await self.cancel(key, consumer: consumer) }
        }
        try Task.checkCancellation()
        return response
    }
    private func startReadyRequests() {
        while active < maxConcurrent {
            // FIFO among requests whose host/session has capacity; a busy host cannot block others.
            guard let index = queue.firstIndex(where: { key in
                guard let flight = flights[key] else { return false }
                return activeHosts[key.url.host?.lowercased() ?? "", default: 0] < perHost && (!flight.request.rendered || activeRendered == 0)
            }) else { return }
            let key = queue.remove(at: index)
            guard var flight = flights[key] else { continue }
            let id = flight.id, request = flight.request
            active += 1; activeHosts[key.url.host?.lowercased() ?? "", default: 0] += 1
            if request.rendered { activeRendered += 1 }
            flight.task = Task {
                let result: Result<SourceResponse, Error>
                do {
                    try Task.checkCancellation()
                    let response: SourceResponse
                    switch request {
                    case .source(let object, let kind, let rule):
                        response = try await fetcher.fetch(object.identityURL, rule: rule, kind: kind)
                    case .image(let page, let rule):
                        if let fixture = try DemoContent.response(for: page.imageURL) { response = fixture }
                        else { response = try await client.download(page.imageURL, rule: rule, referer: page.refererURL, limit: 24 * 1024 * 1024) }
                    }
                    try Task.checkCancellation(); result = .success(response)
                } catch { result = .failure(error) }
                finish(key, id: id, rendered: request.rendered, result: result)
            }
            flights[key] = flight
        }
    }
    private func cancel(_ key: Key, consumer: UUID) {
        guard var flight = flights[key], let waiter = flight.waiters.removeValue(forKey: consumer) else { return }
        waiter.resume(throwing: CancellationError())
        if flight.waiters.isEmpty {
            flights[key] = nil; queue.removeAll { $0 == key }
            // Active slots stay occupied until transport actually finishes cancellation.
            flight.task?.cancel()
        } else { flights[key] = flight }
        startReadyRequests()
    }
    private func finish(_ key: Key, id: UUID, rendered: Bool, result: Result<SourceResponse, Error>) {
        active -= 1; activeHosts[key.url.host?.lowercased() ?? "", default: 1] -= 1
        if rendered { activeRendered -= 1 }
        // An abandoned request may finish after a retry has entered the queue under the same key.
        if let flight = flights[key], flight.id == id {
            flights[key] = nil
            for waiter in flight.waiters.values { waiter.resume(with: result) }
        }
        startReadyRequests()
    }
}
