import Foundation

public struct SourceResponse: Sendable {
    public let data: Data
    public let url: URL
    public init(data: Data, url: URL) { self.data = data; self.url = url }
}
public protocol SourceFetcher: Sendable {
    func fetch(_ url: URL, rule: SiteRule, kind: ContentKind, backgroundLoading: Bool) async throws -> SourceResponse
}

private final class RedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    let rule: SiteRule
    init(rule: SiteRule) { self.rule = rule }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? {
        guard let url = request.url, rule.permits(url) else { return nil }; return request
    }
}

/// Bounded HTTP bodies and redirect policy. RequestSender owns request admission.
public actor HTTPClient {
    private let configuration: URLSessionConfiguration
    public init(configuration: URLSessionConfiguration = .ephemeral) {
        self.configuration = configuration.copy() as! URLSessionConfiguration
    }
    public func download(_ url: URL, rule: SiteRule, referer: URL? = nil, limit: Int = 8 * 1024 * 1024) async throws -> SourceResponse {
        guard rule.permits(url) else { throw ReaderError.blockedHost }
        try Task.checkCancellation()
        let config = configuration.copy() as! URLSessionConfiguration
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 60
        config.httpCookieStorage = nil; config.urlCache = nil
        let policy = RedirectPolicy(rule: rule)
        let session = URLSession(configuration: config, delegate: policy, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.setValue("MangaViewer/1.0", forHTTPHeaderField: "User-Agent")
        if let referer, rule.permits(referer) { request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer") }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, let finalURL = response.url, rule.permits(finalURL) else { throw ReaderError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else { throw ReaderError.httpStatus(response.statusCode) }
        guard response.expectedContentLength <= limit else { throw ReaderError.tooLarge }
        var data = Data(); data.reserveCapacity(min(limit, max(0, Int(response.expectedContentLength))))
        for try await byte in bytes {
            guard data.count < limit else { throw ReaderError.tooLarge }
            data.append(byte)
            if data.count % 16384 == 0 { try Task.checkCancellation() }
        }
        return SourceResponse(data: data, url: finalURL)
    }
}
public struct DefaultSourceFetcher: SourceFetcher {
    public let client: HTTPClient
    public init(client: HTTPClient = HTTPClient()) { self.client = client }
    public func fetch(_ url: URL, rule: SiteRule, kind: ContentKind, backgroundLoading: Bool) async throws -> SourceResponse {
        if let response = try DemoContent.response(for: url) { return response }
        if rule.extraction(for: kind, at: url)?.format.isRendered == true { throw ReaderError.renderedSourceRequired }
        return try await client.download(url, rule: rule)
    }
}
