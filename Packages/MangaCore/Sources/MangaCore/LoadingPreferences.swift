import Foundation

public enum RequestConcurrency: String, Codable, Sendable, CaseIterable {
    case low, medium, high, unlimited

    var total: Int {
        switch self { case .low: 4; case .medium: 8; case .high: 16; case .unlimited: .max }
    }
    var perHost: Int {
        switch self { case .low: 2; case .medium: 4; case .high: 8; case .unlimited: .max }
    }
}

public enum PrefetchDistance: Int, Codable, Sendable, CaseIterable {
    case off = 0, near = 2, medium = 4, far = 8

    /// Current artwork is always prepared. Speculative work favors forward pages,
    /// then one previous page, with a bounded source budget for facing-page plans.
    public func sources(in plans: [DisplayPage], at index: Int) -> [ObjectKey] {
        guard plans.indices.contains(index) else { return [] }
        var indices = Array(index...min(plans.count - 1, index + rawValue))
        if self != .off, index > 0 { indices.append(index - 1) }
        var keys: [ObjectKey] = []
        for i in indices {
            for key in plans[i].sourcePageKeys where !keys.contains(key) { keys.append(key) }
        }
        return Array(keys.prefix((rawValue + 1) * 2))
    }
}
