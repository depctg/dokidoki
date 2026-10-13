import Foundation

public enum ContentKind: String, Codable, Sendable, CaseIterable { case directory, manga, chapter, page }

public struct ObjectKey: Hashable, Codable, Sendable, Identifiable {
    public let ruleID: String
    public let identityURL: URL
    public var id: String { ruleID + "|" + identityURL.absoluteString }
    public init(ruleID: String, identityURL: URL) { self.ruleID = ruleID; self.identityURL = identityURL }

    public static func page(owner: ObjectKey, index: Int) -> ObjectKey {
        var components = URLComponents()
        components.scheme = "reader"; components.host = "page"; components.path = "/\(index)"
        components.queryItems = [URLQueryItem(name: "owner", value: owner.identityURL.absoluteString)]
        return ObjectKey(ruleID: owner.ruleID, identityURL: components.url!)
    }
    public var owner: ObjectKey? {
        guard identityURL.scheme == "reader", identityURL.host == "page",
              let value = URLComponents(url: identityURL, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "owner" })?.value,
              let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return ObjectKey(ruleID: ruleID, identityURL: url)
    }
}

public struct ContentReference: Codable, Sendable, Hashable, Identifiable {
    public let key: ObjectKey
    public let title: String
    public var id: ObjectKey { key }
    public init(key: ObjectKey, title: String) { self.key = key; self.title = title }
}
public struct DirectoryObject: Codable, Sendable {
    public let key: ObjectKey
    public let sourceURL: URL
    public let title: String
    public let items: [ContentReference]?
    public var mangaRefs: [ContentReference] { items ?? [] }
    public var hasMore: Bool? { items == nil ? nil : nextURL != nil }
    private enum CodingKeys: String, CodingKey {
        case key, sourceURL, title, nextURL, sortBy, sortOrder, selectedSortBy, selectedSortOrder
        case items = "mangaRefs"
    }
    public init(key: ObjectKey, sourceURL: URL, title: String, mangaRefs: [ContentReference]? = nil, nextURL: URL? = nil,
                sortBy: [ContentReference]? = nil, sortOrder: [ContentReference]? = nil, selectedSortBy: ObjectKey? = nil, selectedSortOrder: ObjectKey? = nil) {
        self.key = key; self.sourceURL = sourceURL; self.title = title; items = mangaRefs; self.nextURL = nextURL
        self.sortBy = sortBy; self.sortOrder = sortOrder; self.selectedSortBy = selectedSortBy; self.selectedSortOrder = selectedSortOrder
    }
    public let nextURL: URL?
    /// Optional source-provided sort destinations; absent fields keep older snapshots readable.
    public var sortBy: [ContentReference]? = nil
    public var sortOrder: [ContentReference]? = nil
    public var selectedSortBy: ObjectKey? = nil
    public var selectedSortOrder: ObjectKey? = nil
}
public struct MangaObject: Codable, Sendable {
    public let key: ObjectKey
    public let sourceURL: URL
    public let title: String
    public let author: String?
    public let summary: String?
    public let coverPageRef: ObjectKey?
    /// Reading order supplied by the parsing rule; this object owns chapter navigation.
    public let chapterRefs: [ContentReference]
    /// Optional source text, including its own rating scale and publication-status wording.
    /// Missing keys decode as nil in snapshots written before metadata support.
    public var rating: String? = nil
    public var status: String? = nil
    public var tags: [String]? = nil

    public func nextChapter(after chapter: ObjectKey) -> ContentReference? {
        guard let index = chapterRefs.firstIndex(where: { $0.key == chapter }), index + 1 < chapterRefs.count else { return nil }
        return chapterRefs[index + 1]
    }
    public func previousChapter(before chapter: ObjectKey) -> ContentReference? {
        guard let index = chapterRefs.firstIndex(where: { $0.key == chapter }), index > 0 else { return nil }
        return chapterRefs[index - 1]
    }
}
public struct ChapterObject: Codable, Sendable {
    public let key: ObjectKey
    public let sourceURL: URL
    public let title: String
    public let mangaRef: ObjectKey?
    public let pageRefs: [ObjectKey]
}
public struct PageObject: Codable, Sendable, Identifiable {
    public enum Role: String, Codable, Sendable { case cover, content }
    public let key: ObjectKey
    public let ownerRef: ObjectKey?
    public let role: Role
    public let sourceIndex: Int?
    public let imageURL: URL
    public let refererURL: URL?
    public var id: ObjectKey { key }
    public init(key: ObjectKey, ownerRef: ObjectKey?, role: Role = .content, sourceIndex: Int?, imageURL: URL, refererURL: URL?) {
        self.key = key; self.ownerRef = ownerRef; self.role = role; self.sourceIndex = sourceIndex
        self.imageURL = imageURL; self.refererURL = refererURL
    }
}
public enum ContentObject: Codable, Sendable {
    case directory(DirectoryObject), manga(MangaObject), chapter(ChapterObject), page(PageObject)
    public var key: ObjectKey {
        switch self { case .directory(let x): x.key; case .manga(let x): x.key; case .chapter(let x): x.key; case .page(let x): x.key }
    }
    public var kind: ContentKind {
        switch self { case .directory: .directory; case .manga: .manga; case .chapter: .chapter; case .page: .page }
    }
    public var title: String {
        switch self { case .directory(let x): x.title; case .manga(let x): x.title; case .chapter(let x): x.title; case .page(let x): String(localized: "Page \((x.sourceIndex ?? 0) + 1)", bundle: .module) }
    }
}
public enum ReaderError: LocalizedError, Sendable {
    case unsupportedURL, ambiguousURL, invalidRule(String), blockedHost, invalidResponse, httpStatus(Int), tooLarge, extraction(String), cacheMiss, missingRule, renderedSourceRequired
    public var errorDescription: String? {
        switch self {
        case .unsupportedURL: String(localized: "This URL is not supported by an installed rule.", bundle: .module)
        case .ambiguousURL: String(localized: "More than one rule matches this URL. Adjust rule priorities.", bundle: .module)
        case .invalidRule(let reason): String(localized: "Invalid rule: \(reason)", bundle: .module)
        case .blockedHost: String(localized: "The URL or redirect is outside this rule's allowed hosts.", bundle: .module)
        case .invalidResponse: String(localized: "The server did not return a successful response.", bundle: .module)
        case .httpStatus(let code): String(localized: "The server returned HTTP \(code). Try refreshing the chapter or opening the source website.", bundle: .module)
        case .tooLarge: String(localized: "The response exceeds the download size limit.", bundle: .module)
        case .extraction(let reason): String(localized: "Could not read this page: \(reason)", bundle: .module)
        case .cacheMiss: String(localized: "This content is not available in the local cache.", bundle: .module)
        case .missingRule: String(localized: "The rule for this content is no longer installed.", bundle: .module)
        case .renderedSourceRequired: String(localized: "This chapter needs the app's rendered website adapter.", bundle: .module)
        }
    }
}
