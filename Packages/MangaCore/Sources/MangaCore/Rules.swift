import Foundation
import libxml2

public struct Field: Codable, Sendable {
    public let path: String
    public var read: String? = nil
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
    public var readyImageXPath: String? = nil
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
}
public struct URLMatcher: Codable, Sendable {
    public let kind: ContentKind
    public let pattern: String
    public var priority: Int = 0
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
    public var processors: [String]? = nil

    public func permits(_ url: URL) -> Bool {
        ["https", "http"].contains(url.scheme?.lowercased() ?? "") && url.user == nil && url.password == nil &&
        (url.port == nil || url.port == 80 || url.port == 443) && allowedHosts.contains(url.host?.lowercased() ?? "")
    }
    public func validate() throws {
        guard schemaVersion == 1, version > 0, !id.isEmpty, id.count < 100, !name.isEmpty,
              !allowedHosts.isEmpty, !matchers.isEmpty else { throw ReaderError.invalidRule("Missing identity, hosts, or supported schema version.") }
        for host in allowedHosts {
            guard host == host.lowercased(), host.range(of: "^[a-z0-9][a-z0-9.-]*[a-z0-9]$", options: .regularExpression) != nil,
                  !host.contains("..") else { throw ReaderError.invalidRule("Hosts must be exact domain names.") }
        }
        for matcher in matchers {
            guard matcher.pattern.count <= 1024, matcher.pattern.hasPrefix("^"), matcher.pattern.hasSuffix("$"),
                  (try? NSRegularExpression(pattern: matcher.pattern)) != nil,
                  let extraction = extractors[matcher.kind.rawValue] else { throw ReaderError.invalidRule("Invalid URL matcher or missing extractor.") }
            let required: [String] = switch matcher.kind {
            case .directory: ["title", "mangaLinks"]
            case .manga: ["title", "chapterLinks"]
            case .chapter: ["title", "pageImages"]
            case .page: ["image"]
            }
            guard required.allSatisfy({ extraction.fields[$0] != nil }) else { throw ReaderError.invalidRule("Missing required extraction fields for \(matcher.kind.rawValue).") }
            for (name, field) in extraction.variables ?? [:] {
                guard name.range(of: #"^[A-Za-z][A-Za-z0-9_]*$"#, options: .regularExpression) != nil,
                      field.urlTemplate == nil, field.queryPath == nil else { throw ReaderError.invalidRule("Variables have simple names and select values without URL templates.") }
            }
            for field in Array(extraction.fields.values) + Array((extraction.variables ?? [:]).values) {
                guard !field.path.isEmpty, field.path.count <= 2048 else { throw ReaderError.invalidRule("Empty or oversized selector.") }
                for read in [field.read, field.fallback].compactMap({ $0 }) {
                    guard read == "text" || read.range(of: "^attr:[a-zA-Z0-9_-]+$", options: .regularExpression) != nil else { throw ReaderError.invalidRule("Unsupported field reader.") }
                }
                if !extraction.format.isJSON {
                    guard let compiled = xmlXPathCompile(field.path) else { throw ReaderError.invalidRule("Invalid XPath selector.") }
                    xmlXPathFreeCompExpr(compiled)
                }
                if let template = field.urlTemplate {
                    guard template.count <= 4096 else { throw ReaderError.invalidRule("URL templates allow at most 4096 characters.") }
                    let pattern = #"\{(value|[A-Za-z_$][A-Za-z0-9_$]*(\.[A-Za-z0-9_$]+)*)\}"#
                    let stripped = template.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
                    guard !stripped.contains("{"), !stripped.contains("}") else { throw ReaderError.invalidRule("URL templates support only {value} and dotted paths.") }
                }
                if let pattern = field.regex {
                    guard pattern.count <= 2048, let regex = try? NSRegularExpression(pattern: pattern),
                          (0...regex.numberOfCaptureGroups).contains(field.group ?? min(1, regex.numberOfCaptureGroups)) else { throw ReaderError.invalidRule("Invalid extraction regex or capture group.") }
                } else if field.group != nil { throw ReaderError.invalidRule("Capture groups require a regex.") }
                if let path = field.queryPath {
                    guard extraction.format.isJSON, path.range(of: #"^[A-Za-z_$][A-Za-z0-9_$]*(\.[A-Za-z0-9_$]+)*$"#, options: .regularExpression) != nil else { throw ReaderError.invalidRule("Query parameters require a JSON object path.") }
                }
            }
            if let rendering = extraction.rendering {
                guard extraction.format.isRendered else { throw ReaderError.invalidRule("Rendering options require a rendered format.") }
                if let function = rendering.captureFunction {
                    guard function.count <= 256, function.range(of: #"^[A-Za-z_$][A-Za-z0-9_$]*(\.[A-Za-z_$][A-Za-z0-9_$]*)*$"#, options: .regularExpression) != nil,
                          !function.split(separator: ".").contains(where: { ["__proto__", "prototype", "constructor"].contains(String($0)) }) else { throw ReaderError.invalidRule("Capture must name a function using a simple dotted path.") }
                }
                if let xpath = rendering.readyImageXPath {
                    guard xpath.count <= 2048, let compiled = xmlXPathCompile(xpath) else { throw ReaderError.invalidRule("Invalid image readiness XPath.") }
                    xmlXPathFreeCompExpr(compiled)
                }
            }
            if extraction.format == .renderedJSON {
                guard extraction.rendering?.captureFunction != nil, extraction.rendering?.readyImageXPath != nil else { throw ReaderError.invalidRule("Rendered JSON needs a capture function and an image readiness XPath.") }
            }
        }
        guard (processors ?? []).allSatisfy({ ["identity", "marginAlign", "spreadDetect", "layout"].contains($0) }) else { throw ReaderError.invalidRule("Unknown page processor.") }
        if let template = searchURLTemplate {
            guard template.contains("{query}"), let url = URL(string: template.replacingOccurrences(of: "{query}", with: "test")), permits(url) else { throw ReaderError.invalidRule("Search endpoint must use an allowed host and {query}.") }
        }
    }
    public func searchURL(query: String) -> URL? {
        var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: "-._~")
        guard let template = searchURLTemplate, let escaped = query.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: template.replacingOccurrences(of: "{query}", with: escaped))
    }
    public static func decode(_ data: Data) throws -> SiteRule {
        guard data.count <= 128 * 1024 else { throw ReaderError.tooLarge }
        // Unknown fields are rejected: secret-bearing headers/scripts cannot hide in an export.
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let supported: Set<String> = ["schemaVersion", "id", "name", "version", "allowedHosts", "matchers", "extractors", "searchURLTemplate", "processors"]
        guard Set(json.keys).isSubset(of: supported) else { throw ReaderError.invalidRule("Unsupported fields (scripts and request credentials are not allowed).") }
        for extractor in (json["extractors"] as? [String: [String: Any]] ?? [:]).values {
            guard Set(extractor.keys).isSubset(of: ["format", "fields", "rendering", "variables"]) else { throw ReaderError.invalidRule("Unsupported extractor options.") }
            let fields = Array((extractor["fields"] as? [String: [String: Any]] ?? [:]).values) + Array((extractor["variables"] as? [String: [String: Any]] ?? [:]).values)
            for field in fields {
                guard Set(field.keys).isSubset(of: ["path", "read", "fallback", "urlTemplate", "queryPath", "regex", "group", "reverse"]) else { throw ReaderError.invalidRule("Unsupported field options.") }
            }
            if let rendering = extractor["rendering"] as? [String: Any], !Set(rendering.keys).isSubset(of: ["contentMode", "captureFunction", "readyImageXPath"]) { throw ReaderError.invalidRule("Unsupported rendering options; scripts are not allowed.") }
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
        guard Set(rules.map(\.id)).count == rules.count else { throw ReaderError.invalidRule("Duplicate rule IDs.") }
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
