import Foundation
import CoreGraphics
import ImageIO

public actor ImageLoader {
    private let client: HTTPClient
    public init(client: HTTPClient = HTTPClient()) { self.client = client }
    public func image(for page: PageObject, rule: SiteRule, maxPixel: Int = 1800) async throws -> CGImage {
        let data: Data
        if let fixture = try DemoContent.response(for: page.imageURL) { data = fixture.data }
        else { data = try await client.download(page.imageURL, rule: rule, referer: page.refererURL, limit: 24 * 1024 * 1024).data }
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw ReaderError.extraction("The image format could not be decoded.") }
        return image
    }
}
