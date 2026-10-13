import Foundation
import MangaCore

@main struct MangaProbe {
    static func main() async throws {
        let store = try ObjectStore()
        let repository = try ObjectRepository(store: store, rules: DemoContent.bundledRules())
        let url = CommandLine.arguments.dropFirst().first.flatMap(URL.init(string:)) ?? DemoContent.directoryURL
        let key = try await repository.key(for: url)
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
    }
}
