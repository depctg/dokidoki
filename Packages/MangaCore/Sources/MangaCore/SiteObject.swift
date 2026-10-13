import Foundation

/// Declarative Browse/search entry points. Core loads and caches each declared source page.
public struct SiteObject: Sendable, Identifiable {
    public let id: String
    public let name: String
    public let version: Int
    public let browseRefs: [ContentReference]
    public var supportsSearch: Bool { rule.searchURLTemplate != nil }
    private let rule: SiteRule

    public init(rule: SiteRule) throws {
        try rule.validate()
        self.rule = rule; id = rule.id; name = rule.name; version = rule.version
        browseRefs = try (rule.browse ?? []).map {
            ContentReference(key: ObjectKey(ruleID: rule.id, identityURL: try RuleRegistry.normalize($0.url)), title: $0.title)
        }
    }

    public func load(using repository: ObjectRepository, hint: CacheHint = .preferCache) async throws -> [DirectoryObject] {
        do { return try await repository.directories(from: browseRefs, hint: hint) }
        catch {
            if case ReaderError.cacheMiss = error, hint == .offlineOnly { throw error }
            ErrorDiagnostics.record(error, operation: .loadContent); throw error
        }
    }

    /// Search is explicit, rule-scoped, and yields one directory, just like a Browse list.
    public func search(_ query: String) throws -> ContentReference? {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, let template = rule.searchURLTemplate else { return nil }
        var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: "-._~")
        guard let escaped = query.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: template.replacingOccurrences(of: "{query}", with: escaped)) else { throw ReaderError.unsupportedURL }
        let (_, kind, key) = try RuleRegistry(rules: [rule]).match(url, ruleID: id)
        guard kind == .directory else { throw ReaderError.unsupportedURL }
        return ContentReference(key: key, title: query)
    }
}

extension DirectoryObject {
    /// Pagination belongs to this single list; views never construct its request URL/key.
    public var nextPage: ContentReference? {
        nextURL.map { ContentReference(key: ObjectKey(ruleID: key.ruleID, identityURL: $0), title: title) }
    }
}

extension SitePageObject {
    public func lists(using repository: ObjectRepository, hint: CacheHint = .preferCache) async throws -> [DirectoryObject] {
        do { return try await repository.directoryPreviews(directoryRefs, hint: hint) }
        catch {
            if case ReaderError.cacheMiss = error, hint == .offlineOnly { throw error }
            ErrorDiagnostics.record(error, operation: .loadContent, url: sourceURL); throw error
        }
    }
}
