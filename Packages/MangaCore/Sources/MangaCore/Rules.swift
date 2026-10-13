import Foundation
import libxml2

public struct Field: Codable, Sendable {
    public let path: String
    public var read: String? = nil
    /// Relative label path for a selected JSON link object (default: title).
    public var titlePath: String? = nil
    public var fallback: String? = nil
    public var urlTemplate: String? = nil
    public var queryPath: String? = nil
    public var regex: String? = nil
    public var group: Int? = nil
    public var reverse: Bool? = nil
}
/// Data-only parameters for the generic WebKit observer, never executable script.
public struct RenderingRule: Codable, Sendable {
    public enum ContentMode: String, Codable, Sendable { case recommended, desktop, mobile }
    public var contentMode: ContentMode? = nil
    public var captureFunction: String? = nil
    /// Observe the normal return value instead of the first argument.
    public var captureResult: Bool? = nil
    public var readyImageXPath: String? = nil
    /// Wait for a site-created DOM node before taking an asynchronous rendered snapshot.
    public var readyXPath: String? = nil
    /// Defaults to on; false disables hidden images/media/fonts, including ads, for this kind.
    /// The global background-loading setting can always disable it.
    public var loadAds: Bool? = nil
}
public struct SessionRule: Codable, Sendable {
    public enum Mode: String, Codable, Sendable { case load, page, scroll }
    public let mode: Mode
    public var actionXPath: String? = nil
    public var endXPath: String? = nil
}
public struct ExtractionRule: Codable, Sendable {
    public enum Format: String, Codable, Sendable {
        case html, json, renderedHTML, renderedJSON
        var isJSON: Bool { self == .json || self == .renderedJSON }
        var isRendered: Bool { self == .renderedHTML || self == .renderedJSON }
    }
    public let format: Format
    public let fields: [String: Field]
    public var rendering: RenderingRule? = nil
    public var variables: [String: Field]? = nil
    public var pagination: OffsetPagination? = nil
    public var session: SessionRule? = nil
}
extension ExtractionRule {
    private enum CodingKeys: String, CodingKey { case format, fields, rendering, variables, pagination, session }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decodeIfPresent(Format.self, forKey: .format) ?? .renderedHTML
        fields = try c.decode([String: Field].self, forKey: .fields)
        rendering = try c.decodeIfPresent(RenderingRule.self, forKey: .rendering)
        variables = try c.decodeIfPresent([String: Field].self, forKey: .variables)
        pagination = try c.decodeIfPresent(OffsetPagination.self, forKey: .pagination)
        session = try c.decodeIfPresent(SessionRule.self, forKey: .session)
    }
}
/// JSON response counters and the URL query parameter advanced by one page.
public struct OffsetPagination: Codable, Sendable {
    public let offset: String
    public let limit: String
    public let total: String
    public let parameter: String
}
public struct URLMatcher: Codable, Sendable {
    public let kind: ContentKind
    public let pattern: String
    public var priority: Int = 0
    public var extractor: String? = nil
}
/// Minimal JSON declaration; SiteObject turns it into a normalized directory reference.
public struct BrowseList: Codable, Sendable, Identifiable {
    public let title: String
    public let url: URL
    public var id: URL { url }
}
public struct SiteRule: Codable, Sendable, Identifiable {
    public let schemaVersion: Int
    public let id: String
    public let name: String
    public let version: Int
    public let allowedHosts: [String]
    public let matchers: [URLMatcher]
    public let extractors: [String: ExtractionRule]
    public var searchURLTemplate: String? = nil
    public var browse: [BrowseList]? = nil
    public var processors: [String]? = nil

    /// A matcher can select another recipe for the same object kind (e.g. an HTML
    /// catalog and a JSON search API). URL recognition remains entirely in JSON.
    public func extraction(for kind: ContentKind, at url: URL) -> ExtractionRule? {
        let normalized = (try? RuleRegistry.normalize(url)) ?? url
        let matcher = matchers.filter { $0.kind == kind && normalized.absoluteString.range(of: $0.pattern, options: .regularExpression) != nil }
            .max { $0.priority < $1.priority }
        return extractors[matcher?.extractor ?? kind.rawValue]
    }

    public func permits(_ url: URL) -> Bool {
        ["https", "http"].contains(url.scheme?.lowercased() ?? "") && url.user == nil && url.password == nil &&
        (url.port == nil || url.port == 80 || url.port == 443) && allowedHosts.contains(url.host?.lowercased() ?? "")
    }
    public func validate() throws {
        guard schemaVersion == 1, version > 0, !id.isEmpty, id.count < 100, !name.isEmpty,
              !allowedHosts.isEmpty, !matchers.isEmpty else { throw ReaderError.invalidRule(String(localized: "Missing identity, hosts, or supported schema version.", bundle: .module)) }
        for host in allowedHosts {
            guard host == host.lowercased(), host.range(of: "^[a-z0-9][a-z0-9.-]*[a-z0-9]$", options: .regularExpression) != nil,
                  !host.contains("..") else { throw ReaderError.invalidRule(String(localized: "Hosts must be exact domain names.", bundle: .module)) }
        }
        for matcher in matchers {
            guard matcher.pattern.count <= 1024, matcher.pattern.hasPrefix("^"), matcher.pattern.hasSuffix("$"),
                  (try? NSRegularExpression(pattern: matcher.pattern)) != nil,
                  let extraction = extractors[matcher.extractor ?? matcher.kind.rawValue] else { throw ReaderError.invalidRule(String(localized: "Invalid URL matcher or missing extractor.", bundle: .module)) }
            let required: [String] = switch matcher.kind {
            case .directory: ["title", "mangaLinks"]
            case .manga: ["title", "chapterLinks"]
            case .chapter: ["title", "pageImages"]
            case .page: ["image"]
            }
            guard required.allSatisfy({ extraction.fields[$0] != nil }) else { throw ReaderError.invalidRule(String(localized: "Missing required extraction fields for \(matcher.kind.rawValue).", bundle: .module)) }
            for (name, field) in extraction.variables ?? [:] {
                guard name.range(of: #"^[A-Za-z][A-Za-z0-9_]*$"#, options: .regularExpression) != nil,
                      field.urlTemplate == nil, field.queryPath == nil else { throw ReaderError.invalidRule(String(localized: "Variables have simple names and select values without URL templates.", bundle: .module)) }
            }
            for field in Array(extraction.fields.values) + Array((extraction.variables ?? [:]).values) {
                guard !field.path.isEmpty, field.path.count <= 2048 else { throw ReaderError.invalidRule(String(localized: "Empty or oversized selector.", bundle: .module)) }
                for read in [field.read, field.fallback].compactMap({ $0 }) {
                    guard read == "text" || read.range(of: "^attr:[a-zA-Z0-9_-]+$", options: .regularExpression) != nil else { throw ReaderError.invalidRule(String(localized: "Unsupported field reader.", bundle: .module)) }
                }
                if let path = field.titlePath {
                    guard extraction.format.isJSON, Self.validJSONPath(path) else { throw ReaderError.invalidRule(String(localized: "Invalid JSON link title path.", bundle: .module)) }
                }
                if !extraction.format.isJSON {
                    guard let compiled = xmlXPathCompile(field.path) else { throw ReaderError.invalidRule(String(localized: "Invalid XPath selector.", bundle: .module)) }
                    xmlXPathFreeCompExpr(compiled)
                }
                if let template = field.urlTemplate {
                    guard template.count <= 4096 else { throw ReaderError.invalidRule(String(localized: "URL templates allow at most 4096 characters.", bundle: .module)) }
                    let pattern = #"\{(value|[A-Za-z_$][A-Za-z0-9_$]*(\.[A-Za-z0-9_$]+)*)\}"#
                    let stripped = template.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
                    guard !stripped.contains("{"), !stripped.contains("}") else { throw ReaderError.invalidRule(String(localized: "URL templates support only {value} and dotted paths.", bundle: .module)) }
                }
                if let pattern = field.regex {
                    guard pattern.count <= 2048, let regex = try? NSRegularExpression(pattern: pattern),
                          (0...regex.numberOfCaptureGroups).contains(field.group ?? min(1, regex.numberOfCaptureGroups)) else { throw ReaderError.invalidRule(String(localized: "Invalid extraction regex or capture group.", bundle: .module)) }
                } else if field.group != nil { throw ReaderError.invalidRule(String(localized: "Capture groups require a regex.", bundle: .module)) }
                if let path = field.queryPath {
                    guard extraction.format.isJSON, path.range(of: #"^[A-Za-z_$][A-Za-z0-9_$]*(\.[A-Za-z0-9_$]+)*$"#, options: .regularExpression) != nil else { throw ReaderError.invalidRule(String(localized: "Query parameters require a JSON object path.", bundle: .module)) }
                }
            }
            if let pagination = extraction.pagination {
                guard matcher.kind == .directory, extraction.format.isJSON, extraction.fields["next"] == nil,
                      [pagination.offset, pagination.limit, pagination.total].allSatisfy(Self.validJSONPath),
                      !pagination.parameter.isEmpty, pagination.parameter.count <= 100 else {
                    throw ReaderError.invalidRule(String(localized: "Offset pagination needs JSON counters, a query parameter, and no next-link selector.", bundle: .module))
                }
            }
            if let rendering = extraction.rendering {
                guard extraction.format.isRendered else { throw ReaderError.invalidRule(String(localized: "Rendering options require a rendered format.", bundle: .module)) }
                if let function = rendering.captureFunction {
                    guard function.count <= 256, function.range(of: #"^[A-Za-z_$][A-Za-z0-9_$]*(\.[A-Za-z_$][A-Za-z0-9_$]*)*$"#, options: .regularExpression) != nil,
                          !function.split(separator: ".").contains(where: { ["__proto__", "prototype", "constructor"].contains(String($0)) }) else { throw ReaderError.invalidRule(String(localized: "Capture must name a function using a simple dotted path.", bundle: .module)) }
                }
                for xpath in [rendering.readyImageXPath, rendering.readyXPath].compactMap({ $0 }) {
                    guard xpath.count <= 2048, let compiled = xmlXPathCompile(xpath) else { throw ReaderError.invalidRule(String(localized: "Invalid image readiness XPath.", bundle: .module)) }
                    xmlXPathFreeCompExpr(compiled)
                }
            }
            if let session = extraction.session {
                if session.mode != .load {
                    guard [.chapter, .directory].contains(matcher.kind), extraction.format == .renderedHTML, session.actionXPath != nil else { throw ReaderError.invalidRule(String(localized: "Session actions need rendered HTML and an XPath target.", bundle: .module)) }
                }
                if matcher.kind != .chapter, session.actionXPath?.contains("{index}") == true { throw ReaderError.invalidRule(String(localized: "Indexed session targets are only supported for chapter pages.", bundle: .module)) }
                for xpath in [session.actionXPath, session.endXPath].compactMap({ $0 }) {
                    guard xpath.count <= 2048, let compiled = xmlXPathCompile(xpath.replacingOccurrences(of: "{index}", with: "1")) else { throw ReaderError.invalidRule(String(localized: "Invalid XPath selector.", bundle: .module)) }
                    xmlXPathFreeCompExpr(compiled)
                }
            }
            if extraction.format == .renderedJSON {
                guard extraction.rendering?.captureFunction != nil, extraction.rendering?.readyImageXPath != nil else { throw ReaderError.invalidRule(String(localized: "Rendered JSON needs a capture function and an image readiness XPath.", bundle: .module)) }
            }
        }
        guard (processors ?? []).allSatisfy({ ["identity", "marginAlign", "spreadDetect", "layout"].contains($0) }) else { throw ReaderError.invalidRule(String(localized: "Unknown page processor.", bundle: .module)) }
        func isDirectory(_ url: URL) -> Bool {
            guard permits(url), let normalized = try? RuleRegistry.normalize(url) else { return false }
            let matches = matchers.filter { normalized.absoluteString.range(of: $0.pattern, options: .regularExpression) != nil }
            let winners = matches.filter { $0.priority == matches.map(\.priority).max() }
            return winners.count == 1 && winners[0].kind == .directory
        }
        let lists = browse ?? []
        guard lists.count <= 24, Set(try lists.map { try RuleRegistry.normalize($0.url) }).count == lists.count,
              lists.allSatisfy({ !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && isDirectory($0.url) }) else {
            throw ReaderError.invalidRule(String(localized: "Browse lists need unique, allowed directory URLs and nonempty titles (at most 24 lists).", bundle: .module))
        }
        if let template = searchURLTemplate {
            guard template.contains("{query}"), let url = URL(string: template.replacingOccurrences(of: "{query}", with: "test")), isDirectory(url) else { throw ReaderError.invalidRule(String(localized: "Search must use an allowed directory URL and {query}.", bundle: .module)) }
        }
    }
    private static func validJSONPath(_ path: String) -> Bool {
        path.count <= 2048 && path.range(of: #"^[A-Za-z_$][A-Za-z0-9_$]*(\.[A-Za-z0-9_$]+)*$"#, options: .regularExpression) != nil
    }
    public static func decode(_ data: Data) throws -> SiteRule {
        guard data.count <= 128 * 1024 else { throw ReaderError.tooLarge }
        // Unknown fields are rejected: secret-bearing headers/scripts cannot hide in an export.
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let supported: Set<String> = ["schemaVersion", "id", "name", "version", "allowedHosts", "matchers", "extractors", "searchURLTemplate", "browse", "processors"]
        guard Set(json.keys).isSubset(of: supported) else { throw ReaderError.invalidRule(String(localized: "Unsupported fields (scripts and request credentials are not allowed).", bundle: .module)) }
        for list in json["browse"] as? [[String: Any]] ?? [] {
            guard Set(list.keys).isSubset(of: ["title", "url"]) else { throw ReaderError.invalidRule(String(localized: "Browse lists contain only a title and URL.", bundle: .module)) }
        }
        for matcher in json["matchers"] as? [[String: Any]] ?? [] {
            guard Set(matcher.keys).isSubset(of: ["kind", "pattern", "priority", "extractor"]) else { throw ReaderError.invalidRule(String(localized: "Invalid URL matcher or missing extractor.", bundle: .module)) }
        }
        for extractor in (json["extractors"] as? [String: [String: Any]] ?? [:]).values {
            guard Set(extractor.keys).isSubset(of: ["format", "fields", "rendering", "variables", "pagination", "session"]) else { throw ReaderError.invalidRule(String(localized: "Unsupported extractor options.", bundle: .module)) }
            if let session = extractor["session"] as? [String: Any], !Set(session.keys).isSubset(of: ["mode", "actionXPath", "endXPath"]) { throw ReaderError.invalidRule(String(localized: "Unsupported extractor options.", bundle: .module)) }
            if let pagination = extractor["pagination"] as? [String: Any], !Set(pagination.keys).isSubset(of: ["offset", "limit", "total", "parameter"]) { throw ReaderError.invalidRule(String(localized: "Unsupported extractor options.", bundle: .module)) }
            let fields = Array((extractor["fields"] as? [String: [String: Any]] ?? [:]).values) + Array((extractor["variables"] as? [String: [String: Any]] ?? [:]).values)
            for field in fields {
                guard Set(field.keys).isSubset(of: ["path", "read", "titlePath", "fallback", "urlTemplate", "queryPath", "regex", "group", "reverse"]) else { throw ReaderError.invalidRule(String(localized: "Unsupported field options.", bundle: .module)) }
            }
            if let rendering = extractor["rendering"] as? [String: Any], !Set(rendering.keys).isSubset(of: ["contentMode", "captureFunction", "captureResult", "readyImageXPath", "readyXPath", "loadAds"]) { throw ReaderError.invalidRule(String(localized: "Unsupported rendering options; scripts are not allowed.", bundle: .module)) }
        }
        let rule = try JSONDecoder().decode(SiteRule.self, from: data); try rule.validate(); return rule
    }
    public func exported() throws -> Data {
        try validate(); let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

public struct RuleRegistry: Sendable {
    public let rules: [SiteRule]
    public init(rules: [SiteRule]) throws {
        for rule in rules { try rule.validate() }
        guard Set(rules.map(\.id)).count == rules.count else { throw ReaderError.invalidRule(String(localized: "Duplicate rule IDs.", bundle: .module)) }
        self.rules = rules
    }
    public static func normalize(_ url: URL) throws -> URL {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: true),
              ["http", "https"].contains(c.scheme?.lowercased() ?? ""), c.host != nil,
              c.user == nil, c.password == nil else { throw ReaderError.unsupportedURL }
        c.scheme = c.scheme?.lowercased(); c.host = c.host?.lowercased(); c.fragment = nil
        if c.path.isEmpty { c.path = "/" }
        if (c.scheme == "https" && c.port == 443) || (c.scheme == "http" && c.port == 80) { c.port = nil }
        guard let result = c.url else { throw ReaderError.unsupportedURL }; return result
    }
    public func match(_ url: URL, ruleID: String? = nil) throws -> (SiteRule, ContentKind, ObjectKey) {
        let url = try Self.normalize(url)
        var matches: [(SiteRule, URLMatcher)] = []
        for rule in rules where (ruleID == nil || rule.id == ruleID) && rule.permits(url) {
            for matcher in rule.matchers where url.absoluteString.range(of: matcher.pattern, options: .regularExpression) != nil { matches.append((rule, matcher)) }
        }
        guard let maxPriority = matches.map({ $0.1.priority }).max() else { throw ReaderError.unsupportedURL }
        let winners = matches.filter { $0.1.priority == maxPriority }
        guard winners.count == 1 else { throw ReaderError.ambiguousURL }
        let (rule, matcher) = winners[0]
        return (rule, matcher.kind, ObjectKey(ruleID: rule.id, identityURL: url))
    }
}
