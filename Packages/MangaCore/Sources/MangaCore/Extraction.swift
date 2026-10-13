import Foundation
@preconcurrency import libxml2

private struct Selection {
    let value: String
    let title: String
    var node: xmlNodePtr? = nil
    var json: Any? = nil
}

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
    func contains(_ xpath: String) throws -> Bool {
        guard let context = xmlXPathNewContext(document) else { throw ReaderError.invalidResponse }
        defer { xmlXPathFreeContext(context) }
        guard let result = xmlXPathEvalExpression(xpath, context) else { throw ReaderError.invalidResponse }
        defer { xmlXPathFreeObject(result) }
        return (result.pointee.nodesetval?.pointee.nodeNr ?? 0) > 0
    }
    func values(_ field: Field, relativeTo node: xmlNodePtr? = nil, container: Bool = false) throws -> [Selection] {
        guard let context = xmlXPathNewContext(document) else { throw ReaderError.extraction(String(localized: "Could not create XPath context.", bundle: .module)) }
        defer { xmlXPathFreeContext(context) }
        if let node { context.pointee.node = node }
        guard let result = xmlXPathEvalExpression(field.path, context) else { throw ReaderError.extraction(String(localized: "Invalid XPath.", bundle: .module)) }
        defer { xmlXPathFreeObject(result) }
        func string(_ pointer: UnsafeMutablePointer<xmlChar>?) -> String {
            guard let pointer else { return "" }; defer { xmlFree(pointer) }
            return String(cString: pointer).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if result.pointee.type != XPATH_NODESET {
            let value = string(xmlXPathCastToString(result))
            return value.isEmpty ? [] : [Selection(value: value, title: value, node: node)]
        }
        guard let set = result.pointee.nodesetval, set.pointee.nodeNr > 0 else { return [] }
        return (0..<Int(set.pointee.nodeNr)).compactMap { index in
            guard let node = set.pointee.nodeTab[index] else { return nil }
            let title = string(xmlGetProp(node, "title"))
            let text = string(xmlNodeGetContent(node))
            func read(_ mode: String) -> String {
                mode.hasPrefix("attr:") ? string(xmlGetProp(node, String(mode.dropFirst(5)))) : text
            }
            var value = read(field.read ?? "text")
            if value.isEmpty, let fallback = field.fallback { value = read(fallback) }
            return value.isEmpty && !container ? nil : Selection(value: value, title: title.isEmpty ? text : title, node: node)
        }
    }
}

public struct RuleExtractor: Sendable {
    public init() {}
    public func extract(data: Data, responseURL: URL, key: ObjectKey, kind: ContentKind, rule: SiteRule, sessionURL: URL? = nil) throws -> [ContentObject] {
        guard let spec = rule.extraction(for: kind, at: key.identityURL) else { throw ReaderError.extraction(String(localized: "Missing extractor.", bundle: .module)) }
        let html = spec.format.isJSON ? nil : try HTMLDocument(data: data)
        let json: Any? = spec.format.isJSON ? try JSONSerialization.jsonObject(with: data) : nil
        func nodes(at path: String, from root: Any? = nil) -> [Any] {
            var nodes: [Any] = (root ?? json).map { [$0] } ?? []
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
        func extract(_ field: Field, relativeTo selection: Selection? = nil, container: Bool = false) throws -> [Selection] {
            var entries: [Selection]
            if let html { entries = try html.values(field, relativeTo: selection?.node, container: container) }
            else {
                entries = nodes(at: field.path, from: selection?.json).compactMap { node in
                    if let text = scalar(node) { return Selection(value: text, title: text, json: node) }
                    if let dict = node as? [String: Any] {
                        func read(_ mode: String?) -> String? {
                            scalar(dict[mode?.hasPrefix("attr:") == true ? String(mode!.dropFirst(5)) : "url"])
                        }
                        guard let value = read(field.read) ?? field.fallback.flatMap({ read($0) }) ?? (container ? "" : nil) else { return nil }
                        let title = scalar(nodes(at: field.titlePath ?? "title", from: node).first)
                        return Selection(value: value, title: title ?? value, json: node)
                    }
                    return nil
                }
            }
            if field.reverse == true { entries.reverse() }
            let regex = try field.regex.map { try NSRegularExpression(pattern: $0) }
            return try entries.compactMap { entry in
                var value = entry.value
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
                        let replacement = token == "value" ? selected : token.hasPrefix("vars.") ? variables[String(token.dropFirst(5))] : scalar(nodes(at: token, from: selection?.json).first)
                        guard let replacement else { throw ReaderError.extraction(String(localized: "Missing URL template value: \(token).", bundle: .module)) }
                        value.replaceSubrange(Range(match.range, in: value)!, with: replacement)
                    }
                }
                if let path = field.queryPath {
                    guard let query = nodes(at: path, from: selection?.json).first as? [String: Any], var components = URLComponents(string: value) else { throw ReaderError.extraction(String(localized: "Query parameters must be a JSON object.", bundle: .module)) }
                    let items = try query.keys.sorted().map { key in
                        guard let value = scalar(query[key]) else { throw ReaderError.extraction(String(localized: "Query parameters must be strings or numbers.", bundle: .module)) }
                        return URLQueryItem(name: key, value: value)
                    }
                    components.queryItems = (components.queryItems ?? []) + items
                    guard let rendered = components.string else { throw ReaderError.extraction(String(localized: "Invalid image URL.", bundle: .module)) }; value = rendered
                }
                return Selection(value: value, title: entry.title, node: entry.node, json: entry.json)
            }
        }
        for (name, field) in spec.variables ?? [:] { variables[name] = try extract(field).first?.value }
        func values(_ name: String, fields: [String: Field]? = nil, relativeTo selection: Selection? = nil) throws -> [(String, String)] {
            guard let field = (fields ?? spec.fields)[name] else { return [] }
            return try extract(field, relativeTo: selection).map { ($0.value, $0.title) }
        }
        func first(_ name: String) throws -> String? { try values(name).first?.0 }
        func counter(_ name: String, minimum: Int = 0) throws -> Int? {
            guard spec.fields[name] != nil else { return nil }
            guard let value = try first(name).flatMap(Int.init), (minimum...100_000).contains(value) else { throw ReaderError.invalidResponse }
            return value
        }
        func cleaned(_ values: [String]) -> [String] {
            var seen: Set<String> = []
            return values.compactMap { value in
                let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return !text.isEmpty && seen.insert(text).inserted ? text : nil
            }
        }
        func url(_ string: String) throws -> URL {
            guard let url = URL(string: string, relativeTo: responseURL)?.absoluteURL, rule.permits(url) else { throw ReaderError.blockedHost }
            return try RuleRegistry.normalize(url)
        }
        var children: [ContentObject] = []
        // Documents and links use one typed constructor. Missing relationships stay unknown.
        func create(_ kind: ContentKind, key childKey: ObjectKey, fields: [String: Field], relativeTo selection: Selection? = nil) throws -> [ContentObject] {
            func metadata(_ name: String) throws -> [String] { cleaned(try values(name, fields: fields, relativeTo: selection).map(\.0)) }
            func text(_ name: String) throws -> String? { try metadata(name).first }
            let title = try text("title") ?? selection.map { $0.title.isEmpty ? childKey.identityURL.lastPathComponent : $0.title }
                ?? String(localized: "Untitled", bundle: .module)
            let sourceURL = selection == nil ? responseURL : childKey.identityURL
            switch kind {
            case .manga:
                let cover = try text("coverImage").map { value in
                    PageObject(key: .page(owner: childKey, index: -1), ownerRef: childKey, role: .cover, sourceIndex: nil,
                        imageURL: try url(value), refererURL: responseURL, sessionURL: sessionURL ?? key.identityURL)
                }
                let tags = try metadata("tags")
                let object = MangaObject(key: childKey, sourceURL: sourceURL, title: title,
                    author: try text("author"), summary: try text("summary"), coverPageRef: cover?.key,
                    chapterRefs: selection == nil ? try refs("chapterLinks", expected: .chapter) : nil,
                    rating: try text("rating"), status: try text("status"), tags: tags.isEmpty ? nil : tags,
                    chapterLists: selection == nil ? try chapterLists() : nil)
                return [.manga(object)] + (cover.map { [.page($0)] } ?? [])
            case .directory:
                let items = try fields["mangaLinks"].map { _ in try refs("mangaLinks", expected: .manga, fields: fields, relativeTo: selection) }
                if selection != nil {
                    return [.directory(DirectoryObject(key: childKey, sourceURL: sourceURL, title: title, mangaRefs: items, isPreview: true))]
                }
                let title = rule.browse?.first(where: { (try? RuleRegistry.normalize($0.url)) == childKey.identityURL })?.title ?? title
                let total = try counter("totalCount")
                let end: Bool? = if let strategy = spec.session, strategy.mode != .load {
                    try (total.map { (items?.count ?? 0) >= $0 } ?? false) || (strategy.endXPath.map { try html?.contains($0) ?? false } ?? false)
                } else { nil }
                let by = try refs("sortByLinks", expected: .directory), order = try refs("sortOrderLinks", expected: .directory)
                return [.directory(DirectoryObject(key: childKey, sourceURL: sourceURL, title: title,
                    mangaRefs: items, nextURL: try nextPageURL(), endReached: end, totalCount: total,
                    sortBy: by.isEmpty ? nil : by, sortOrder: order.isEmpty ? nil : order,
                    selectedSortBy: try refs("selectedSortBy", expected: .directory).first?.key,
                    selectedSortOrder: try refs("selectedSortOrder", expected: .directory).first?.key))]
            default: throw ReaderError.invalidResponse
            }
        }
        let registry = try RuleRegistry(rules: [rule])
        func refs(_ name: String, expected: ContentKind, fields: [String: Field]? = nil, relativeTo parent: Selection? = nil) throws -> [ContentReference] {
            guard let field = (fields ?? spec.fields)[name] else { return [] }
            var seen: Set<ObjectKey> = []
            return try extract(field, relativeTo: parent).compactMap { selection in
                let destination = try url(selection.value)
                // Selectors may include other site links; retain only references of the requested kind.
                guard let (_, kind, childKey) = try? registry.match(destination), kind == expected, seen.insert(childKey).inserted else { return nil }
                var label = selection.title.isEmpty ? destination.lastPathComponent : selection.title
                if name == "mangaLinks" || name == "directoryLinks" {
                    let objects = try create(kind, key: childKey, fields: field.fields ?? [:], relativeTo: selection)
                    children += objects; label = objects[0].title
                }
                return ContentReference(key: childKey, title: label)
            }
        }
        func chapterLists() throws -> [ChapterList]? {
            guard let field = spec.fields["chapterLists"], let fields = field.fields else { return nil }
            var seen: Set<String> = []
            return try extract(field, container: true).enumerated().map { index, selection in
                func text(_ name: String) throws -> String? { cleaned(try values(name, fields: fields, relativeTo: selection).map(\.0)).first }
                let id = try text("id") ?? String(index)
                guard seen.insert(id).inserted else { throw ReaderError.invalidResponse }
                return ChapterList(id: id, title: try text("title"), indexTitle: try text("indexTitle"),
                    chapters: try refs("chapterLinks", expected: .chapter, fields: fields, relativeTo: selection))
            }
        }
        func nextPageURL() throws -> URL? {
            guard let pagination = spec.pagination else { return try refs("next", expected: .directory).first?.key.identityURL }
            guard let offset = scalar(nodes(at: pagination.offset).first).flatMap(Int.init), offset >= 0,
                  let limit = scalar(nodes(at: pagination.limit).first).flatMap(Int.init), limit > 0,
                  let total = scalar(nodes(at: pagination.total).first).flatMap(Int.init), total >= 0 else {
                throw ReaderError.extraction(String(localized: "Invalid pagination counters.", bundle: .module))
            }
            let (next, overflow) = offset.addingReportingOverflow(limit)
            guard !overflow else { throw ReaderError.extraction(String(localized: "Invalid pagination counters.", bundle: .module)) }
            guard next < total else { return nil }
            guard var components = URLComponents(url: responseURL, resolvingAgainstBaseURL: true) else { throw ReaderError.invalidResponse }
            components.queryItems = (components.queryItems ?? []).filter { $0.name != pagination.parameter } + [URLQueryItem(name: pagination.parameter, value: String(next))]
            guard let target = components.url, rule.permits(target),
                  let (_, kind, key) = try? RuleRegistry(rules: [rule]).match(target), kind == .directory else { throw ReaderError.invalidResponse }
            return key.identityURL
        }
        let title = try first("title") ?? String(localized: "Untitled", bundle: .module)
        switch kind {
        case .site:
            let directories = try refs("directoryLinks", expected: .directory)
            return [.site(SitePageObject(key: key, sourceURL: responseURL, title: title, directoryRefs: directories))] + children
        case .directory, .manga:
            let objects = try create(kind, key: key, fields: spec.fields)
            return objects + children
        case .chapter:
            let offset = (try counter("pageNumber", minimum: 1) ?? 1) - 1
            let pages = try values("pageImages").enumerated().map { position, entry in
                let index = offset + position
                return PageObject(key: .page(owner: key, index: index), ownerRef: key, sourceIndex: index, imageURL: try url(entry.0), refererURL: responseURL)
            }
            let parent = try refs("mangaLink", expected: .manga).first?.key
            let count = try counter("totalCount") ?? (offset + pages.count)
            guard count >= offset + pages.count, count <= 100_000 else { throw ReaderError.invalidResponse }
            return [.chapter(ChapterObject(key: key, sourceURL: responseURL, title: title, mangaRef: parent,
                pageRefs: (0..<count).map { .page(owner: key, index: $0) }))] + pages.map(ContentObject.page)
        case .page:
            guard let image = try first("image") else { throw ReaderError.extraction(String(localized: "Missing image URL.", bundle: .module)) }
            return [.page(PageObject(key: key, ownerRef: nil, sourceIndex: nil, imageURL: try url(image), refererURL: responseURL))]
        }
    }
}
