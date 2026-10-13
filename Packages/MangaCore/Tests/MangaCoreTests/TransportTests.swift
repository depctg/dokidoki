import Foundation
import Testing
import os
@testable import MangaCore

struct TransportTests {
    @Test func redirectsAndStreamingBodiesStayBounded() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TransportFixture.self]
        let client = HTTPClient(configuration: configuration)
        var json = try JSONSerialization.jsonObject(with: DemoContent.bundledRules().first { $0.id == "demo" }!.exported()) as! [String: Any]
        json["allowedHosts"] = ["transport.fixture.test"]
        json.removeValue(forKey: "browse"); json.removeValue(forKey: "searchURLTemplate")
        let rule = try SiteRule.decode(JSONSerialization.data(withJSONObject: json))
        let url = URL(string: "https://transport.fixture.test/")!
        let response = try await client.download(url.appendingPathComponent("okay"), rule: rule, limit: 8)
        #expect(response.data == Data("okay".utf8))
        await #expect(throws: ReaderError.self) { try await client.download(url.appendingPathComponent("large"), rule: rule, limit: 8) }
        await #expect(throws: ReaderError.self) { try await client.download(url.appendingPathComponent("stream"), rule: rule, limit: 8) }
        await #expect(throws: (any Error).self) { try await client.download(url.appendingPathComponent("redirect"), rule: rule) }
        #expect(!TransportFixture.requests.withLock { $0 }.contains("blocked.fixture.test"))
    }
}

private final class TransportFixture: URLProtocol, @unchecked Sendable {
    static let requests = OSAllocatedUnfairLock(initialState: [String]())
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        Self.requests.withLock { $0.append(url.host ?? "") }
        if url.path == "/redirect" {
            let destination = URL(string: "https://blocked.fixture.test/private")!
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": destination.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: destination), redirectResponse: response)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let data = Data((url.path == "/okay" ? "okay" : "0123456789abcdef").utf8)
        let headers = url.path == "/stream" ? [:] : ["Content-Length": String(data.count)]
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
