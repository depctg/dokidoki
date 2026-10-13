import Foundation
import CoreGraphics

public enum ReadingMode: String, Codable, Sendable, CaseIterable { case paged = "Paged", scroll = "Scroll" }
public enum ReadingDirection: String, Codable, Sendable, CaseIterable { case rightToLeft = "Right to left", leftToRight = "Left to right" }
public enum SpreadOverride: String, Codable, Sendable, CaseIterable { case automatic = "Automatic", keep = "Keep original", split = "Split", pairWithNext = "Pair with next" }

public struct ReaderPreferences: Codable, Sendable, Equatable {
    public var mode: ReadingMode = .paged
    public var direction: ReadingDirection = .rightToLeft
    public var trimMargins = false
    public var detectSpreads = true
    public var facingPages = true
    public init() {}
}
public struct PageRegion: Codable, Sendable, Equatable {
    public let sourcePage: ObjectKey
    public var normalizedCrop: CGRect
    public init(sourcePage: ObjectKey, normalizedCrop: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)) {
        self.sourcePage = sourcePage; self.normalizedCrop = normalizedCrop
    }
}
public struct DisplayPage: Codable, Sendable, Equatable, Identifiable {
    public var regions: [PageRegion]
    public var intentionalSpread: Bool
    public var id: String { regions.map { "\($0.sourcePage.id):\($0.normalizedCrop)" }.joined(separator: ";") }
    public var sourcePageKeys: [ObjectKey] { regions.map(\.sourcePage) }
    public init(regions: [PageRegion], intentionalSpread: Bool = false) { self.regions = regions; self.intentionalSpread = intentionalSpread }
}
public struct ImageAnalysis: Codable, Sendable {
    public let width: Int
    public let height: Int
    public let contentBounds: CGRect
    public let centerGutter: Bool
    /// RGB triplets sampled along the artwork boundary, after conservative white-border detection.
    public let leftEdge: [Double]
    public let rightEdge: [Double]
    /// Measured horizontal bounds before the margin safety inset; old analysis has no seam evidence.
    public var seamBounds: CGRect? = nil
    public var aspectRatio: Double { Double(width) / Double(max(1, height)) }
    public init(width: Int, height: Int, contentBounds: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1), centerGutter: Bool = false, leftEdge: [Double] = [], rightEdge: [Double] = [], seamBounds: CGRect? = nil) {
        self.width = width; self.height = height; self.contentBounds = contentBounds; self.centerGutter = centerGutter
        self.leftEdge = leftEdge; self.rightEdge = rightEdge
        self.seamBounds = seamBounds
    }
}
public struct ReaderContext: Sendable {
    public var size: CGSize
    public var preferences: ReaderPreferences
    public var analysis: [ObjectKey: ImageAnalysis]
    public var overrides: [ObjectKey: SpreadOverride]
    public init(size: CGSize, preferences: ReaderPreferences = ReaderPreferences(), analysis: [ObjectKey: ImageAnalysis] = [:], overrides: [ObjectKey: SpreadOverride] = [:]) {
        self.size = size; self.preferences = preferences; self.analysis = analysis; self.overrides = overrides
    }
    public var wide: Bool { size.width >= 850 && size.width > size.height * 1.1 }
}
public protocol PageProcessor: Sendable {
    var id: String { get }
    func plan(_ pages: [DisplayPage], context: ReaderContext) async throws -> [DisplayPage]
}
public struct PagePipeline: Sendable {
    private let processors: [any PageProcessor]
    public init(ids: [String] = ["identity", "marginAlign", "spreadDetect", "layout"]) throws {
        processors = try ids.map { id in
            switch id {
            case "identity": return IdentityProcessor() as any PageProcessor
            case "marginAlign": return MarginProcessor() as any PageProcessor
            case "spreadDetect": return SpreadProcessor() as any PageProcessor
            case "layout": return LayoutProcessor() as any PageProcessor
            default: throw ReaderError.invalidRule(String(localized: "Unknown processor: \(id)", bundle: .module))
            }
        }
    }
    public func plan(_ sources: [ObjectKey], context: ReaderContext) async -> [DisplayPage] {
        let original = sources.map { DisplayPage(regions: [PageRegion(sourcePage: $0)]) }
        var result = original
        for processor in processors {
            if Task.isCancelled { return original }
            do { result = try await processor.plan(result, context: context) }
            catch { return original }
        }
        return result.isEmpty && !sources.isEmpty ? original : result
    }
    /// Fraction is relative to the original source, so split halves remain addressable across replans.
    public static func index(for source: ObjectKey?, fraction: Double, in pages: [DisplayPage]) -> Int {
        guard let source else { return 0 }
        let indices = pages.indices.filter { pages[$0].sourcePageKeys.contains(source) }
        guard !indices.isEmpty else { return 0 }
        let safeFraction = fraction.isFinite ? min(1, max(0, fraction)) : 0
        return indices[min(indices.count - 1, Int(safeFraction * Double(indices.count)))]
    }
    public static func fraction(index: Int, withinPage: Double, source: ObjectKey, in pages: [DisplayPage]) -> Double {
        let indices = pages.indices.filter { pages[$0].sourcePageKeys.contains(source) }
        guard let part = indices.firstIndex(of: index) else { return 0 }
        return min(0.999_999, (Double(part) + min(0.999_999, max(0, withinPage))) / Double(indices.count))
    }
}

private struct IdentityProcessor: PageProcessor {
    let id = "identity"
    func plan(_ pages: [DisplayPage], context: ReaderContext) async throws -> [DisplayPage] { pages }
}
private struct MarginProcessor: PageProcessor {
    let id = "marginAlign"
    func plan(_ pages: [DisplayPage], context: ReaderContext) async throws -> [DisplayPage] {
        guard context.preferences.trimMargins else { return pages }
        return pages.map { page in
            var page = page
            page.regions = page.regions.map { region in
                guard let analysis = context.analysis[region.sourcePage] else { return region }
                var region = region; region.normalizedCrop = region.normalizedCrop.intersection(analysis.contentBounds); return region
            }
            // Imported recipes may put marginAlign after spreadDetect; do not offset joined halves.
            if page.intentionalSpread { page.regions = SplitPageJoin.alignVertically(page.regions) }
            return page
        }
    }
}
private struct SpreadProcessor: PageProcessor {
    let id = "spreadDetect"
    func plan(_ pages: [DisplayPage], context: ReaderContext) async throws -> [DisplayPage] {
        var result: [DisplayPage] = []; var index = 0
        while index < pages.count {
            let page = pages[index]; index += 1
            guard let region = page.regions.first, page.regions.count == 1 else { result.append(page); continue }
            let override = context.overrides[region.sourcePage] ?? .automatic
            let analysis = context.analysis[region.sourcePage]
            if override == .keep { result.append(DisplayPage(regions: page.regions, intentionalSpread: true)); continue }
            let wide = (analysis?.aspectRatio ?? 0) > 1.25
            let shouldSplit = override == .split || (override == .automatic && context.preferences.detectSpreads && wide && analysis?.centerGutter == true && !context.wide && context.preferences.mode == .paged)
            if shouldSplit {
                let crop = region.normalizedCrop
                let left = PageRegion(sourcePage: region.sourcePage, normalizedCrop: CGRect(x: crop.minX, y: crop.minY, width: crop.width / 2, height: crop.height))
                let right = PageRegion(sourcePage: region.sourcePage, normalizedCrop: CGRect(x: crop.midX, y: crop.minY, width: crop.width / 2, height: crop.height))
                let halves = context.preferences.direction == .rightToLeft ? [right, left] : [left, right]
                result += halves.map { DisplayPage(regions: [$0], intentionalSpread: true) }; continue
            }
            if index < pages.count, let next = pages[index].regions.first, pages[index].regions.count == 1,
               context.overrides[next.sourcePage, default: .automatic] == .automatic {
                let match = context.preferences.detectSpreads && SplitPageJoin.matches(analysis, context.analysis[next.sourcePage], direction: context.preferences.direction)
                if override == .pairWithNext || match {
                    var regions = context.preferences.direction == .rightToLeft ? [next, region] : [region, next]
                    if match { regions = SplitPageJoin.removingSeam(from: regions, analysis: context.analysis) }
                    result.append(DisplayPage(regions: regions, intentionalSpread: true)); index += 1; continue
                }
            }
            result.append(DisplayPage(regions: page.regions, intentionalSpread: wide))
        }
        return result
    }
}
private struct LayoutProcessor: PageProcessor {
    let id = "layout"
    func plan(_ pages: [DisplayPage], context: ReaderContext) async throws -> [DisplayPage] {
        guard context.wide, context.preferences.mode == .paged, context.preferences.facingPages else { return pages }
        var result: [DisplayPage] = []; var index = 0
        while index < pages.count {
            let first = pages[index]; index += 1
            if !first.intentionalSpread, first.regions.count == 1, index < pages.count,
               !pages[index].intentionalSpread, pages[index].regions.count == 1 {
                let second = pages[index]; index += 1
                result.append(DisplayPage(regions: context.preferences.direction == .rightToLeft ? second.regions + first.regions : first.regions + second.regions))
            } else { result.append(first) }
        }
        return result
    }
}
