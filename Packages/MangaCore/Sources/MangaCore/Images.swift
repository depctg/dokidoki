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
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
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
            try? FileManager.default.removeItem(at: file)
            throw ReaderError.extraction(String(localized: "The image format could not be decoded. Retry to fetch a new copy.", bundle: .module))
        }
        if generation == currentGeneration {
            memory.setObject(image, forKey: memoryKey, cost: image.bytesPerRow * image.height)
            if !FileManager.default.fileExists(atPath: file.path), data.count <= diskLimit {
                try? data.write(to: file, options: .atomic)
                trimDisk()
            }
        }
        return image
    }
    public func clear() {
        generation += 1; memory.removeAllObjects()
        for file in entries() { try? FileManager.default.removeItem(at: file.url) }
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
        for file in files where size > diskLimit { try? FileManager.default.removeItem(at: file.url); size -= file.size }
    }
}

public enum ImageProcessing {
    /// Downsample before analysis. Only nearly uniform white outer rows/columns are trimmed,
    /// at most 10% per edge, retaining a two-pixel safety border. Dark/uncertain borders stay intact.
    public static func analyze(_ image: CGImage) -> ImageAnalysis {
        let width = 96
        let height = min(192, max(32, Int(Double(image.height) / Double(image.width) * Double(width))))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height)); return true
        }
        guard drawn else { return ImageAnalysis(width: image.width, height: image.height) }
        func luminance(_ x: Int, _ y: Int) -> Double {
            let index = (y * width + x) * 4
            return (Double(pixels[index]) + Double(pixels[index + 1]) + Double(pixels[index + 2])) / (3 * 255)
        }
        func whiteColumn(_ x: Int) -> Bool { (0..<height).allSatisfy { luminance(x, $0) > 0.975 } }
        func whiteRow(_ y: Int) -> Bool { (0..<width).allSatisfy { luminance($0, y) > 0.975 } }
        var left = 0, right = 0, top = 0, bottom = 0
        while left < width / 10 && whiteColumn(left) { left += 1 }
        while right < width / 10 && whiteColumn(width - right - 1) { right += 1 }
        while top < height / 10 && whiteRow(top) { top += 1 }
        while bottom < height / 10 && whiteRow(height - bottom - 1) { bottom += 1 }
        left = max(0, left - 2); right = max(0, right - 2); top = max(0, top - 2); bottom = max(0, bottom - 2)
        let crop = CGRect(x: Double(left) / Double(width), y: Double(top) / Double(height), width: 1 - Double(left + right) / Double(width), height: 1 - Double(top + bottom) / Double(height))
        let central = (0..<height).map { luminance(width / 2, $0) }
        let gutter = central.filter { $0 > 0.97 }.count > height * 9 / 10 &&
            (0..<height).filter { luminance(width / 2 - 5, $0) < 0.85 || luminance(width / 2 + 5, $0) < 0.85 }.count > height / 3
        let leftEdge = (0..<32).map { luminance(1, min(height - 1, $0 * height / 32)) }
        let rightEdge = (0..<32).map { luminance(width - 2, min(height - 1, $0 * height / 32)) }
        return ImageAnalysis(width: image.width, height: image.height, contentBounds: crop, centerGutter: gutter, leftEdge: leftEdge, rightEdge: rightEdge)
    }
    /// Core Graphics crops source images and composes facing pages in visual left-to-right order.
    public static func render(_ page: DisplayPage, images: [ObjectKey: CGImage]) -> CGImage? {
        let pieces = page.regions.compactMap { region -> CGImage? in
            guard let image = images[region.sourcePage] else { return nil }
            let r = region.normalizedCrop
            let rect = CGRect(x: r.minX * Double(image.width), y: r.minY * Double(image.height), width: r.width * Double(image.width), height: r.height * Double(image.height)).integral
            return image.cropping(to: rect)
        }
        guard pieces.count == page.regions.count, let first = pieces.first else { return nil }
        if pieces.count == 1 { return first }
        let aspect = pieces.reduce(0.0) { $0 + Double($1.width) / Double($1.height) }
        let height = min(1800, Int(3600 / max(1, aspect)))
        let width = max(1, Int(Double(height) * aspect))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        var x = 0.0
        for image in pieces {
            let w = Double(height) * Double(image.width) / Double(image.height)
            context.draw(image, in: CGRect(x: x, y: 0, width: w, height: Double(height))); x += w
        }
        return context.makeImage()
    }
}
