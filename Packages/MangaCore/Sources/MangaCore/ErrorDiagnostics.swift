import Foundation
import OSLog

/// Error-only native diagnostics. Never pass free-form source text or URLs to the system log.
public enum ErrorDiagnostics {
    public enum Operation: String, Sendable {
        case loadContent, loadImage, openURL, startup, storage, imageCache
        case importRule, exportRule, updateRules, processImage, readReport, exportReport
    }
    public struct Entry: Sendable {
        public let date: Date
        public let message: String
    }
    static let subsystem = "com.mangaviewer.reader"
    static let category = "errors"
    private static let logger = Logger(subsystem: subsystem, category: category)

    public static func record(_ error: any Error, operation: Operation, url: URL? = nil) {
        guard !Task.isCancelled, let message = message(error, operation: operation, url: url) else { return }
        logger.error("\(message, privacy: .public)")
    }

    // Only stable reason codes and the hostname are public. Error descriptions/userInfo can
    // contain signed URLs, local paths, imported rules or page contents, even for system errors.
    static func message(_ error: any Error, operation: Operation, url: URL? = nil) -> String? {
        let nsError = error as NSError
        guard !(error is CancellationError),
              !(nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled),
              !(nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError) else { return nil }
        let reason: String
        if let error = error as? ReaderError {
            switch error {
            case .unsupportedURL: reason = "unsupported_url"
            case .ambiguousURL: reason = "ambiguous_rule"
            case .invalidRule: reason = "invalid_rule"
            case .blockedHost: reason = "blocked_host"
            case .invalidResponse: reason = "invalid_response"
            case .httpStatus(let code): reason = "HTTP \(code)"
            case .tooLarge: reason = "response_too_large"
            case .extraction: reason = "extraction_failed"
            case .cacheMiss: reason = "cache_miss"
            case .missingRule: reason = "missing_rule"
            case .renderedSourceRequired: reason = "rendered_source_required"
            }
        } else if error is DecodingError { reason = "decoding_failed" }
        else if error is EncodingError { reason = "encoding_failed" }
        else {
            let domains = [NSURLErrorDomain, NSCocoaErrorDomain, NSPOSIXErrorDomain, "WKErrorDomain", "GRDB.DatabaseError"]
            reason = "\(domains.contains(nsError.domain) ? nsError.domain : "other") \(nsError.code)"
        }
        let host = url?.host?.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber || ".-:[]".contains($0)) }
        return "\(operation.rawValue): \(reason)" + (host.flatMap { $0.isEmpty ? nil : " [\(String($0.prefix(253)))]" } ?? "")
    }

    /// Native stores expose the current process on all supported platforms. Apple owns retention;
    /// bound reports to the latest 200 error/fault entries within 24 hours, excluding other loggers.
    public static func entries() async throws -> [Entry] {
        try await Task.detached(priority: .utility) {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let start = store.position(date: Date().addingTimeInterval(-86_400))
            let predicate = NSPredicate(format: "subsystem == %@ AND category == %@", subsystem, category)
            var result: [Entry] = []
            for case let entry as OSLogEntryLog in try store.getEntries(at: start, matching: predicate) {
                guard entry.level == .error || entry.level == .fault else { continue }
                result.append(Entry(date: entry.date, message: entry.composedMessage))
                if result.count > 200 { result.removeFirst() }
            }
            return result
        }.value
    }
}
