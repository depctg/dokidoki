import Foundation

/// Retention is a cache concern. Objects carry neither TTLs nor cache priority.
/// Within each priority, metadata and on-disk images evict least-recently-used data.
enum CachePolicy {
    static let metadataBytes = 64 * 1024 * 1024
    static let imageBytes = 512 * 1024 * 1024
    static let decodedPageBytes = 80 * 1024 * 1024
    static let decodedCoverBytes = 32 * 1024 * 1024

    static func priority(_ object: ContentObject) -> Int {
        switch object {
        case .site, .directory: 0
        case .manga: 2
        case .chapter: 1
        case .page(let page): page.role == .cover ? 2 : 1
        }
    }
}

/// Passive, bounded lookup of bytes already obtained by a logical session.
/// Misses never initiate work: RequestSender selects the appropriate transport.
struct SessionResources {
    private struct Entry { let response: SourceResponse; var used: Date }
    private struct Key: Hashable { let url: URL; let referer: URL? }
    private var entries: [Key: Entry] = [:]
    private(set) var used = Date()
    private let limit = 24 * 1024 * 1024
    mutating func response(for url: URL, referer: URL? = nil) -> SourceResponse? {
        let url = Key(url: url, referer: referer)
        guard var entry = entries[url] else { return nil }
        used = Date(); entry.used = used; entries[url] = entry
        return entry.response
    }
    mutating func remove(_ url: URL, referer: URL?) { entries[Key(url: url, referer: referer)] = nil }
    mutating func insert(_ response: SourceResponse, for url: URL, referer: URL? = nil) {
        let url = Key(url: url, referer: referer)
        guard response.data.count <= limit else { return }
        used = Date(); entries[url] = Entry(response: response, used: used)
        var bytes = entries.values.reduce(0) { $0 + $1.response.data.count }
        for (key, entry) in entries.sorted(by: { $0.value.used < $1.value.used }) where bytes > limit {
            entries[key] = nil; bytes -= entry.response.data.count
        }
    }
}
