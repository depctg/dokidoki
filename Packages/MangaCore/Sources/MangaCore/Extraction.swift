import Foundation
@preconcurrency import libxml2

/// XPath is evaluated without external entities or network access. Each document stays on one task.
private final class HTMLDocument {
    let document: htmlDocPtr
    init(data: Data) throws {
        let options = Int32(HTML_PARSE_RECOVER.rawValue | HTML_PARSE_NOERROR.rawValue | HTML_PARSE_NOWARNING.rawValue | HTML_PARSE_NONET.rawValue)
        guard let doc = data.withUnsafeBytes({ raw in
            htmlReadMemory(raw.bindMemory(to: CChar.self).baseAddress, Int32(data.count), nil, "UTF-8", options)
        }) else { throw ReaderError.extraction(String(localized: "Invalid HTML.", bundle: .module)) }
        document = doc
    }
    deinit { xmlFreeDoc(document) }
    func values(_ field: Field) throws -> [(String, String)] {
        guard let context = xmlXPathNewContext(document) else { throw ReaderError.extraction(String(localized: "Could not create XPath context.", bundle: .module)) }
        defer { xmlXPathFreeContext(context) }
        guard let result = xmlXPathEvalExpression(field.path, context) else { throw ReaderError.extraction(String(localized: "Invalid XPath.", bundle: .module)) }
        defer { xmlXPathFreeObject(result) }
        guard let set = result.pointee.nodesetval, set.pointee.nodeNr > 0 else { return [] }
        func string(_ pointer: UnsafeMutablePointer<xmlChar>?) -> String {
            guard let pointer else { return "" }; defer { xmlFree(pointer) }
            return String(cString: pointer).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return (0..<Int(set.pointee.nodeNr)).compactMap { index in
            guard let node = set.pointee.nodeTab[index] else { return nil }
            let title = string(xmlGetProp(node, "title"))
            let text = string(xmlNodeGetContent(node))
            func read(_ mode: String) -> String {
                mode.hasPrefix("attr:") ? string(xmlGetProp(node, String(mode.dropFirst(5)))) : text
            }
            var value = read(field.read ?? "text")
            if value.isEmpty, let fallback = field.fallback { value = read(fallback) }
            return value.isEmpty ? nil : (value, title.isEmpty ? text : title)
        }
    }
}

public struct RuleExtractor: Sendable {
    public init() {}
    public func extract(data: Data, responseURL: URL, key: ObjectKey, kind: ContentKind, rule: SiteRule) throws -> [ContentObject] {
        guard let spec = rule.extractors[kind.rawValue] else { throw ReaderError.extraction(String(localized: "Missing extractor.", bundle: .module)) }
        let html = spec.format.isJSON ? nil : try HTMLDocument(data: data)
        let json: Any? = spec.format.isJSON ? try JSONSerialization.jsonObject(with: data) : nil
        func nodes(at path: String) -> [Any] {
            var nodes: [Any] = json.map { [$0] } ?? []
            for component in path.split(separator: ".").map(String.init) {
                nodes = nodes.flatMap { node -> [Any] in
                    if component == "*", let array = node as? [Any] { return array }
                    if let dict = node as? [String: Any], let child = dict[component] { return [child] }
                    if let array = node as? [Any], let index = Int(component), array.indices.contains(index) { return [array[index]] }
                    return []
                }
            }
            return nodes
        }
        func scalar(_ node: Any?) -> String? {
            if let string = node as? String { return string }
            if let number = node as? NSNumber { return number.stringValue }
            return nil
        }
        var variables: [String: String] = [:]
        func extract(_ field: Field) throws -> [(String, String)] {
            var entries: [(String, String)]
            if let html { entries = try html.values(field) }
            else {
                entries = nodes(at: field.path).compactMap { node in
                    if let text = scalar(node) { return (text, text) }
                    if let dict = node as? [String: Any], let url = dict["url"] as? String { return (url, dict["title"] as? String ?? url) }
                    return nil
                }
            }
            if field.reverse == true { entries.reverse() }
            let regex = try field.regex.map { try NSRegularExpression(pattern: $0) }
            return try entries.compactMap { entry in
                var value = entry.0
                if let regex {
                    let group = field.group ?? min(1, regex.numberOfCaptureGroups)
                    guard let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
                          group >= 0, group < match.numberOfRanges,
                          let range = Range(match.range(at: group), in: value) else { return nil }
                    value = String(value[range])
                }
                if let template = field.urlTemplate {
                    let expression = try NSRegularExpression(pattern: #"\{([^{}]+)\}"#)
                    let selected = value
                    value = template
                    for match in expression.matches(in: template, range: NSRange(template.startIndex..., in: template)).reversed() {
                        let token = String(template[Range(match.range(at: 1), in: template)!])
                        let replacement = token == "value" ? selected : token.hasPrefix("vars.") ? variables[String(token.dropFirst(5))] : scalar(nodes(at: token).first)
                        guard let replacement else { throw ReaderError.extraction(String(localized: "Missing URL template value: \(token).", bundle: .module)) }
                        value.replaceSubrange(Range(match.range, in: value)!, with: replacement)
                    }
                }
                if let path = field.queryPath {
                    guard let query = nodes(at: path).first as? [String: Any], var components = URLComponents(string: value) else { throw ReaderError.extraction(String(localized: "Query parameters must be a JSON object.", bundle: .module)) }
                    let items = try query.keys.sorted().map { key in
                        guard let value = scalar(query[key]) else { throw ReaderError.extraction(String(localized: "Query parameters must be strings or numbers.", bundle: .module)) }
                        return URLQueryItem(name: key, value: value)
                    }
                    components.queryItems = (components.queryItems ?? []) + items
                    guard let rendered = components.string else { throw ReaderError.extraction(String(localized: "Invalid image URL.", bundle: .module)) }; value = rendered
                }
                return (value, entry.1)
            }
        }
        for (name, field) in spec.variables ?? [:] { variables[name] = try extract(field).first?.0 }
        func values(_ name: String) throws -> [(String, String)] {
            guard let field = spec.fields[name] else { return [] }
            return try extract(field)
        }
        func first(_ name: String) throws -> String? { try values(name).first?.0 }
        func metadata(_ name: String) throws -> [String] {
            var seen: Set<String> = []
            return try values(name).compactMap { value, _ in
                let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return !text.isEmpty && seen.insert(text).inserted ? text : nil
            }
        }
        func url(_ string: String) throws -> URL {
            guard let url = URL(string: string, relativeTo: responseURL)?.absoluteURL, rule.permits(url) else { throw ReaderError.blockedHost }
            return try RuleRegistry.normalize(url)
        }
        func refs(_ name: String, expected: ContentKind) throws -> [ContentReference] {
            let registry = try RuleRegistry(rules: [rule]); var seen: Set<ObjectKey> = []
            return try values(name).compactMap { value, label in
                let destination = try url(value)
                // Selectors may include other site links; retain only references of the requested kind.
                guard let (_, kind, childKey) = try? registry.match(destination), kind == expected, seen.insert(childKey).inserted else { return nil }
                return ContentReference(key: childKey, title: label.isEmpty ? destination.lastPathComponent : label)
            }
        }
        let title = try first("title") ?? String(localized: "Untitled", bundle: .module)
        switch kind {
        case .directory:
            let title = rule.browse?.first(where: { (try? RuleRegistry.normalize($0.url)) == key.identityURL })?.title ?? title
            let by = try refs("sortByLinks", expected: .directory)
            let order = try refs("sortOrderLinks", expected: .directory)
            return [.directory(DirectoryObject(key: key, sourceURL: responseURL, title: title,
                mangaRefs: try refs("mangaLinks", expected: .manga), nextURL: try refs("next", expected: .directory).first?.key.identityURL,
                sortBy: by.isEmpty ? nil : by, sortOrder: order.isEmpty ? nil : order,
                selectedSortBy: try refs("selectedSortBy", expected: .directory).first?.key,
                selectedSortOrder: try refs("selectedSortOrder", expected: .directory).first?.key))]
        case .manga:
            let cover = try first("coverImage").map { value in
                PageObject(key: .page(owner: key, index: -1), ownerRef: key, role: .cover, sourceIndex: nil, imageURL: try url(value), refererURL: responseURL)
            }
            let tags = try metadata("tags")
            let manga = MangaObject(key: key, sourceURL: responseURL, title: title, author: try first("author"), summary: try first("summary"), coverPageRef: cover?.key, chapterRefs: try refs("chapterLinks", expected: .chapter), rating: try metadata("rating").first, status: try metadata("status").first, tags: tags.isEmpty ? nil : tags)
            return [.manga(manga)] + (cover.map { [.page($0)] } ?? [])
        case .chapter:
            let pages = try values("pageImages").enumerated().map { index, entry in
                PageObject(key: .page(owner: key, index: index), ownerRef: key, sourceIndex: index, imageURL: try url(entry.0), refererURL: responseURL)
            }
            let parent = try refs("mangaLink", expected: .manga).first?.key
            return [.chapter(ChapterObject(key: key, sourceURL: responseURL, title: title, mangaRef: parent, pageRefs: pages.map(\.key)))] + pages.map(ContentObject.page)
        case .page:
            guard let image = try first("image") else { throw ReaderError.extraction(String(localized: "Missing image URL.", bundle: .module)) }
            return [.page(PageObject(key: key, ownerRef: nil, sourceIndex: nil, imageURL: try url(image), refererURL: responseURL))]
        }
    }
}
