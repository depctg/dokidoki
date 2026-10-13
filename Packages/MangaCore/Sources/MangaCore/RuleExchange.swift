import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreGraphics

public enum RuleExchange {
    /// Conservative single-code payload. Larger rules always remain available as JSON files.
    public static let qrByteLimit = 1200
    public static func qrImage(for rule: SiteRule) throws -> CGImage? {
        let data = try rule.exported()
        guard data.count <= qrByteLimit else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = data; filter.correctionLevel = "M"
        guard let output = filter.outputImage else { throw ReaderError.extraction(String(localized: "Could not create a QR code.", bundle: .module)) }
        let scale = 5
        let width = Int(output.extent.width) + 8
        let rendered = output.transformed(by: CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale)))
        guard let qr = CIContext().createCGImage(rendered, from: rendered.extent),
              let context = CGContext(data: nil, width: width * scale, height: width * scale, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw ReaderError.extraction(String(localized: "Could not render the QR code.", bundle: .module)) }
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width * scale, height: width * scale))
        context.interpolationQuality = .none
        context.draw(qr, in: CGRect(x: 4 * scale, y: 4 * scale, width: qr.width, height: qr.height))
        return context.makeImage()
    }
}
