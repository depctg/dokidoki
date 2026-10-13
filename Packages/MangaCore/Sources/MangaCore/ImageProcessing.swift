import Foundation
import CoreGraphics

public enum ImageProcessing {
    /// Downsample before analysis. Only nearly uniform white outer rows/columns are trimmed,
    /// at most 10% per edge. General margin trimming retains a safety border; a confirmed join
    /// can remove the measured white seam. Dark/uncertain borders stay intact.
    public static func analyze(_ image: CGImage) -> ImageAnalysis {
        // More horizontal precision keeps the joined seam within a few source pixels; <= 1 MiB.
        let width = min(1024, image.width)
        let height = min(256, image.height)
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
        // Allow faint JPEG ringing in otherwise white binding margins.
        func whiteColumn(_ x: Int) -> Bool { (0..<height).allSatisfy { luminance(x, $0) > 0.96 } }
        func whiteRow(_ y: Int) -> Bool { (0..<width).allSatisfy { luminance($0, y) > 0.975 } }
        var left = 0, right = 0, top = 0, bottom = 0
        while left < width / 10 && whiteColumn(left) { left += 1 }
        while right < width / 10 && whiteColumn(width - right - 1) { right += 1 }
        while top < height / 10 && whiteRow(top) { top += 1 }
        while bottom < height / 10 && whiteRow(height - bottom - 1) { bottom += 1 }
        let seam = CGRect(x: Double(left) / Double(width), y: 0,
                          width: 1 - Double(left + right) / Double(width), height: 1)
        func column(_ x: Int) -> [Double] {
            (0..<64).flatMap { sample in
                let y = min(height - 1, (sample * 2 + 1) * height / 128)
                let offset = (y * width + x) * 4
                return (0..<3).map { Double(pixels[offset + $0]) / 255 }
            }
        }
        func edge(_ x: Int, inward: Int) -> [Double] {
            // Reaching the scan limit in blank space supplies no artwork evidence.
            guard !whiteColumn(x) else { return [] }
            let boundary = column(x)
            let interior = column(min(width - 1, max(0, x + inward * max(2, width / 32))))
            // Repeated panel frames can match perfectly between unrelated pages. A frame's
            // abrupt change to the interior is not continuous artwork at a cut.
            let inwardDifference = zip(boundary, interior).reduce(0.0) { $0 + pow($1.0 - $1.1, 2) } / Double(boundary.count)
            return inwardDifference < 0.04 ? boundary : []
        }
        let leftEdge = edge(left, inward: 1), rightEdge = edge(width - right - 1, inward: -1)
        left = max(0, left - 2); right = max(0, right - 2); top = max(0, top - 2); bottom = max(0, bottom - 2)
        let crop = CGRect(x: Double(left) / Double(width), y: Double(top) / Double(height), width: 1 - Double(left + right) / Double(width), height: 1 - Double(top + bottom) / Double(height))
        let central = (0..<height).map { luminance(width / 2, $0) }
        let gutterOffset = max(1, width * 5 / 96)
        let gutter = central.filter { $0 > 0.97 }.count > height * 9 / 10 &&
            (0..<height).filter { luminance(max(0, width / 2 - gutterOffset), $0) < 0.85 || luminance(min(width - 1, width / 2 + gutterOffset), $0) < 0.85 }.count > height / 3
        return ImageAnalysis(width: image.width, height: image.height, contentBounds: crop, centerGutter: gutter,
                             leftEdge: leftEdge, rightEdge: rightEdge, seamBounds: seam)
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
