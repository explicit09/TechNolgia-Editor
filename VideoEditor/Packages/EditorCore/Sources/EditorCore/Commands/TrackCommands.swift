import Foundation

// MARK: - AddTrackCommand

public struct AddTrackCommand: Command {
    public let name = "Add Track"
    public let track: Track
    public let insertionIndex: Int?
    public var affectedTrackIDs: [UUID] { [track.id] }
    public var metadata: [String: String] {
        var values = ["trackType": track.type.rawValue, "trackName": track.name]
        if let insertionIndex {
            values["trackIndex"] = String(insertionIndex)
        }
        return values
    }

    public init(track: Track, insertionIndex: Int? = nil) {
        self.track = track
        self.insertionIndex = insertionIndex
    }

    public mutating func execute(context: EditingContext) throws {
        if let insertionIndex {
            let safeIndex = min(max(insertionIndex, 0), context.timelineState.timeline.tracks.count)
            context.timelineState.timeline.tracks.insert(track, at: safeIndex)
        } else {
            context.timelineState.timeline.tracks.append(track)
        }
    }

    public func undo(context: EditingContext) throws {
        context.timelineState.timeline.tracks.removeAll { $0.id == track.id }
    }
}

// MARK: - ReorderTrackCommand

public struct ReorderTrackCommand: Command {
    public let name = "Reorder Track"
    public let trackID: UUID
    public let newIndex: Int
    public var affectedTrackIDs: [UUID] { [trackID] }
    private var previousIndex: Int?

    public init(trackID: UUID, newIndex: Int) {
        self.trackID = trackID
        self.newIndex = newIndex
    }

    public mutating func execute(context: EditingContext) throws {
        guard let currentIndex = context.timelineState.timeline.tracks.firstIndex(where: { $0.id == trackID }) else {
            throw CommandError.trackNotFound(trackID)
        }
        previousIndex = currentIndex
        let track = context.timelineState.timeline.tracks.remove(at: currentIndex)
        let safeIndex = min(max(newIndex, 0), context.timelineState.timeline.tracks.count)
        context.timelineState.timeline.tracks.insert(track, at: safeIndex)
    }

    public func undo(context: EditingContext) throws {
        guard let previousIndex else { return }
        guard let currentIndex = context.timelineState.timeline.tracks.firstIndex(where: { $0.id == trackID }) else { return }
        let track = context.timelineState.timeline.tracks.remove(at: currentIndex)
        let safeIndex = min(previousIndex, context.timelineState.timeline.tracks.count)
        context.timelineState.timeline.tracks.insert(track, at: safeIndex)
    }
}

// MARK: - RemoveTrackCommand

public struct RemoveTrackCommand: Command {
    public let name = "Remove Track"
    public let trackID: UUID
    public var affectedTrackIDs: [UUID] { [trackID] }
    private var removedTrack: Track?
    private var removedIndex: Int?

    public init(trackID: UUID) {
        self.trackID = trackID
    }

    public mutating func execute(context: EditingContext) throws {
        let index = try editableTrackIndex(for: trackID, context: context)
        guard context.timelineState.timeline.tracks[index].clips.isEmpty else {
            throw CommandError.trackNotEmpty(trackID)
        }
        removedTrack = context.timelineState.timeline.tracks[index]
        removedIndex = index
        context.timelineState.timeline.tracks.remove(at: index)
    }

    public func undo(context: EditingContext) throws {
        guard let track = removedTrack, let index = removedIndex else { return }
        let insertAt = min(index, context.timelineState.timeline.tracks.count)
        context.timelineState.timeline.tracks.insert(track, at: insertAt)
    }
}
