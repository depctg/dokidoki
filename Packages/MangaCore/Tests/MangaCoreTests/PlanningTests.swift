import Foundation
import CoreGraphics
import Testing
@testable import MangaCore

struct PlanningTests {
    private let owner = ObjectKey(ruleID: "demo", identityURL: URL(string: "https://demo.mangaviewer.local/chapter/arrival")!)
    private var keys: [ObjectKey] { (0..<4).map { .page(owner: owner, index: $0) } }

    @Test(arguments: [0.5, 0.7, 3.0])
    func initialFitMatchesFinalLayoutAndMinimums(ratio: Double) async throws {
        let pipeline = try PagePipeline(), sources = Array(keys.prefix(2))
        let minimum = CGSize(width: 320, height: 420)
        var context = ReaderContext(size: CGSize(width: 1100, height: 800))
        #expect(await pipeline.fittedSize(sources, source: keys[0], fraction: 0, context: context, minimum: minimum) == nil)
        context.analysis = Dictionary(uniqueKeysWithValues: sources.map { ($0, ImageAnalysis(width: Int(ratio * 1000), height: 1000)) })
        let size = try #require(await pipeline.fittedSize(sources, source: keys[0], fraction: 0, context: context, minimum: minimum))
        #expect(size.width >= minimum.width && size.height >= minimum.height)
        context.size = size
        let displayed = try #require(await pipeline.plan(sources, context: context).first)
        #expect(abs(size.width / size.height - displayed.aspectRatio(analysis: context.analysis)) < 0.0001)
        // Ordinary portraits retain the default facing pair; very tall artwork
        // settles into a single page. Very wide artwork meets the minimum height.
        #expect(displayed.regions.count == (ratio == 0.7 ? 2 : 1))

        context.size = CGSize(width: 600, height: 900)
        context.preferences.facingPages = false
        context.overrides[keys[0]] = .split
        let splitSize = try #require(await pipeline.fittedSize(sources, source: keys[0], fraction: 0.7, context: context, minimum: minimum))
        #expect(abs(splitSize.width / splitSize.height - ratio / 2) < 0.0001)
    }

    @Test func wideSpreadEvidenceAndReadingOrder() async throws {
        let key = keys[0]; let pipeline = try PagePipeline()
        var context = ReaderContext(size: CGSize(width: 390, height: 800), analysis: [key: ImageAnalysis(width: 1600, height: 1000, centerGutter: true)])
        let rtl = await pipeline.plan([key], context: context)
        #expect(rtl.count == 2); #expect(rtl[0].regions[0].normalizedCrop.minX == 0.5)
        context.preferences.direction = .leftToRight
        let ltr = await pipeline.plan([key], context: context)
        #expect(ltr[0].regions[0].normalizedCrop.minX == 0)
        context.analysis[key] = ImageAnalysis(width: 1600, height: 1000)
        #expect(await pipeline.plan([key], context: context).count == 1)
        context.preferences.detectSpreads = false; context.overrides[key] = .split
        #expect(await pipeline.plan([key], context: context).count == 2)
        context.overrides[key] = .keep
        #expect(await pipeline.plan([key], context: context).count == 1)
        context.preferences.detectSpreads = true
        context.analysis[key] = ImageAnalysis(width: 1600, height: 1000, centerGutter: true)
        context.overrides[key] = .pairWithNext
        let explicitPair = await pipeline.plan([key, keys[1]], context: context)
        #expect(explicitPair.count == 1)
        #expect(explicitPair[0].sourcePageKeys.count == 2)
    }
    @Test func adjacentEvidenceAndLayoutPreserveIntentionalPairs() async throws {
        let edge = (0..<64).flatMap { Array(repeating: $0.isMultiple(of: 2) ? 0.15 : 0.85, count: 3) }
        let bounds = CGRect(x: 0, y: 0, width: 1, height: 1)
        var context = ReaderContext(size: CGSize(width: 1200, height: 800))
        context.analysis[keys[0]] = ImageAnalysis(width: 700, height: 1000, leftEdge: edge, rightEdge: [], seamBounds: bounds)
        context.analysis[keys[1]] = ImageAnalysis(width: 700, height: 1000, leftEdge: [], rightEdge: edge, seamBounds: bounds)
        let pages = await (try PagePipeline()).plan(keys, context: context)
        #expect(pages.count == 2)
        #expect(pages[0].intentionalSpread)
        #expect(pages[0].sourcePageKeys == [keys[1], keys[0]])
        #expect(pages[1].sourcePageKeys == [keys[3], keys[2]])
        context.preferences.facingPages = false
        context.analysis[keys[0]] = ImageAnalysis(width: 700, height: 1000, leftEdge: Array(repeating: 1, count: 32))
        context.analysis[keys[1]] = ImageAnalysis(width: 700, height: 1000, rightEdge: Array(repeating: 1, count: 32))
        #expect(await (try PagePipeline()).plan(keys, context: context).count == 4)
        context.overrides[keys[0]] = .pairWithNext
        #expect(await (try PagePipeline()).plan(keys, context: context).count == 3)

        // Imported recipes can trim after joining; differing blank margins must not shift halves.
        context.preferences.trimMargins = true
        context.analysis[keys[0]] = ImageAnalysis(width: 700, height: 1000,
            contentBounds: CGRect(x: 0, y: 0.05, width: 1, height: 0.95), leftEdge: edge, seamBounds: bounds)
        context.analysis[keys[1]] = ImageAnalysis(width: 700, height: 1000, rightEdge: edge, seamBounds: bounds)
        context.overrides = [:]
        for ids in [["marginAlign", "spreadDetect"], ["spreadDetect", "marginAlign"]] {
            let joined = await (try PagePipeline(ids: ids)).plan(Array(keys.prefix(2)), context: context)
            #expect(joined.count == 1)
            #expect(joined[0].regions.allSatisfy { $0.normalizedCrop.minY == 0 && $0.normalizedCrop.height == 1 })
        }
    }
    @Test func sourceProgressSurvivesSplitAndPairChanges() async throws {
        let pipeline = try PagePipeline()
        var context = ReaderContext(size: CGSize(width: 390, height: 800), overrides: [keys[0]: .split])
        let split = await pipeline.plan(keys, context: context)
        let fraction = PagePipeline.fraction(index: 1, withinPage: 0.4, source: keys[0], in: split)
        #expect(abs(fraction - 0.7) < 0.0001)
        #expect(PagePipeline.index(for: keys[0], fraction: fraction, in: split) == 1)
        context.overrides = [:]; context.size = CGSize(width: 1200, height: 800)
        let pair = await pipeline.plan(keys, context: context)
        #expect(PagePipeline.index(for: keys[0], fraction: fraction, in: pair) == 0)
        #expect(PagePipeline.index(for: keys[1], fraction: 0.2, in: pair) == 0)
        context.preferences.mode = .scroll
        let original = await pipeline.plan(keys, context: context)
        #expect(PagePipeline.index(for: keys[1], fraction: 0.2, in: original) == 1)
    }
    @Test func conservativeAnalysisAndComposition() async throws {
        let rule = try DemoContent.bundledRules().first { $0.id == "demo" }!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let loader = ImageLoader(directory: directory)
        let page = PageObject(key: keys[0], ownerRef: owner, sourceIndex: 0, imageURL: URL(string: "https://demo.mangaviewer.local/images/3.png")!, refererURL: owner.identityURL)
        let image = try await loader.image(for: page, rule: rule)
        let analysis = ImageProcessing.analyze(image)
        #expect(analysis.centerGutter)
        #expect(analysis.contentBounds.minX <= 0.1)
        #expect(analysis.contentBounds.width >= 0.8)
        let plan = DisplayPage(regions: [PageRegion(sourcePage: keys[0], normalizedCrop: CGRect(x: 0.5, y: 0, width: 0.5, height: 1))])
        let rendered = try #require(ImageProcessing.render(plan, images: [keys[0]: image]))
        #expect(rendered.width == image.width / 2)
        #expect(rendered.height == image.height)
    }
    @Test func diskCacheIsBoundedAndClearable() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let largest = try (1...4).map { try DemoContent.resource(String($0), extension: "png").count }.max()!
        let loader = ImageLoader(directory: directory, diskLimit: largest + 1)
        let rule = try DemoContent.bundledRules().first { $0.id == "demo" }!
        for n in 1...4 {
            let page = PageObject(key: keys[n - 1], ownerRef: owner, sourceIndex: n - 1, imageURL: URL(string: "https://demo.mangaviewer.local/images/\(n).png")!, refererURL: owner.identityURL)
            _ = try await loader.image(for: page, rule: rule, maxPixel: 256)
        }
        #expect(await loader.diskUsage() <= largest + 1)
        #expect(await loader.diskUsage() > 0)
        await loader.clear()
        #expect(await loader.diskUsage() == 0)
    }
}
