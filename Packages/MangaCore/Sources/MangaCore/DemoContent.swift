import Foundation

public enum DemoContent {
    public static let directoryURL = URL(string: "https://demo.mangaviewer.local/catalog")!
    public static func bundledRules() throws -> [SiteRule] {
        try ["demo", "manhuagui"].map { try SiteRule.decode(resource($0, extension: "json")) }
    }
    public static func resource(_ name: String, extension ext: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Resources") else { throw ReaderError.cacheMiss }
        return try Data(contentsOf: url)
    }
    public static func response(for url: URL) throws -> SourceResponse? {
        guard url.host == directoryURL.host else { return nil }
        let name: String; let ext: String
        switch url.path {
        case "/catalog": name = "catalog"; ext = "html"
        case "/series/observatory": name = "manga"; ext = "html"
        case "/chapter/arrival": name = "arrival"; ext = "json"
        case "/chapter/starlight": name = "starlight"; ext = "json"
        case let path where path.hasPrefix("/images/"): name = url.deletingPathExtension().lastPathComponent; ext = "png"
        default: throw ReaderError.unsupportedURL
        }
        return SourceResponse(data: try resource(name, extension: ext), url: url)
    }
}
