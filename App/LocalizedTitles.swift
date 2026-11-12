import Foundation
import MangaCore

// Display labels are separate from the stable raw values stored in reader preferences.
extension ReadingMode {
    var title: String {
        switch self {
        case .paged: String(localized: "Paged")
        case .scroll: String(localized: "Scroll")
        }
    }
}
extension ReadingDirection {
    var title: String {
        switch self {
        case .rightToLeft: String(localized: "Right to left")
        case .leftToRight: String(localized: "Left to right")
        }
    }
}
extension SpreadOverride {
    var title: String {
        switch self {
        case .automatic: String(localized: "Automatic")
        case .keep: String(localized: "Keep original")
        case .split: String(localized: "Split")
        case .pairWithNext: String(localized: "Pair with next")
        }
    }
}

// Loading choices retain language-independent values in core preferences.
extension RequestConcurrency {
    var title: String {
        switch self {
        case .low: String(localized: "Low")
        case .medium: String(localized: "Medium")
        case .high: String(localized: "High")
        case .unlimited: String(localized: "Unlimited")
        }
    }
}
extension PrefetchDistance {
    var title: String {
        self == .off ? String(localized: "No prefetch") : String(localized: "\(rawValue) pages ahead")
    }
}
