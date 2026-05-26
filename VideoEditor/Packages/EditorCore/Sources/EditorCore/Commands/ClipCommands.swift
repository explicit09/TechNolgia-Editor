import Foundation

// MARK: - InsertClipCommand

public struct InsertClipCommand: Command {
    public let name = "Insert Clip"
    public let clip: Clip
    public let trackID: UUID
    public var affectedClipIDs: [UUID] { [clip.id] }
    public var affectedTrackIDs: [UUID] { [trackID] }

    public init(clip: Clip, trackID: UUID) {
        self.clip = clip
        self.trackID = trackID
    }

    public mutating func execute(context: EditingContext) throws {
        let trackIndex = try editableTrackIndex(for: trackID, context: context)
        var insertedClip = clip
        let adjustedStart = collisionAdjustedStart(
            proposedStart: clip.timelineRange.start,
            duration: clip.timelineRange.duration,
            in: context.timelineState.timeline.tracks[trackIndex].clips
        )
        insertedClip.timelineRange = TimeRange(start: adjustedStart, duration: clip.timelineRange.duration)
        let insertionIndex = MoveClipCommand.insertionIndex(for: insertedClip, in: context.timelineState.timeline.tracks[trackIndex].clips)
        context.timelineState.timeline.tracks[trackIndex].clips.insert(insertedClip, at: insertionIndex)
    }

    public func undo(context: EditingContext) throws {
        guard let trackIndex = context.timelineState.timeline.tracks.firstIndex(where: { $0.id == trackID }) else { return }
        context.timelineState.timeline.tracks[trackIndex].clips.removeAll { $0.id == clip.id }
    }
}

// MARK: - DeleteClipsCommand

public struct DeleteClipsCommand: Command {
    public let name = "Delete Clips"
    public let clipIDs: [UUID]
    public var affectedClipIDs: [UUID] { clipIDs }
    private var removedClips: [(clip: Clip, trackID: UUID, clipIndex: Int)] = []

    public init(clipIDs: [UUID]) {
        self.clipIDs = clipIDs
    }

    public mutating func execute(context: EditingContext) throws {
        for clipID in Set(clipIDs) {
            _ = try editableClipLocation(for: clipID, context: context)
        }

        removedClips = []
        for trackIndex in context.timelineState.timeline.tracks.indices {
            let trackID = context.timelineState.timeline.tracks[trackIndex].id
            for (clipIndex, clip) in context.timelineState.timeline.tracks[trackIndex].clips.enumerated() where clipIDs.contains(clip.id) {
                removedClips.append((clip: clip, trackID: trackID, clipIndex: clipIndex))
            }
            context.timelineState.timeline.tracks[trackIndex].clips.removeAll { clipIDs.contains($0.id) }
        }
    }

    public func undo(context: EditingContext) throws {
        // Restore in order of original index (lowest first) so positions stay correct
        let sorted = removedClips.sorted { $0.clipIndex < $1.clipIndex }
        for entry in sorted {
            guard let trackIndex = context.timelineState.timeline.tracks.firstIndex(where: { $0.id == entry.trackID }) else { continue }
            let insertAt = min(entry.clipIndex, context.timelineState.timeline.tracks[trackIndex].clips.count)
            context.timelineState.timeline.tracks[trackIndex].clips.insert(entry.clip, at: insertAt)
        }
    }
}

// MARK: - MoveClipCommand

public struct MoveClipCommand: Command {
    public let name = "Move Clip"
    public let clipID: UUID
    public let newStart: TimeInterval
    public let targetTrackID: UUID
    public var affectedClipIDs: [UUID] { [clipID] }
    public var affectedTrackIDs: [UUID] {
        guard let previousTrackID, previousTrackID != targetTrackID else { return [targetTrackID] }
        return [previousTrackID, targetTrackID]
    }
    public var metadata: [String: String] { ["newStart": String(newStart)] }
    private var previousRange: TimeRange?
    private var previousTrackID: UUID?
    private var previousClipIndex: Int?

    public init(clipID: UUID, newStart: TimeInterval, targetTrackID: UUID) {
        self.clipID = clipID
        self.newStart = newStart
        self.targetTrackID = targetTrackID
    }

    public mutating func execute(context: EditingContext) throws {
        let location = try clipLocation(for: clipID, context: context)
        let sourceTrackIndex = location.trackIndex
        let clipIndex = location.clipIndex
        let targetTrackIndex = try trackIndex(for: targetTrackID, context: context)
        let sourceTrackID = context.timelineState.timeline.tracks[sourceTrackIndex].id
        guard !context.timelineState.timeline.tracks[sourceTrackIndex].isLocked else {
            throw CommandError.trackLocked(sourceTrackID)
        }
        guard !context.timelineState.timeline.tracks[targetTrackIndex].isLocked else {
            throw CommandError.trackLocked(targetTrackID)
        }

        let clip = context.timelineState.timeline.tracks[sourceTrackIndex].clips[clipIndex]
        previousRange = clip.timelineRange
        previousTrackID = sourceTrackID
        previousClipIndex = clipIndex

        var movedClip = clip
        let adjustedStart = collisionAdjustedStart(
            proposedStart: newStart,
            duration: clip.timelineRange.duration,
            in: context.timelineState.timeline.tracks[targetTrackIndex].clips,
            excluding: clipID
        )
        movedClip.timelineRange = TimeRange(start: adjustedStart, duration: clip.timelineRange.duration)

        context.timelineState.timeline.tracks[sourceTrackIndex].clips.remove(at: clipIndex)

        let insertionIndex = Self.insertionIndex(for: movedClip, in: context.timelineState.timeline.tracks[targetTrackIndex].clips)
        context.timelineState.timeline.tracks[targetTrackIndex].clips.insert(movedClip, at: insertionIndex)
    }

    public func undo(context: EditingContext) throws {
        guard let previousRange, let previousTrackID, let previousClipIndex else { return }
        guard let currentTrackIndex = context.timelineState.timeline.tracks.firstIndex(where: { track in
            track.clips.contains(where: { $0.id == clipID })
        }), let currentClipIndex = context.timelineState.timeline.tracks[currentTrackIndex].clips.firstIndex(where: { $0.id == clipID }) else {
            return
        }

        var restoredClip = context.timelineState.timeline.tracks[currentTrackIndex].clips.remove(at: currentClipIndex)
        restoredClip.timelineRange = previousRange

        guard let destinationTrackIndex = context.timelineState.timeline.tracks.firstIndex(where: { $0.id == previousTrackID }) else {
            // Don't silently put clip on wrong track — put it back where we found it and throw
            context.timelineState.timeline.tracks[currentTrackIndex].clips.insert(restoredClip, at: min(currentClipIndex, context.timelineState.timeline.tracks[currentTrackIndex].clips.count))
            throw CommandError.trackNotFound(previousTrackID)
        }

        let insertAt = min(previousClipIndex, context.timelineState.timeline.tracks[destinationTrackIndex].clips.count)
        context.timelineState.timeline.tracks[destinationTrackIndex].clips.insert(restoredClip, at: insertAt)
    }

    static func insertionIndex(for clip: Clip, in clips: [Clip]) -> Int {
        clips.firstIndex {
            if $0.timelineRange.start != clip.timelineRange.start {
                return $0.timelineRange.start > clip.timelineRange.start
            }
            return $0.timelineRange.end > clip.timelineRange.end
        } ?? clips.count
    }
}

// MARK: - TrimClipCommand

public struct TrimClipCommand: Command {
    public let name = "Trim Clip"
    public let clipID: UUID
    public let newSourceRange: TimeRange
    public var affectedClipIDs: [UUID] { [clipID] }
    private var previousSourceRange: TimeRange?
    private var previousTimelineRange: TimeRange?

    public init(clipID: UUID, newSourceRange: TimeRange) {
        self.clipID = clipID
        self.newSourceRange = newSourceRange
    }

    public mutating func execute(context: EditingContext) throws {
        let location = try editableClipLocation(for: clipID, context: context)
        let clip = context.timelineState.timeline.tracks[location.trackIndex].clips[location.clipIndex]
        previousSourceRange = clip.sourceRange
        previousTimelineRange = clip.timelineRange
        let proposal = ClipTrimResolver.proposal(
            for: clip,
            proposedSourceRange: newSourceRange,
            in: context.timelineState.timeline.tracks[location.trackIndex].clips
        )

        context.timelineState.timeline.tracks[location.trackIndex].clips[location.clipIndex].sourceRange = proposal.sourceRange
        context.timelineState.timeline.tracks[location.trackIndex].clips[location.clipIndex].timelineRange = proposal.timelineRange
    }

    public func undo(context: EditingContext) throws {
        guard let previousSourceRange, let previousTimelineRange else { return }
        for trackIndex in context.timelineState.timeline.tracks.indices {
            if let clipIndex = context.timelineState.timeline.tracks[trackIndex].clips.firstIndex(where: { $0.id == clipID }) {
                context.timelineState.timeline.tracks[trackIndex].clips[clipIndex].sourceRange = previousSourceRange
                context.timelineState.timeline.tracks[trackIndex].clips[clipIndex].timelineRange = previousTimelineRange
                return
            }
        }
    }
}

// MARK: - SplitClipCommand

public struct SplitClipCommand: Command {
    public let name = "Split Clip"
    public let clipID: UUID
    public let at: TimeInterval
    public var affectedClipIDs: [UUID] { [clipID] + (secondClipID.map { [$0] } ?? []) }
    public var metadata: [String: String] { ["splitAt": String(at)] }
    private var originalClip: Clip?
    private var secondClipID: UUID?
    private var trackID: UUID?

    public init(clipID: UUID, at: TimeInterval) {
        self.clipID = clipID
        self.at = at
    }

    public mutating func execute(context: EditingContext) throws {
        let location = try editableClipLocation(for: clipID, context: context)
        let clip = context.timelineState.timeline.tracks[location.trackIndex].clips[location.clipIndex]
        originalClip = clip
        trackID = context.timelineState.timeline.tracks[location.trackIndex].id

        guard at > clip.timelineRange.start && at < clip.timelineRange.end else {
            throw CommandError.splitPointOutOfRange
        }

        let splitOffset = at - clip.timelineRange.start

        // Shorten first clip.
        context.timelineState.timeline.tracks[location.trackIndex].clips[location.clipIndex].timelineRange = TimeRange(
            start: clip.timelineRange.start,
            end: at
        )
        context.timelineState.timeline.tracks[location.trackIndex].clips[location.clipIndex].sourceRange = TimeRange(
            start: clip.sourceRange.start,
            end: clip.sourceRange.start + splitOffset
        )

        // Create second clip.
        let newID = UUID()
        secondClipID = newID
        let secondClip = Clip(
            id: newID,
            assetID: clip.assetID,
            timelineRange: TimeRange(start: at, end: clip.timelineRange.end),
            sourceRange: TimeRange(start: clip.sourceRange.start + splitOffset, end: clip.sourceRange.end),
            transform: clip.transform,
            cropRect: clip.cropRect,
            opacity: clip.opacity,
            volume: clip.volume,
            effects: clip.effects,
            keyframes: clip.keyframes,
            metadata: clip.metadata,
            speed: clip.speed,
            transitionIn: clip.transitionIn,
            linkGroupID: clip.linkGroupID,
            blendMode: clip.blendMode,
            overlayPresentation: clip.overlayPresentation
        )
        context.timelineState.timeline.tracks[location.trackIndex].clips.insert(secondClip, at: location.clipIndex + 1)
    }

    public func undo(context: EditingContext) throws {
        guard let originalClip, let secondClipID, let trackID else { return }
        guard let trackIndex = context.timelineState.timeline.tracks.firstIndex(where: { $0.id == trackID }) else { return }

        // Remove the second clip
        context.timelineState.timeline.tracks[trackIndex].clips.removeAll { $0.id == secondClipID }

        // Restore original clip
        if let clipIndex = context.timelineState.timeline.tracks[trackIndex].clips.firstIndex(where: { $0.id == clipID }) {
            context.timelineState.timeline.tracks[trackIndex].clips[clipIndex] = originalClip
        }
    }
}

// MARK: - SetMarkerCommand

public struct SetMarkerCommand: Command {
    public let name = "Set Marker"
    public let marker: Marker

    public init(at time: TimeInterval, label: String, color: String = "#FF0000") {
        self.marker = Marker(time: time, label: label, color: color)
    }

    public mutating func execute(context: EditingContext) throws {
        // Idempotent: don't add duplicate on redo
        if !context.timelineState.timeline.markers.contains(where: { $0.id == marker.id }) {
            context.timelineState.timeline.markers.append(marker)
            context.timelineState.timeline.markers.sort { $0.time < $1.time }
        }
    }

    public func undo(context: EditingContext) throws {
        context.timelineState.timeline.markers.removeAll { $0.id == marker.id }
    }
}

// MARK: - CommandError

public enum CommandError: Error {
    case trackNotFound(UUID)
    case clipNotFound(UUID)
    case trackLocked(UUID)
    case splitPointOutOfRange
    case trackNotEmpty(UUID)
    case invalidRemoveSectionRange
    case noClipsInRemoveSectionRange
    case rippleDeleteEmpty
}
