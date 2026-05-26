import Foundation

// MARK: - Timeline fragment prune (matches app `TimelineFragmentPruner`)

private enum TimelineFragmentPrunerInternal {
    static let minimumRenderableDuration: TimeInterval = 0.02

    static func prune(
        _ timeline: Timeline,
        minimumDuration: TimeInterval = minimumRenderableDuration
    ) -> Timeline {
        var sanitized = timeline
        for trackIndex in sanitized.tracks.indices {
            sanitized.tracks[trackIndex].clips.removeAll { clip in
                clip.timelineRange.duration < minimumDuration || clip.sourceRange.duration < minimumDuration
            }
            sanitized.tracks[trackIndex].clips.sort {
                if $0.timelineRange.start != $1.timelineRange.start {
                    return $0.timelineRange.start < $1.timelineRange.start
                }
                return $0.timelineRange.end < $1.timelineRange.end
            }
        }
        return sanitized
    }
}

// MARK: - Overlay timestamp shift

@MainActor
private func shiftBroadcastOverlayEarlierAfterCut(context: EditingContext, cutPoint: TimeInterval, duration: TimeInterval) {
    guard var overlay = context.timelineState.broadcastOverlay else { return }
    overlay.topics = overlay.topics.map { topic in
        var t = topic
        if t.timeSeconds > cutPoint {
            t.timeSeconds -= duration
        }
        return t
    }
    overlay.chapters = overlay.chapters.map { ch in
        var c = ch
        if c.timeSeconds > cutPoint {
            c.timeSeconds -= duration
        }
        return c
    }
    context.timelineState.broadcastOverlay = overlay
}

@MainActor
private func rippleCloseAllGaps(context: EditingContext) {
    for trackIndex in context.timelineState.timeline.tracks.indices {
        var clips = context.timelineState.timeline.tracks[trackIndex].clips
        clips.sort { $0.timelineRange.start < $1.timelineRange.start }
        var cursor: TimeInterval = 0
        for i in clips.indices {
            if clips[i].timelineRange.start > cursor {
                let duration = clips[i].timelineRange.duration
                clips[i].timelineRange = TimeRange(start: cursor, duration: duration)
            }
            cursor = clips[i].timelineRange.end
        }
        context.timelineState.timeline.tracks[trackIndex].clips = clips
    }
}

@MainActor
private func clipIDsToSplitAtTimelineTime(_ time: TimeInterval, context: EditingContext) -> [UUID] {
    let tolerance = 0.001
    guard let videoTrackIdx = context.timelineState.timeline.tracks.firstIndex(where: { $0.type == .video }) else {
        return []
    }
    let clips = context.timelineState.timeline.tracks[videoTrackIdx].clips
    guard let clip = clips.first(where: {
        time > $0.timelineRange.start + tolerance && time < $0.timelineRange.end - tolerance
    }) else { return [] }

    if let link = clip.linkGroupID {
        return context.timelineState.timeline.tracks.flatMap(\.clips).filter {
            $0.linkGroupID == link
                && time > $0.timelineRange.start + tolerance
                && time < $0.timelineRange.end - tolerance
        }.map(\.id)
    }
    return [clip.id]
}

@MainActor
private func expandClipIDsForDeletion(_ clipIDs: [UUID], context: EditingContext) -> [UUID] {
    let allClips = context.timelineState.timeline.tracks.flatMap(\.clips)
    var expanded = Set(clipIDs)
    for id in clipIDs {
        guard let clip = allClips.first(where: { $0.id == id }),
              let linkGroup = clip.linkGroupID else { continue }
        allClips.filter { $0.linkGroupID == linkGroup }.forEach { expanded.insert($0.id) }
    }
    return Array(expanded)
}

// MARK: - RemoveSectionCommand

/// Split–delete–ripple workflow matching `MCPServer.handleRemoveSection` (first video track drives splits; linked clips follow).
public struct RemoveSectionCommand: Command {
    public let name = "Remove Section"
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    public var affectedClipIDs: [UUID] { [] }

    private var timelineSnapshot: Data?
    private var overlaySnapshot: Data?

    public init(startTime: TimeInterval, endTime: TimeInterval) {
        self.startTime = startTime
        self.endTime = endTime
    }

    public mutating func execute(context: EditingContext) throws {
        guard endTime > startTime else {
            throw CommandError.invalidRemoveSectionRange
        }

        timelineSnapshot = try JSONEncoder().encode(context.timelineState.timeline)
        if let overlay = context.timelineState.broadcastOverlay {
            overlaySnapshot = try JSONEncoder().encode(overlay)
        }

        let tolerance = 0.001

        if !clipIDsToSplitAtTimelineTime(startTime, context: context).isEmpty {
            let ids = clipIDsToSplitAtTimelineTime(startTime, context: context)
            for id in ids {
                var cmd = SplitClipCommand(clipID: id, at: startTime)
                try cmd.execute(context: context)
            }
            LinkedClipRelinker.relinkSecondHalvesAfterSplit(context: context, splitClipIDs: ids)
        }

        if !clipIDsToSplitAtTimelineTime(endTime, context: context).isEmpty {
            let ids = clipIDsToSplitAtTimelineTime(endTime, context: context)
            for id in ids {
                var cmd = SplitClipCommand(clipID: id, at: endTime)
                try cmd.execute(context: context)
            }
            LinkedClipRelinker.relinkSecondHalvesAfterSplit(context: context, splitClipIDs: ids)
        }

        let clipsToDelete = context.timelineState.timeline.tracks.flatMap(\.clips).filter { clip in
            clip.timelineRange.start >= startTime - tolerance && clip.timelineRange.end <= endTime + tolerance
        }.map(\.id)

        guard !clipsToDelete.isEmpty else {
            throw CommandError.noClipsInRemoveSectionRange
        }

        let expanded = expandClipIDsForDeletion(clipsToDelete, context: context)
        var del = DeleteClipsCommand(clipIDs: expanded)
        try del.execute(context: context)

        rippleCloseAllGaps(context: context)
        context.timelineState.timeline = TimelineFragmentPrunerInternal.prune(context.timelineState.timeline)

        let duration = endTime - startTime
        shiftBroadcastOverlayEarlierAfterCut(context: context, cutPoint: startTime, duration: duration)
    }

    public func undo(context: EditingContext) throws {
        guard let timelineSnapshot,
              let decoded = try? JSONDecoder().decode(Timeline.self, from: timelineSnapshot) else { return }
        context.timelineState.timeline = decoded
        if let overlaySnapshot,
           let overlay = try? JSONDecoder().decode(BroadcastOverlayConfig.self, from: overlaySnapshot) {
            context.timelineState.broadcastOverlay = overlay
        } else {
            context.timelineState.broadcastOverlay = nil
        }
    }
}

// MARK: - RippleDeleteClipsCommand

public struct RippleDeleteClipsCommand: Command {
    public let name = "Ripple Delete Clips"
    public let clipIDs: [UUID]
    public var affectedClipIDs: [UUID] { clipIDs }

    private var timelineSnapshot: Data?
    private var overlaySnapshot: Data?

    public init(clipIDs: [UUID]) {
        self.clipIDs = clipIDs
    }

    public mutating func execute(context: EditingContext) throws {
        guard !clipIDs.isEmpty else {
            throw CommandError.rippleDeleteEmpty
        }

        timelineSnapshot = try JSONEncoder().encode(context.timelineState.timeline)
        if let overlay = context.timelineState.broadcastOverlay {
            overlaySnapshot = try JSONEncoder().encode(overlay)
        }

        let idSet = Set(clipIDs)
        let deletedClips = context.timelineState.timeline.tracks.flatMap(\.clips).filter { idSet.contains($0.id) }
        let cutPoint = deletedClips.map(\.timelineRange.start).min() ?? 0
        let deletedDuration = deletedClips.map { $0.timelineRange.end - $0.timelineRange.start }.reduce(0, +)

        let expanded = expandClipIDsForDeletion(Array(idSet), context: context)
        var del = DeleteClipsCommand(clipIDs: expanded)
        try del.execute(context: context)

        rippleCloseAllGaps(context: context)

        if deletedDuration > 0 {
            shiftBroadcastOverlayEarlierAfterCut(context: context, cutPoint: cutPoint, duration: deletedDuration)
        }
    }

    public func undo(context: EditingContext) throws {
        guard let timelineSnapshot,
              let decoded = try? JSONDecoder().decode(Timeline.self, from: timelineSnapshot) else { return }
        context.timelineState.timeline = decoded
        if let overlaySnapshot,
           let overlay = try? JSONDecoder().decode(BroadcastOverlayConfig.self, from: overlaySnapshot) {
            context.timelineState.broadcastOverlay = overlay
        } else {
            context.timelineState.broadcastOverlay = nil
        }
    }
}
