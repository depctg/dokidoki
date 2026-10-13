import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Testing
@testable import MangaCore

struct SplitPageJoinTests {
    private let owner = ObjectKey(ruleID: "fixture", identityURL: URL(string: "https://reader.example/chapter")!)
    private var leftKey: ObjectKey { .page(owner: owner, index: 0) }
    private var rightKey: ObjectKey { .page(owner: owner, index: 1) }

    @Test func paddedHalvesJoinInBothDirectionsAndModes() async throws {
        let left = try half(right: false, padding: 12), right = try half(right: true, padding: 20)
        let analyses = [leftKey: ImageProcessing.analyze(left), rightKey: ImageProcessing.analyze(right)]
        let pipeline = try PagePipeline()
        for direction in ReadingDirection.allCases {
            for mode in ReadingMode.allCases {
                var preferences = ReaderPreferences()
                preferences.direction = direction; preferences.mode = mode; preferences.facingPages = false
                let keys = direction == .rightToLeft ? [rightKey, leftKey] : [leftKey, rightKey]
                var context = ReaderContext(size: CGSize(width: 390, height: 800), preferences: preferences, analysis: analyses)
                let plan = try #require(await pipeline.plan(keys, context: context).first)
                #expect(plan.sourcePageKeys == [leftKey, rightKey])
                #expect(plan.intentionalSpread)
                #expect(abs(plan.regions[0].normalizedCrop.maxX * Double(left.width) - 280) < 0.01)
                #expect(abs(plan.regions[1].normalizedCrop.minX * Double(right.width) - 20) < 0.01)
                #expect(plan.regions.allSatisfy { $0.normalizedCrop.minY == 0 && $0.normalizedCrop.height == 1 })
                let rendered = try #require(ImageProcessing.render(plan, images: [leftKey: left, rightKey: right]))
                #expect(abs(Double(rendered.width) / Double(rendered.height) - 560.0 / 800) < 0.003)
                // The actual composed center must contain artwork, not white padding.
                let composed = ImageProcessing.analyze(rendered)
                #expect(!composed.centerGutter)
                #expect(PagePipeline.index(for: rightKey, fraction: 0.4, in: [plan]) == 0)
                context.preferences.detectSpreads = false
                #expect(await pipeline.plan(keys, context: context).count == 2)
                context.preferences.detectSpreads = true; context.overrides[keys[0]] = .keep
                #expect(await pipeline.plan(keys, context: context).count == 2)
                context.overrides = [keys[1]: .keep]
                #expect(await pipeline.plan(keys, context: context).count == 2)
            }
        }
    }

    @Test func compressionIsToleratedButAmbiguousBordersAndUnrelatedArtworkStaySeparate() throws {
        let left = ImageProcessing.analyze(try half(right: false, padding: 12))
        let originalRight = try half(right: true, padding: 20)
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, originalRight, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        let source = try #require(CGImageSourceCreateWithData(data, nil))
        let compressed = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(SplitPageJoin.matches(left, ImageProcessing.analyze(compressed), direction: .leftToRight))
        let other = ImageProcessing.analyze(try half(right: true, padding: 20, offset: 150))
        #expect(!SplitPageJoin.matches(left, other, direction: .leftToRight))
        #expect(!SplitPageJoin.matches(left, ImageProcessing.analyze(originalRight), direction: .rightToLeft))
        for kind in 0..<4 {
            let image = try bitmap(width: 300, height: 800) { _, y in
                switch kind {
                case 0: return [255, 255, 255] // Blank white.
                case 1: return [0, 0, 0] // Blank black.
                case 2: return [210, 45, 80] // Flat color is not spatial variation.
                default: return y < 60 || y > 740 ? [255, 255, 255] : [0, 0, 0] // Panel border.
                }
            }
            let analysis = ImageProcessing.analyze(image)
            #expect(!SplitPageJoin.matches(analysis, analysis, direction: .leftToRight))
        }
        let oversizedMargin = ImageProcessing.analyze(try half(right: true, padding: 80))
        #expect(!SplitPageJoin.matches(left, oversizedMargin, direction: .leftToRight))
        // Same four-panel frames, different interiors: matching black/white border runs
        // must not join ordinary manga pages, even though they have many transitions.
        var panels: [ImageAnalysis] = []
        for color: [UInt8] in [[255, 255, 255], [40, 110, 200], [220, 90, 50]] {
            let page = try bitmap(width: 600, height: 900) { x, y in
                guard x >= 30, x < 570, y >= 30, (y - 30) % 220 < 180 else { return [255, 255, 255] }
                if x < 34 || x >= 566 || (y - 30) % 220 < 4 || (y - 30) % 220 >= 176 { return [0, 0, 0] }
                return color
            }
            panels.append(ImageProcessing.analyze(page))
        }
        for a in panels { for b in panels { #expect(!SplitPageJoin.matches(a, b, direction: .leftToRight)) } }
    }

    @Test func unpaddedHalvesAndOldAnalysisRemainSafe() async throws {
        let a = ImageProcessing.analyze(try half(right: false, padding: 0))
        let b = ImageProcessing.analyze(try half(right: true, padding: 0))
        #expect(SplitPageJoin.matches(a, b, direction: .leftToRight))
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(a)) as! [String: Any]
        legacy.removeValue(forKey: "seamBounds")
        let restored = try JSONDecoder().decode(ImageAnalysis.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(!SplitPageJoin.matches(restored, b, direction: .leftToRight))
        let tiny = ImageProcessing.analyze(try bitmap(width: 1, height: 1) { _, _ in [255, 255, 255] })
        #expect(tiny.contentBounds.width > 0)
    }

    @Test func bundledSplitFixtureLoadsAndJoinsThroughCore() async throws {
        let repository = try ObjectRepository(store: ObjectStore(), rules: DemoContent.bundledRules())
        let key = try await repository.key(for: URL(string: "https://demo.mangaviewer.local/chapter/rejoined")!)
        guard case .chapter(let chapter) = try await key.load(using: repository) else { Issue.record("Missing chapter"); return }
        let pages = try await chapter.pages(using: repository)
        var analysis: [ObjectKey: ImageAnalysis] = [:]
        for page in pages { analysis[page.key] = ImageProcessing.analyze(try await page.image(using: repository)) }
        let plans = await (try PagePipeline()).plan(pages.map(\.key), context: ReaderContext(size: CGSize(width: 390, height: 800), analysis: analysis))
        #expect(plans.count == 1)
        #expect(plans.first?.sourcePageKeys == pages.map(\.key).reversed())
    }

    private func half(right: Bool, padding: Int, offset: Int = 0) throws -> CGImage {
        try bitmap(width: 280 + padding, height: 800) { x, y in
            if right ? x < padding : x >= 280 { return [255, 255, 255] }
            let sourceX = right ? x - padding + 280 : x
            let phase = Double(y + offset)
            return [UInt8(40 + 80 * (sin(phase * 0.05) + 1) / 2 + Double(sourceX) * 0.07),
                    UInt8(30 + 150 * (cos(phase * 0.033) + 1) / 2),
                    UInt8(70 + 70 * (sin(phase * 0.017) + 1) / 2)]
        }
    }
    private func bitmap(width: Int, height: Int, color: (Int, Int) -> [UInt8]) throws -> CGImage {
        var bytes = [UInt8](); bytes.reserveCapacity(width * height * 4)
        for y in 0..<height { for x in 0..<width { bytes += color(x, y) + [255] } }
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        return try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }
}
