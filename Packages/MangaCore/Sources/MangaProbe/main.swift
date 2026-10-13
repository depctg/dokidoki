import Foundation
import MangaCore
#if os(macOS)
import AppKit
#endif

@main struct MangaProbe {
    @MainActor static func main() async {
        do { try await run() }
        catch { print("Probe failed: \(error.localizedDescription)"); exit(1) }
    }
    @MainActor static func run() async throws {
        var arguments = Array(CommandLine.arguments.dropFirst())
        var itemRange: Range<Int>?
        if let index = arguments.firstIndex(of: "--range") {
            guard arguments.indices.contains(index + 1) else { throw ReaderError.invalidResponse }
            let parts = arguments[index + 1].split(separator: ":").compactMap { Int($0) }
            guard parts.count == 2, parts[0] >= 0, parts[1] > 0, parts[0] <= 100_000 - parts[1] else { throw ReaderError.invalidResponse }
            itemRange = parts[0]..<(parts[0] + parts[1]); arguments.removeSubrange(index...index + 1)
        }
        var snapshotPath: String?
        if let index = arguments.firstIndex(of: "--snapshot") {
            guard arguments.indices.contains(index + 1) else { throw ReaderError.invalidRule("--snapshot requires an output file") }
            snapshotPath = arguments[index + 1]
            arguments.removeSubrange(index...index + 1)
        }
        var rules = try DemoContent.bundledRules()
        if let index = arguments.firstIndex(of: "--rule") {
            guard arguments.indices.contains(index + 1) else { throw ReaderError.invalidRule("Usage: manga-probe [--rule file.json] [--rendered] [--diagnostics] [URL]") }
            let rule = try SiteRule.decode(Data(contentsOf: URL(fileURLWithPath: arguments[index + 1])))
            rules.removeAll { $0.id == rule.id }; rules.append(rule)
            arguments.removeSubrange(index...index + 1)
        }
        #if os(macOS)
        if CommandLine.arguments.contains("--rendered") { NSApplication.shared.setActivationPolicy(.prohibited) }
        #endif
        let store = try ObjectStore()
        let fetcher: any SourceFetcher = CommandLine.arguments.contains("--rendered") ? RenderedSourceFetcher() : DefaultSourceFetcher()
        let sender = RequestSender(fetcher: fetcher)
        let repository = try ObjectRepository(store: store, rules: rules, sender: sender)
        let backgroundLoading = !arguments.contains("--no-background")
        try await repository.setBackgroundLoading(backgroundLoading)
        let url = arguments.first(where: { !$0.hasPrefix("--") }).flatMap(URL.init(string:)) ?? DemoContent.directoryURL
        let key = try await repository.key(for: url)
        if arguments.contains("--diagnostics") || snapshotPath != nil {
            let rule = try await repository.rule(for: key)
            let kind = try RuleRegistry(rules: [rule]).match(url).1
            let response = try await sender.send(.source(key, kind: kind, rule: rule, backgroundLoading: backgroundLoading, load: SourceLoad(range: itemRange)))
            if let snapshotPath {
                try response.data.write(to: URL(fileURLWithPath: snapshotPath), options: .atomic)
                print("Saved source snapshot (\(response.data.count) bytes)")
            }
            let html = String(decoding: response.data, as: UTF8.self)
            let regex = try NSRegularExpression(pattern: "https?://([^/\\\" ]+)")
            let hosts = Set(regex.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap { Range($0.range(at: 1), in: html).map { String(html[$0]) } })
            print("Rendered hosts: \(hosts.sorted().joined(separator: ", "))")
            return
        }
        let object = try await key.load(using: repository)
        print("\(object.kind.rawValue): \(object.title)")
        if case .site(let page) = object {
            let directories = try await page.lists(using: repository)
            print("\(directories.count) directories from one source page")
            for directory in directories {
                print("\(directory.title): \(directory.mangaRefs.count) known items; preview: \(directory.isPreview == true) → \(directory.key.identityURL.absoluteString)")
                if arguments.contains("--previews"), let ref = directory.mangaRefs.first,
                   case .manga(let manga) = try await ref.preview(using: repository), let cover = try await manga.coverPage(using: repository) {
                    let image = try await cover.image(using: repository)
                    print("Preview cover decoded: \(image.width) × \(image.height); chapters unknown: \(manga.chapters == nil)")
                }
            }
        }
        if case .directory(let directory) = object {
            print("\(directory.mangaRefs.count) manga references")
            for (label, options, selected) in [("Sort by", directory.sortBy, directory.selectedSortBy), ("Order", directory.sortOrder, directory.selectedSortOrder)] {
                for option in options ?? [] {
                    print("\(label): \(option.title)\(option.key == selected ? " [selected]" : "") → \(option.key.identityURL.absoluteString)")
                }
            }
            if let next = directory.nextURL { print("Next list page: \(next.absoluteString)") }
            if arguments.contains("--previews") {
                let start = ContinuousClock.now
                var previews: [MangaObject] = []
                for ref in directory.mangaRefs.prefix(8) {
                    if case .manga(let manga) = try await ref.preview(using: repository) { previews.append(manga) }
                }
                print("Previews: \(previews.count); known covers: \(previews.filter { $0.coverPageRef != nil }.count); detail documents still unknown: \(previews.filter { $0.chapters == nil }.count); elapsed: \(start.duration(to: .now))")
                if let first = previews.first, let cover = try await first.coverPage(using: repository) {
                    let image = try await cover.image(using: repository)
                    print("Preview cover decoded: \(image.width) × \(image.height)")
                }
            }
            if url == DemoContent.directoryURL, let ref = directory.mangaRefs.first,
               case .manga(let manga) = try await ref.load(using: repository), let chapter = manga.chapterRefs.first,
               case .chapter(let chapter) = try await chapter.load(using: repository), let page = chapter.pageRefs.first,
               case .page(let page) = try await page.load(using: repository) {
                print("\(manga.title) → \(chapter.title) → \(chapter.pageRefs.count) pages; first image: \(page.imageURL?.lastPathComponent ?? "unresolved")")
            }
        }
        if case .manga(let manga) = object {
            print("\(manga.chapterRefs.count) chapters; cover: \(manga.coverPageRef != nil)")
            if let rating = manga.rating { print("Rating: \(rating)") }
            if let status = manga.status { print("Status: \(status)") }
            if let tags = manga.tags { print("Tags: \(tags.joined(separator: ", "))") }
            if arguments.contains("--references") {
                for chapter in manga.chapterRefs { print("\(chapter.title) → \(chapter.key.identityURL.absoluteString)") }
            }
        }
        if case .chapter(let chapter) = object {
            if let itemRange {
                let pages = try await chapter.load(itemRange, using: repository)
                print("Requested range: \(itemRange); resolved \(pages.count) pages")
                for page in pages { print("Page \((page.sourceIndex ?? 0) + 1): \(page.imageURL?.lastPathComponent ?? "unresolved")") }
                if let page = pages.last {
                    let image = try await page.image(using: repository)
                    print("Requested image decoded: \(image.width) × \(image.height)")
                }
            }
            print("\(chapter.pageRefs.count) pages")
            if let key = chapter.pageRefs.first, case .page(let page) = try await key.load(using: repository) {
                let image = try await page.image(using: repository)
                print("First image decoded: \(image.width) × \(image.height)")
            }
        }
    }
}
