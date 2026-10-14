import Foundation

public struct MangaProgress: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable { case reading, finished, new }
    public internal(set) var state: State = .reading
    /// Unknown until the manga's chapter catalog is known. Ignored chapters are excluded.
    public internal(set) var fraction: Double?
}

struct ChapterProgress: Codable, Sendable, Equatable {
    var status: ChapterReadingStatus
    var fraction: Double
}
/// Durable user knowledge carried by a manga, separate from evictable source snapshots.
/// No tasks, transport or session state belongs here.
public struct MangaPersonalState: Codable, Sendable, Equatable {
    var chapterProgress: [ObjectKey: ChapterProgress] = [:]
    var finishedCatalog: Set<ObjectKey>?
    public internal(set) var position: ReadingPosition?
    public internal(set) var isSaved = false
    public internal(set) var isStarred = false
    public internal(set) var isRecentHidden = false
    public internal(set) var progress = MangaProgress()
    public var chapterStatuses: [ObjectKey: ChapterReadingStatus] { chapterProgress.mapValues(\.status) }
}

extension MangaObject {
    mutating func updateProgress() {
        guard var state = personalState else { return }
        guard let chapters else {
            state.progress = MangaProgress(); personalState = state; return
        }
        let keys = Set(chapters.map(\.key))
        let eligible = keys.filter { state.chapterProgress[$0]?.status != .ignored }
        let finished = !keys.isEmpty && eligible.allSatisfy { state.chapterProgress[$0]?.status == .read }
        let fraction = eligible.isEmpty ? (finished ? 1.0 : 0.0)
            : eligible.reduce(0.0) { $0 + (state.chapterProgress[$1]?.fraction ?? 0) } / Double(eligible.count)
        var kind: MangaProgress.State = finished ? .finished : .reading
        if finished {
            if state.finishedCatalog != keys { state.finishedCatalog = keys }
        } else if let baseline = state.finishedCatalog {
            let added = eligible.subtracting(baseline)
            if !added.isEmpty, added.allSatisfy({ (state.chapterProgress[$0]?.status ?? .unread) == .unread }) { kind = .new }
        }
        state.progress = MangaProgress(state: kind, fraction: min(1, max(0, fraction)))
        personalState = state
    }
}
