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
    public let mangaRefs: [ContentReference]
    public let nextURL: URL?
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
        switch self { case .directory(let x): x.title; case .manga(let x): x.title; case .chapter(let x): x.title; case .page(let x): "Page \((x.sourceIndex ?? 0) + 1)" }
    }
}
public enum ReaderError: LocalizedError, Sendable {
    case unsupportedURL, ambiguousURL, invalidRule(String), blockedHost, invalidResponse, httpStatus(Int), tooLarge, extraction(String), cacheMiss, missingRule, renderedSourceRequired
    public var errorDescription: String? {
        switch self {
        case .unsupportedURL: "This URL is not supported by an installed rule."
        case .ambiguousURL: "More than one rule matches this URL. Adjust rule priorities."
        case .invalidRule(let reason): "Invalid rule: \(reason)"
        case .blockedHost: "The URL or redirect is outside this rule's allowed hosts."
        case .invalidResponse: "The server did not return a successful response."
        case .httpStatus(let code): "The server returned HTTP \(code). Try refreshing the chapter or opening the source website."
        case .tooLarge: "The response exceeds the download size limit."
        case .extraction(let reason): "Could not read this page: \(reason)"
        case .cacheMiss: "This content is not available in the local cache."
        case .missingRule: "The rule for this content is no longer installed."
        case .renderedSourceRequired: "This chapter needs the app's rendered website adapter."
        }
    }
}
