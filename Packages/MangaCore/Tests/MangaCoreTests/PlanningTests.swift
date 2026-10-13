import Foundation
import CoreGraphics
import Testing
@testable import MangaCore

struct PlanningTests {
    private let owner = ObjectKey(ruleID: "demo", identityURL: URL(string: "https://demo.mangaviewer.local/chapter/arrival")!)
    private var keys: [ObjectKey] { (0..<4).map { .page(owner: owner, index: $0) } }

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
        let edge = (0..<32).map { $0.isMultiple(of: 2) ? 0.15 : 0.85 }
        var context = ReaderContext(size: CGSize(width: 1200, height: 800))
        context.analysis[keys[0]] = ImageAnalysis(width: 700, height: 1000, leftEdge: edge, rightEdge: [])
        context.analysis[keys[1]] = ImageAnalysis(width: 700, height: 1000, leftEdge: [], rightEdge: edge)
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
        let rule = try DemoContent.bundledRules()[0]
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
        let rule = try DemoContent.bundledRules()[0]
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
