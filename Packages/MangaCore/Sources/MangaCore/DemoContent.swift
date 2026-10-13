import Foundation

public enum DemoContent {
    public static let directoryURL = URL(string: "https://demo.mangaviewer.local/catalog")!
    public static func bundledRules() throws -> [SiteRule] {
        guard let directory = Bundle.module.url(forResource: "Rules", withExtension: nil) else { throw ReaderError.cacheMiss }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        return try files.map { try SiteRule.decode(Data(contentsOf: $0)) }
    }
    public static func resource(_ name: String, extension ext: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures") else { throw ReaderError.cacheMiss }
        return try Data(contentsOf: url)
    }
    public static func response(for url: URL) throws -> SourceResponse? {
        guard url.host == directoryURL.host else { return nil }
        let name: String; let ext: String
        switch url.path {
        case "/catalog":
            // Offline fixture responses, not website parsing or client-side sorting.
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let byTitle = query.contains(URLQueryItem(name: "sort", value: "title"))
            let descending = query.contains(URLQueryItem(name: "order", value: "descending"))
            if query.contains(URLQueryItem(name: "browser", value: "page")) { name = "browser-page" }
            else if query.contains(URLQueryItem(name: "q", value: "story")) {
                name = query.contains(URLQueryItem(name: "offset", value: "1")) ? "search-second" : "search-first"
            } else { name = byTitle ? (descending ? "catalog-descending" : "catalog-title") : "catalog" }
            ext = "html"
        case "/series/observatory": name = "manga"; ext = "html"
        case "/series/aster": name = "aster"; ext = "html"
        case "/chapter/arrival": name = "arrival"; ext = "json"
        case "/chapter/starlight": name = "starlight"; ext = "json"
        case "/chapter/rejoined": name = "rejoined"; ext = "json"
        case "/chapter/lazy": name = "browser-scroll"; ext = "html"
        case "/chapter/paged": name = "browser-page"; ext = "html"
        case "/chapter/capture": name = "browser-capture"; ext = "html"
        case let path where path.hasPrefix("/images/"): name = url.deletingPathExtension().lastPathComponent; ext = "png"
        default: throw ReaderError.unsupportedURL
        }
        return SourceResponse(data: try resource(name, extension: ext), url: url)
    }
}
