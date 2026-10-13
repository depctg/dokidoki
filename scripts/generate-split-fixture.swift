// Run from the repository root: swift scripts/generate-split-fixture.swift
// Original continuous geometric artwork, cut in half with unequal white binding margins.
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Foundation

let width = 1400, height = 1000
let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
context.setFillColor(CGColor(red: 0.08, green: 0.15, blue: 0.22, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: width, height: height))
for ridge in 0..<10 {
    let gold = ridge.isMultiple(of: 3)
    context.setFillColor(CGColor(red: gold ? 0.84 : 0.15 + Double(ridge) * 0.04,
        green: gold ? 0.67 : 0.3 + Double(ridge) * 0.025, blue: gold ? 0.4 : 0.42 + Double(ridge) * 0.015, alpha: 1))
    context.beginPath(); context.move(to: CGPoint(x: 0, y: 0))
    for x in stride(from: 0, through: width, by: 4) {
        let y = Double(height - 70 - ridge * 86) + 32 * sin(Double(x) / 155 + Double(ridge) * 0.8)
        context.addLine(to: CGPoint(x: Double(x), y: y))
    }
    context.addLine(to: CGPoint(x: width, y: 0)); context.closePath(); context.fillPath()
}
let original = context.makeImage()!
for right in [false, true] {
    let padding = right ? 24 : 16
    let piece = original.cropping(to: CGRect(x: right ? 700 : 0, y: 0, width: 700, height: height))!
    let padded = CGContext(data: nil, width: 700 + padding, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    padded.setFillColor(CGColor(gray: 1, alpha: 1)); padded.fill(CGRect(x: 0, y: 0, width: 700 + padding, height: height))
    padded.draw(piece, in: CGRect(x: right ? padding : 0, y: 0, width: 700, height: height))
    let name = right ? "split-right" : "split-left"
    let url = URL(fileURLWithPath: "Packages/MangaCore/Sources/MangaCore/Resources/Fixtures/\(name).png")
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, padded.makeImage()!, nil)
    precondition(CGImageDestinationFinalize(destination))
}
