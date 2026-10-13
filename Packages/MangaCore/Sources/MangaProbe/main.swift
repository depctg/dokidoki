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
        #if os(macOS)
        if CommandLine.arguments.contains("--rendered") { NSApplication.shared.setActivationPolicy(.prohibited) }
        #endif
        let store = try ObjectStore()
        let fetcher: any SourceFetcher = CommandLine.arguments.contains("--rendered") ? RenderedSourceFetcher() : DefaultSourceFetcher()
        let repository = try ObjectRepository(store: store, rules: DemoContent.bundledRules(), fetcher: fetcher)
        let url = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("--") }).flatMap(URL.init(string:)) ?? DemoContent.directoryURL
        let key = try await repository.key(for: url)
        if CommandLine.arguments.contains("--diagnostics") {
            let rule = try await repository.rule(for: key)
            let kind = try RuleRegistry(rules: [rule]).match(url).1
            let response = try await fetcher.fetch(url, rule: rule, kind: kind)
            let html = String(decoding: response.data, as: UTF8.self)
            let regex = try NSRegularExpression(pattern: "https?://([^/\\\" ]+)")
            let hosts = Set(regex.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap { Range($0.range(at: 1), in: html).map { String(html[$0]) } })
            print("Rendered hosts: \(hosts.sorted().joined(separator: ", "))")
            return
        }
        let object = try await repository.resolve(key)
        print("\(object.kind.rawValue): \(object.title)")
        if case .directory(let directory) = object {
            print("\(directory.mangaRefs.count) manga references")
            if url == DemoContent.directoryURL, let ref = directory.mangaRefs.first,
               case .manga(let manga) = try await repository.resolve(ref.key), let chapter = manga.chapterRefs.first,
               case .chapter(let chapter) = try await repository.resolve(chapter.key), let page = chapter.pageRefs.first,
               case .page(let page) = try await repository.resolve(page) {
                print("\(manga.title) → \(chapter.title) → \(chapter.pageRefs.count) pages; first image: \(page.imageURL.lastPathComponent)")
            }
        }
        if case .manga(let manga) = object { print("\(manga.chapterRefs.count) chapters; cover: \(manga.coverPageRef != nil)") }
        if case .chapter(let chapter) = object {
            print("\(chapter.pageRefs.count) pages")
            if let key = chapter.pageRefs.first, case .page(let page) = try await repository.resolve(key) {
                let image = try await ImageLoader().image(for: page, rule: repository.rule(for: key))
                print("First image decoded: \(image.width) × \(image.height)")
            }
        }
    }
}
