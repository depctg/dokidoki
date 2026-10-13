import Foundation
import CoreGraphics
import ImageIO
import CryptoKit

/// Image bytes and decoded images have separate bounded caches. No object/reading state is stored here.
public actor ImageLoader {
    private let sender: RequestSender
    private let memory = NSCache<NSString, CGImage>()
    private let directory: URL
    private let diskLimit: Int
    private var generation = 0
    public init(sender: RequestSender = RequestSender(), directory: URL? = nil, diskLimit: Int = 256 * 1024 * 1024) {
        self.sender = sender; self.diskLimit = max(0, diskLimit)
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("MangaViewer/Images", isDirectory: true)
        memory.totalCostLimit = 96 * 1024 * 1024; memory.countLimit = 24
        do { try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true) }
        catch { ErrorDiagnostics.record(error, operation: .imageCache) }
    }
    public func image(for page: PageObject, rule: SiteRule, maxPixel: Int = 1800) async throws -> CGImage {
        try Task.checkCancellation()
        guard rule.permits(page.imageURL) else { throw ReaderError.blockedHost }
        let maxPixel = min(4096, max(64, maxPixel))
        let digest = SHA256.hash(data: Data("\(rule.id)|\(rule.version)|\(page.imageURL.absoluteString)|\(page.refererURL?.absoluteString ?? "")".utf8)).map { String(format: "%02x", $0) }.joined()
        let memoryKey = "\(digest)-\(maxPixel)" as NSString
        let file = directory.appendingPathComponent(digest).appendingPathExtension("cache")
        if let image = memory.object(forKey: memoryKey) {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
            return image
        }
        let currentGeneration = generation
        let data: Data
        if let cached = try? Data(contentsOf: file), cached.count <= 24 * 1024 * 1024 {
            data = cached
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        } else {
            data = try await sender.send(.image(page, rule: rule)).data
        }
        try Task.checkCancellation()
        if let image = memory.object(forKey: memoryKey) { return image }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else {
            remove(file)
            throw ReaderError.extraction(String(localized: "The image format could not be decoded. Retry to fetch a new copy.", bundle: .module))
        }
        if generation == currentGeneration {
            memory.setObject(image, forKey: memoryKey, cost: image.bytesPerRow * image.height)
            if !FileManager.default.fileExists(atPath: file.path), data.count <= diskLimit {
                do { try data.write(to: file, options: .atomic) }
                catch { ErrorDiagnostics.record(error, operation: .imageCache) }
                trimDisk()
            }
        }
        return image
    }
    public func clear() {
        generation += 1; memory.removeAllObjects()
        for file in entries() { remove(file.url) }
    }
    public func diskUsage() -> Int { entries().reduce(0) { $0 + $1.size } }
    private func entries() -> [(url: URL, size: Int, date: Date)] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey], options: .skipsHiddenFiles)) ?? []
        return urls.filter { $0.pathExtension == "cache" }.map { url in
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return (url, values?.fileSize ?? 0, values?.contentModificationDate ?? .distantPast)
        }
    }
    private func trimDisk() {
        let files = entries().sorted { $0.date < $1.date }; var size = files.reduce(0) { $0 + $1.size }
        for file in files where size > diskLimit { remove(file.url); size -= file.size }
    }
    private func remove(_ file: URL) {
        do { try FileManager.default.removeItem(at: file) }
        catch {
            let failure = error as NSError
            if failure.domain != NSCocoaErrorDomain || failure.code != NSFileNoSuchFileError {
                ErrorDiagnostics.record(error, operation: .imageCache)
            }
        }
    }
}
