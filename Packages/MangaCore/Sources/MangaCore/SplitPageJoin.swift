import Foundation
import CoreGraphics

/// Adjacent left/right halves only. Boundary color SSD follows Cho, Avidan & Freeman (CVPR 2010),
/// adapted to sampled RGB rather than normalized Lab. See docs/IMAGE_PROCESSING.md for limits.
enum SplitPageJoin {
    static func matches(_ first: ImageAnalysis?, _ second: ImageAnalysis?, direction: ReadingDirection) -> Bool {
        guard let a = first, let b = second, a.seamBounds != nil, b.seamBounds != nil,
              a.aspectRatio < 0.9, b.aspectRatio < 0.9,
              abs(Double(a.height) / Double(max(1, b.height)) - 1) < 0.08 else { return false }
        let edgeA = direction == .rightToLeft ? a.leftEdge : a.rightEdge
        let edgeB = direction == .rightToLeft ? b.rightEdge : b.leftEdge
        guard edgeA.count == 192, edgeB.count == edgeA.count,
              informative(edgeA), informative(edgeB) else { return false }
        let squaredDifference = zip(edgeA, edgeB).reduce(0.0) { $0 + pow($1.0 - $1.1, 2) } / Double(edgeA.count)
        return squaredDifference < 0.0025
    }

    private static func informative(_ edge: [Double]) -> Bool {
        // Spatial variance per channel rejects uniform colored borders too. Several transitions
        // are required: a plain panel frame with white top/bottom margins is not a split spread.
        var variance = 0.0
        for channel in 0..<3 {
            let values = stride(from: channel, to: edge.count, by: 3).map { edge[$0] }
            let mean = values.reduce(0, +) / Double(values.count)
            variance += values.reduce(0) { $0 + pow($1 - mean, 2) } / Double(values.count * 3)
        }
        let transitions = (1..<64).filter { row in
            (0..<3).contains { abs(edge[row * 3 + $0] - edge[(row - 1) * 3 + $0]) > 0.06 }
        }.count
        return variance > 0.012 && transitions >= 6
    }

    static func removingSeam(from regions: [PageRegion], analysis: [ObjectKey: ImageAnalysis]) -> [PageRegion] {
        guard regions.count == 2, let left = analysis[regions[0].sourcePage]?.seamBounds,
              let right = analysis[regions[1].sourcePage]?.seamBounds else { return regions }
        var result = alignVertically(regions)
        result[0].normalizedCrop.size.width = left.maxX - result[0].normalizedCrop.minX
        let end = result[1].normalizedCrop.maxX
        result[1].normalizedCrop.origin.x = right.minX
        result[1].normalizedCrop.size.width = end - right.minX
        return result
    }

    static func alignVertically(_ regions: [PageRegion]) -> [PageRegion] {
        guard regions.count == 2 else { return regions }
        var result = regions
        // A shared extent is also required when an imported recipe trims after joining.
        let top = min(regions[0].normalizedCrop.minY, regions[1].normalizedCrop.minY)
        let bottom = max(regions[0].normalizedCrop.maxY, regions[1].normalizedCrop.maxY)
        for index in result.indices {
            result[index].normalizedCrop.origin.y = top
            result[index].normalizedCrop.size.height = bottom - top
        }
        return result
    }
}
