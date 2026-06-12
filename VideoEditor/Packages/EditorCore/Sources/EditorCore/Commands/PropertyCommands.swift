import Foundation

// MARK: - Clip Property Commands

/// Change a clip's audio volume.
public struct SetClipVolumeCommand: Command {
    public let name = "Set Clip Volume"
    public let clipID: UUID
    public let newVolume: Double
    public var affectedClipIDs: [UUID] { [clipID] }
    private var previousVolume: Double?

    public init(clipID: UUID, volume: Double) {
        self.clipID = clipID
        self.newVolume = max(volume, 0)
    }

    public mutating func execute(context: EditingContext) throws {
        try modifyClip(id: clipID, context: context) { clip in
            previousVolume = clip.volume
            clip.volume = newVolume
        }
    }

    public func undo(context: EditingContext) throws {
        guard let prev = previousVolume else { return }
        try modifyClip(id: clipID, context: context) { $0.volume = prev }
    }
}

/// Change a clip's visual opacity.
public struct SetClipOpacityCommand: Command {
    public let name = "Set Clip Opacity"
    public let clipID: UUID
    public let newOpacity: Double
    public var affectedClipIDs: [UUID] { [clipID] }
    private var previousOpacity: Double?

    public init(clipID: UUID, opacity: Double) {
        self.clipID = clipID
        self.newOpacity = min(max(opacity, 0), 1)
    }

    public mutating func execute(context: EditingContext) throws {
        try modifyClip(id: clipID, context: context) { clip in
            previousOpacity = clip.opacity
            clip.opacity = newOpacity
        }
    }

    public func undo(context: EditingContext) throws {
        guard let prev = previousOpacity else { return }
        try modifyClip(id: clipID, context: context) { $0.opacity = prev }
    }
}

/// Change a clip's 2D transform (position, scale, rotation).
public struct SetClipTransformCommand: Command {
    public let name = "Set Clip Transform"
    public let clipID: UUID
    public let newTransform: Transform2D
    public var affectedClipIDs: [UUID] { [clipID] }
    private var previousTransform: Transform2D?

    public init(clipID: UUID, transform: Transform2D) {
        self.clipID = clipID
        self.newTransform = transform
    }

    public mutating func execute(context: EditingContext) throws {
        try modifyClip(id: clipID, context: context) { clip in
            previousTransform = clip.transform
            clip.transform = newTransform
        }
    }

    public func undo(context: EditingContext) throws {
        guard let prev = previousTransform else { return }
        try modifyClip(id: clipID, context: context) { $0.transform = prev }
    }
}

/// Change a clip's normalized crop rect.
public struct SetClipCropCommand: Command {
    public let name = "Set Clip Crop"
    public let clipID: UUID
    public let newCropRect: CropRect
    public var affectedClipIDs: [UUID] { [clipID] }
    private var previousCropRect: CropRect?

    public init(clipID: UUID, cropRect: CropRect) {
        self.clipID = clipID
        self.newCropRect = cropRect.clamped
    }

    public mutating func execute(context: EditingContext) throws {
        try modifyClip(id: clipID, context: context) { clip in
            previousCropRect = clip.cropRect
            clip.cropRect = newCropRect
        }
    }

    public func undo(context: EditingContext) throws {
        guard let previousCropRect else { return }
        try modifyClip(id: clipID, context: context) { $0.cropRect = previousCropRect }
    }
}

/// Change a clip's overlay presentation state.
public struct SetClipOverlayPresentationCommand: Command {
    public let name = "Set Clip Overlay Presentation"
    public let clipID: UUID
    public let presentation: OverlayPresentation
    public var affectedClipIDs: [UUID] { [clipID] }
    private var previousPresentation: OverlayPresentation?

    public init(clipID: UUID, presentation: OverlayPresentation) {
        self.clipID = clipID
        self.presentation = presentation
    }

    public mutating func execute(context: EditingContext) throws {
        try modifyClip(id: clipID, context: context) { clip in
            previousPresentation = clip.overlayPresentation
            clip.overlayPresentation = presentation
        }
    }

    public func undo(context: EditingContext) throws {
        guard let previousPresentation else { return }
        try modifyClip(id: clipID, context: context) { $0.overlayPresentation = previousPresentation }
    }
}

/// Apply a simple clip-owned PiP preset.
public struct ApplyClipPiPPresetCommand: Command {
    public let name = "Apply Clip PiP Preset"
    public let clipID: UUID
    public let preset: OverlayPiPPreset
    public var affectedClipIDs: [UUID] { [clipID] }
    private var previousPresentation: OverlayPresentation?
    private var previousTransform: Transform2D?

    public init(clipID: UUID, preset: OverlayPiPPreset) {
        self.clipID = clipID
        self.preset = preset
    }

    public mutating func execute(context: EditingContext) throws {
        try modifyClip(id: clipID, context: context) { clip in
            previousPresentation = clip.overlayPresentation
            previousTransform = clip.transform
            clip.overlayPresentation = pipPresentation(for: preset)
            clip.transform = pipTransform(for: preset)
        }
    }

    public func undo(context: EditingContext) throws {
        guard let previousPresentation, let previousTransform else { return }
        try modifyClip(id: clipID, context: context) { clip in
            clip.overlayPresentation = previousPresentation
            clip.transform = previousTransform
        }
    }
}

/// Set track audio effect chain (EQ, compression, noise gate).
public struct SetTrackAudioEffectsCommand: Command {
    public let name = "Set Track Audio Effects"
    public let trackID: UUID
    public let newEffectChain: AudioEffectChain?
    public var affectedTrackIDs: [UUID] { [trackID] }
    private var previousEffectChain: AudioEffectChain?

    public init(trackID: UUID, effectChain: AudioEffectChain?) {
        self.trackID = trackID
        self.newEffectChain = effectChain
    }

    public mutating func execute(context: EditingContext) throws {
        try modifyTrack(id: trackID, context: context) { track in
            previousEffectChain = track.audioEffectChain
            track.audioEffectChain = newEffectChain
        }
    }

    public func undo(context: EditingContext) throws {
        try modifyTrack(id: trackID, context: context) { $0.audioEffectChain = previousEffectChain }
    }
}

// MARK: - Track Property Commands

/// Toggle track mute state.
public struct MuteTrackCommand: Command {
    public let name = "Toggle Mute Track"
    public let trackID: UUID
    public let muted: Bool
    public var affectedTrackIDs: [UUID] { [trackID] }
    private var previousMuted: Bool?

    public init(trackID: UUID, muted: Bool) {
        self.trackID = trackID
        self.muted = muted
    }

    public mutating func execute(context: EditingContext) throws {
        try modifyTrack(id: trackID, context: context) { track in
            previousMuted = track.isMuted
            track.isMuted = muted
        }
    }

    public func undo(context: EditingContext) throws {
        guard let prev = previousMuted else { return }
        try modifyTrack(id: trackID, context: context) { $0.isMuted = prev }
    }
}

/// Toggle track solo state.
public struct SoloTrackCommand: Command {
    public let name = "Toggle Solo Track"
    public let trackID: UUID
    public let soloed: Bool
    public var affectedTrackIDs: [UUID] { [trackID] }
    private var previousSoloed: Bool?

    public init(trackID: UUID, soloed: Bool) {
        self.trackID = trackID
        self.soloed = soloed
    }

    public mutating func execute(context: EditingContext) throws {
        try modifyTrack(id: trackID, context: context) { track in
            previousSoloed = track.isSoloed
            track.isSoloed = soloed
        }
    }

    public func undo(context: EditingContext) throws {
        guard let prev = previousSoloed else { return }
        try modifyTrack(id: trackID, context: context) { $0.isSoloed = prev }
    }
}

/// Toggle track lock state.
public struct LockTrackCommand: Command {
    public let name = "Toggle Lock Track"
    public let trackID: UUID
    public let locked: Bool
    public var affectedTrackIDs: [UUID] { [trackID] }
    private var previousLocked: Bool?

    public init(trackID: UUID, locked: Bool) {
        self.trackID = trackID
        self.locked = locked
    }

    public mutating func execute(context: EditingContext) throws {
        try modifyTrack(id: trackID, context: context) { track in
            previousLocked = track.isLocked
            track.isLocked = locked
        }
    }

    public func undo(context: EditingContext) throws {
        guard let prev = previousLocked else { return }
        try modifyTrack(id: trackID, context: context) { $0.isLocked = prev }
    }
}

/// Rename a track.
public struct RenameTrackCommand: Command {
    public let name = "Rename Track"
    public let trackID: UUID
    public let newName: String
    public var affectedTrackIDs: [UUID] { [trackID] }
    private var previousName: String?

    public init(trackID: UUID, name: String) {
        self.trackID = trackID
        self.newName = name
    }

    public mutating func execute(context: EditingContext) throws {
        try modifyTrack(id: trackID, context: context) { track in
            previousName = track.name
            track.name = newName
        }
    }

    public func undo(context: EditingContext) throws {
        guard let previousName else { return }
        try modifyTrack(id: trackID, context: context) { $0.name = previousName }
    }
}

/// Change track volume.
public struct SetTrackVolumeCommand: Command {
    public let name = "Set Track Volume"
    public let trackID: UUID
    public let newVolume: Double
    public var affectedTrackIDs: [UUID] { [trackID] }
    private var previousVolume: Double?

    public init(trackID: UUID, volume: Double) {
        self.trackID = trackID
        self.newVolume = max(volume, 0)
    }

    public mutating func execute(context: EditingContext) throws {
        try modifyTrack(id: trackID, context: context) { track in
            previousVolume = track.volume
            track.volume = newVolume
        }
    }

    public func undo(context: EditingContext) throws {
        guard let prev = previousVolume else { return }
        try modifyTrack(id: trackID, context: context) { $0.volume = prev }
    }
}

/// Rename a clip's label.
public struct RenameClipCommand: Command {
    public let name = "Rename Clip"
    public let clipID: UUID
    public let newLabel: String
    public var affectedClipIDs: [UUID] { [clipID] }
    private var previousLabel: String?

    public init(clipID: UUID, label: String) {
        self.clipID = clipID
        self.newLabel = label
    }

    public mutating func execute(context: EditingContext) throws {
        try modifyClip(id: clipID, context: context) { clip in
            previousLabel = clip.metadata.label
            clip.metadata.label = newLabel
        }
    }

    public func undo(context: EditingContext) throws {
        try modifyClip(id: clipID, context: context) { $0.metadata.label = previousLabel }
    }
}

/// Duplicate a clip within the same track, placed immediately after the original.
public struct DuplicateClipCommand: Command {
    public let name = "Duplicate Clip"
    public let clipID: UUID
    public var affectedClipIDs: [UUID] { [clipID] + (newClipID.map { [$0] } ?? []) }
    private var newClipID: UUID?
    private var trackID: UUID?

    public init(clipID: UUID) {
        self.clipID = clipID
    }

    public mutating func execute(context: EditingContext) throws {
        let location = try editableClipLocation(for: clipID, context: context)
        let original = context.timelineState.timeline.tracks[location.trackIndex].clips[location.clipIndex]
        let id = UUID()
        newClipID = id
        trackID = context.timelineState.timeline.tracks[location.trackIndex].id
        let adjustedStart = collisionAdjustedStart(
            proposedStart: original.timelineRange.end,
            duration: original.timelineRange.duration,
            in: context.timelineState.timeline.tracks[location.trackIndex].clips
        )

        let duplicate = Clip(
            id: id,
            assetID: original.assetID,
            timelineRange: TimeRange(start: adjustedStart, duration: original.timelineRange.duration),
            sourceRange: original.sourceRange,
            transform: original.transform,
            cropRect: original.cropRect,
            opacity: original.opacity,
            volume: original.volume,
            effects: original.effects,
            keyframes: original.keyframes,
            metadata: ClipMetadata(label: (original.metadata.label ?? "Clip") + " (copy)"),
            speed: original.speed,
            transitionIn: original.transitionIn,
            linkGroupID: original.linkGroupID,
            blendMode: original.blendMode,
            overlayPresentation: original.overlayPresentation
        )
        let insertionIndex = MoveClipCommand.insertionIndex(
            for: duplicate,
            in: context.timelineState.timeline.tracks[location.trackIndex].clips
        )
        context.timelineState.timeline.tracks[location.trackIndex].clips.insert(duplicate, at: insertionIndex)
    }

    public func undo(context: EditingContext) throws {
        guard let newClipID else { return }
        for trackIndex in context.timelineState.timeline.tracks.indices {
            context.timelineState.timeline.tracks[trackIndex].clips.removeAll { $0.id == newClipID }
        }
    }
}

/// Add or update an effect on a clip.
public struct SetClipEffectCommand: Command {
    public let name = "Set Effect"
    public let clipID: UUID
    public let effect: EffectInstance
    public var affectedClipIDs: [UUID] { [clipID] }
    private var previousEffects: [EffectInstance]?

    public init(clipID: UUID, effect: EffectInstance) {
        self.clipID = clipID
        self.effect = effect
    }

    public mutating func execute(context: EditingContext) throws {
        let location = try editableClipLocation(for: clipID, context: context)
        let clip = context.timelineState.timeline.tracks[location.trackIndex].clips[location.clipIndex]
        previousEffects = clip.effects

        var effects = clip.effects
        if let idx = effects.firstIndex(where: { $0.type == effect.type }) {
            effects[idx] = effect
        } else {
            effects.append(effect)
        }
        context.timelineState.timeline.tracks[location.trackIndex].clips[location.clipIndex].effects = effects
    }

    public func undo(context: EditingContext) throws {
        guard let prev = previousEffects else { return }
        for trackIndex in context.timelineState.timeline.tracks.indices {
            if let clipIndex = context.timelineState.timeline.tracks[trackIndex].clips.firstIndex(where: { $0.id == clipID }) {
                context.timelineState.timeline.tracks[trackIndex].clips[clipIndex].effects = prev
                return
            }
        }
    }
}

/// Replace the clip's primary visual effect stack with a single effect.
/// Used by AI/MCP setter-style tools that should not accumulate stale effects.
public struct ReplacePrimaryClipEffectCommand: Command {
    public let name = "Replace Primary Effect"
    public let clipID: UUID
    public let effect: EffectInstance
    public var affectedClipIDs: [UUID] { [clipID] }
    private var previousEffects: [EffectInstance]?

    public init(clipID: UUID, effect: EffectInstance) {
        self.clipID = clipID
        self.effect = effect
    }

    public mutating func execute(context: EditingContext) throws {
        try modifyClip(id: clipID, context: context) { clip in
            previousEffects = clip.effects
            if effect.type == "_none" {
                clip.effects = []
            } else {
                clip.effects = [effect]
            }
        }
    }

    public func undo(context: EditingContext) throws {
        guard let prev = previousEffects else { return }
        try modifyClip(id: clipID, context: context) { $0.effects = prev }
    }
}

/// Set clip playback speed.
public struct SetClipSpeedCommand: Command {
    public let name = "Set Clip Speed"
    public let clipID: UUID
    public let newSpeed: Double
    public var affectedClipIDs: [UUID] { [clipID] }
    private var previousSpeed: Double?
    private var previousTimelineRange: TimeRange?

    public init(clipID: UUID, speed: Double) {
        self.clipID = clipID
        self.newSpeed = max(speed, 0.1)
    }

    public mutating func execute(context: EditingContext) throws {
        let location = try editableClipLocation(for: clipID, context: context)
        let clip = context.timelineState.timeline.tracks[location.trackIndex].clips[location.clipIndex]
        previousSpeed = clip.speed
        previousTimelineRange = clip.timelineRange

        // Changing speed changes the effective duration on the timeline
        let newDuration = clip.sourceRange.duration / newSpeed
        context.timelineState.timeline.tracks[location.trackIndex].clips[location.clipIndex].speed = newSpeed
        context.timelineState.timeline.tracks[location.trackIndex].clips[location.clipIndex].timelineRange = TimeRange(
            start: clip.timelineRange.start,
            duration: newDuration
        )
    }

    public func undo(context: EditingContext) throws {
        guard let prev = previousSpeed, let prevRange = previousTimelineRange else { return }
        for trackIndex in context.timelineState.timeline.tracks.indices {
            if let clipIndex = context.timelineState.timeline.tracks[trackIndex].clips.firstIndex(where: { $0.id == clipID }) {
                context.timelineState.timeline.tracks[trackIndex].clips[clipIndex].speed = prev
                context.timelineState.timeline.tracks[trackIndex].clips[clipIndex].timelineRange = prevRange
                return
            }
        }
    }
}

/// Set clip transition.
public struct SetClipTransitionCommand: Command {
    public let name = "Set Transition"
    public let clipID: UUID
    public let newTransition: ClipTransition
    public var affectedClipIDs: [UUID] { [clipID] }
    private var previousTransition: ClipTransition?

    public init(clipID: UUID, transition: ClipTransition) {
        self.clipID = clipID
        self.newTransition = transition
    }

    public mutating func execute(context: EditingContext) throws {
        let location = try editableClipLocation(for: clipID, context: context)
        previousTransition = context.timelineState.timeline.tracks[location.trackIndex].clips[location.clipIndex].transitionIn
        context.timelineState.timeline.tracks[location.trackIndex].clips[location.clipIndex].transitionIn = newTransition
    }

    public func undo(context: EditingContext) throws {
        guard let prev = previousTransition else { return }
        for trackIndex in context.timelineState.timeline.tracks.indices {
            if let clipIndex = context.timelineState.timeline.tracks[trackIndex].clips.firstIndex(where: { $0.id == clipID }) {
                context.timelineState.timeline.tracks[trackIndex].clips[clipIndex].transitionIn = prev
                return
            }
        }
    }
}

/// Set clip blend mode.
public struct SetClipBlendModeCommand: Command {
    public let name = "Set Blend Mode"
    public let clipID: UUID
    public let newBlendMode: BlendMode
    public var affectedClipIDs: [UUID] { [clipID] }
    private var previousBlendMode: BlendMode?

    public init(clipID: UUID, blendMode: BlendMode) {
        self.clipID = clipID
        self.newBlendMode = blendMode
    }

    public mutating func execute(context: EditingContext) throws {
        try modifyClip(id: clipID, context: context) { clip in
            previousBlendMode = clip.blendMode
            clip.blendMode = newBlendMode
        }
    }

    public func undo(context: EditingContext) throws {
        guard let prev = previousBlendMode else { return }
        try modifyClip(id: clipID, context: context) { $0.blendMode = prev }
    }
}

/// Link or unlink a set of clips (shared linkGroupID).
public struct LinkClipsCommand: Command {
    public let name = "Link Clips"
    public let clipIDs: [UUID]
    public let newLinkGroupID: UUID?
    public var affectedClipIDs: [UUID] { clipIDs }
    private var previousLinkGroupIDs: [UUID: UUID?] = [:]

    public init(clipIDs: [UUID], linkGroupID: UUID?) {
        self.clipIDs = clipIDs
        self.newLinkGroupID = linkGroupID
    }

    public mutating func execute(context: EditingContext) throws {
        for clipID in clipIDs {
            for ti in context.timelineState.timeline.tracks.indices {
                if let ci = context.timelineState.timeline.tracks[ti].clips.firstIndex(where: { $0.id == clipID }) {
                    previousLinkGroupIDs[clipID] = context.timelineState.timeline.tracks[ti].clips[ci].linkGroupID
                    context.timelineState.timeline.tracks[ti].clips[ci].linkGroupID = newLinkGroupID
                }
            }
        }
    }

    public func undo(context: EditingContext) throws {
        for (clipID, prevGroup) in previousLinkGroupIDs {
            for ti in context.timelineState.timeline.tracks.indices {
                if let ci = context.timelineState.timeline.tracks[ti].clips.firstIndex(where: { $0.id == clipID }) {
                    context.timelineState.timeline.tracks[ti].clips[ci].linkGroupID = prevGroup
                }
            }
        }
    }
}

/// Remove an effect from a clip by effect ID.
public struct RemoveClipEffectCommand: Command {
    public let name = "Remove Effect"
    public let clipID: UUID
    public let effectID: UUID
    public var affectedClipIDs: [UUID] { [clipID] }
    private var removedEffect: EffectInstance?
    private var removedIndex: Int?

    public init(clipID: UUID, effectID: UUID) {
        self.clipID = clipID
        self.effectID = effectID
    }

    public mutating func execute(context: EditingContext) throws {
        let location = try editableClipLocation(for: clipID, context: context)
        let effects = context.timelineState.timeline.tracks[location.trackIndex].clips[location.clipIndex].effects
        if let idx = effects.firstIndex(where: { $0.id == effectID }) {
            removedEffect = effects[idx]
            removedIndex = idx
            context.timelineState.timeline.tracks[location.trackIndex].clips[location.clipIndex].effects.remove(at: idx)
        }
    }

    public func undo(context: EditingContext) throws {
        guard let effect = removedEffect, let idx = removedIndex else { return }
        for ti in context.timelineState.timeline.tracks.indices {
            if let ci = context.timelineState.timeline.tracks[ti].clips.firstIndex(where: { $0.id == clipID }) {
                let safeIdx = min(idx, context.timelineState.timeline.tracks[ti].clips[ci].effects.count)
                context.timelineState.timeline.tracks[ti].clips[ci].effects.insert(effect, at: safeIdx)
                return
            }
        }
    }
}

// MARK: - Slip Edit

/// Slip edit: shifts which portion of source media is shown without moving
/// the clip on the timeline or changing its duration.
public struct SlipClipCommand: Command {
    public let name = "Slip Clip"
    public let clipID: UUID
    public let delta: TimeInterval
    public var affectedClipIDs: [UUID] { [clipID] }
    private var previousSourceRange: TimeRange?

    public init(clipID: UUID, delta: TimeInterval) {
        self.clipID = clipID
        self.delta = delta
    }

    public mutating func execute(context: EditingContext) throws {
        let location = try editableClipLocation(for: clipID, context: context)
        let clip = context.timelineState.timeline.tracks[location.trackIndex].clips[location.clipIndex]
        previousSourceRange = clip.sourceRange

        let newStart = clip.sourceRange.start + delta
        let newEnd = clip.sourceRange.end + delta
        guard newStart >= 0 else {
            throw CommandError.splitPointOutOfRange
        }

        context.timelineState.timeline.tracks[location.trackIndex].clips[location.clipIndex].sourceRange = TimeRange(
            start: newStart,
            end: newEnd
        )
    }

    public func undo(context: EditingContext) throws {
        guard let prev = previousSourceRange else { return }
        try modifyClip(id: clipID, context: context) { $0.sourceRange = prev }
    }
}

// MARK: - Ripple Trim

/// Ripple trim: trims a clip's head or tail and shifts all subsequent clips
/// on the same track to close or open the resulting gap.
public struct RippleTrimCommand: Command {
    public let name = "Ripple Trim"
    public let clipID: UUID
    public let edge: TrimEdge
    public let delta: TimeInterval
    public var affectedClipIDs: [UUID] { [clipID] + shiftedClipIDs }

    private var previousSourceRange: TimeRange?
    private var previousTimelineRange: TimeRange?
    private var shiftedClipIDs: [UUID] = []
    private var trackIndex: Int?

    public init(clipID: UUID, edge: TrimEdge, delta: TimeInterval) {
        self.clipID = clipID
        self.edge = edge
        self.delta = delta
    }

    public mutating func execute(context: EditingContext) throws {
        let location = try editableClipLocation(for: clipID, context: context)
        trackIndex = location.trackIndex
        let clip = context.timelineState.timeline.tracks[location.trackIndex].clips[location.clipIndex]
        previousSourceRange = clip.sourceRange
        previousTimelineRange = clip.timelineRange

        let timelineShift: TimeInterval

        switch edge {
        case .head:
            // Positive delta = trim more from head (clip gets shorter, starts later in source)
            let newSourceStart = clip.sourceRange.start + delta
            let newTimelineStart = clip.timelineRange.start + delta
            guard newSourceStart >= 0, newTimelineStart >= 0,
                  newSourceStart < clip.sourceRange.end else {
                throw CommandError.splitPointOutOfRange
            }
            context.timelineState.timeline.tracks[location.trackIndex].clips[location.clipIndex].sourceRange = TimeRange(
                start: newSourceStart,
                end: clip.sourceRange.end
            )
            context.timelineState.timeline.tracks[location.trackIndex].clips[location.clipIndex].timelineRange = TimeRange(
                start: newTimelineStart,
                end: clip.timelineRange.end
            )
            // Downstream clips shift by delta (negative delta = gap closes)
            timelineShift = delta

        case .tail:
            // Positive delta = extend tail (clip gets longer), negative = shorten
            let newSourceEnd = clip.sourceRange.end + delta
            let newTimelineEnd = clip.timelineRange.end + delta
            guard newSourceEnd > clip.sourceRange.start,
                  newTimelineEnd > clip.timelineRange.start else {
                throw CommandError.splitPointOutOfRange
            }
            context.timelineState.timeline.tracks[location.trackIndex].clips[location.clipIndex].sourceRange = TimeRange(
                start: clip.sourceRange.start,
                end: newSourceEnd
            )
            context.timelineState.timeline.tracks[location.trackIndex].clips[location.clipIndex].timelineRange = TimeRange(
                start: clip.timelineRange.start,
                end: newTimelineEnd
            )
            timelineShift = delta
        }

        // Shift all downstream clips on the same track
        let clipEnd = clip.timelineRange.end
        let clips = context.timelineState.timeline.tracks[location.trackIndex].clips
        for i in clips.indices {
            let other = clips[i]
            guard other.id != clipID, other.timelineRange.start >= clipEnd else { continue }
            shiftedClipIDs.append(other.id)
            context.timelineState.timeline.tracks[location.trackIndex].clips[i].timelineRange = TimeRange(
                start: other.timelineRange.start + timelineShift,
                end: other.timelineRange.end + timelineShift
            )
        }
    }

    public func undo(context: EditingContext) throws {
        guard let prevSource = previousSourceRange,
              let prevTimeline = previousTimelineRange,
              let ti = trackIndex else { return }

        // Restore the trimmed clip
        if let ci = context.timelineState.timeline.tracks[ti].clips.firstIndex(where: { $0.id == clipID }) {
            context.timelineState.timeline.tracks[ti].clips[ci].sourceRange = prevSource
            context.timelineState.timeline.tracks[ti].clips[ci].timelineRange = prevTimeline
        }

        // Reverse the shift on downstream clips
        let timelineShift = delta
        for shiftedID in shiftedClipIDs {
            if let ci = context.timelineState.timeline.tracks[ti].clips.firstIndex(where: { $0.id == shiftedID }) {
                let current = context.timelineState.timeline.tracks[ti].clips[ci].timelineRange
                context.timelineState.timeline.tracks[ti].clips[ci].timelineRange = TimeRange(
                    start: current.start - timelineShift,
                    end: current.end - timelineShift
                )
            }
        }
    }
}

// MARK: - Text Overlay Commands

/// Add a text overlay to a clip.
public struct AddTextOverlayCommand: Command {
    public let name = "Add Text Overlay"
    public let clipID: UUID
    public let overlay: TextOverlay
    public var affectedClipIDs: [UUID] { [clipID] }

    public init(clipID: UUID, overlay: TextOverlay) {
        self.clipID = clipID
        self.overlay = overlay
    }

    public mutating func execute(context: EditingContext) throws {
        try modifyClip(id: clipID, context: context) { clip in
            clip.textOverlays.append(overlay)
        }
    }

    public func undo(context: EditingContext) throws {
        try modifyClip(id: clipID, context: context) { clip in
            clip.textOverlays.removeAll { $0.id == overlay.id }
        }
    }
}

/// Remove a text overlay from a clip.
public struct RemoveTextOverlayCommand: Command {
    public let name = "Remove Text Overlay"
    public let clipID: UUID
    public let overlayID: UUID
    public var affectedClipIDs: [UUID] { [clipID] }
    private var removedOverlay: TextOverlay?

    public init(clipID: UUID, overlayID: UUID) {
        self.clipID = clipID
        self.overlayID = overlayID
    }

    public mutating func execute(context: EditingContext) throws {
        try modifyClip(id: clipID, context: context) { clip in
            if let idx = clip.textOverlays.firstIndex(where: { $0.id == overlayID }) {
                removedOverlay = clip.textOverlays[idx]
                clip.textOverlays.remove(at: idx)
            }
        }
    }

    public func undo(context: EditingContext) throws {
        guard let overlay = removedOverlay else { return }
        try modifyClip(id: clipID, context: context) { clip in
            clip.textOverlays.append(overlay)
        }
    }
}

// MARK: - Speed Ramp Command

/// Apply a speed ramp by setting keyframes on the "speed" track.
public struct ApplySpeedRampCommand: Command {
    public let name = "Apply Speed Ramp"
    public let clipID: UUID
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    public let speedStart: Double
    public let speedEnd: Double
    public let easing: KeyframeInterpolation
    public var affectedClipIDs: [UUID] { [clipID] }
    private var previousSpeedKeyframes: [Keyframe]?

    public init(
        clipID: UUID,
        startTime: TimeInterval,
        endTime: TimeInterval,
        speedStart: Double,
        speedEnd: Double,
        easing: KeyframeInterpolation = .easeInOut
    ) {
        self.clipID = clipID
        self.startTime = startTime
        self.endTime = endTime
        self.speedStart = speedStart
        self.speedEnd = speedEnd
        self.easing = easing
    }

    public mutating func execute(context: EditingContext) throws {
        try modifyClip(id: clipID, context: context) { clip in
            previousSpeedKeyframes = clip.keyframes.tracks["speed"]
            let keyframes = [
                Keyframe(time: startTime, value: speedStart, interpolation: easing),
                Keyframe(time: endTime, value: speedEnd, interpolation: easing)
            ]
            clip.keyframes.tracks["speed"] = keyframes
        }
    }

    public func undo(context: EditingContext) throws {
        try modifyClip(id: clipID, context: context) { clip in
            clip.keyframes.tracks["speed"] = previousSpeedKeyframes
        }
    }
}

// MARK: - Zoom Effect Command

/// Add a zoom effect by setting keyframes on scale, positionX, and positionY tracks.
public struct AddZoomEffectCommand: Command {
    public let name = "Add Zoom Effect"
    public let clipID: UUID
    public let startTime: TimeInterval
    public let duration: TimeInterval
    public let zoomStart: Double
    public let zoomEnd: Double
    public let centerX: Double
    public let centerY: Double
    public var affectedClipIDs: [UUID] { [clipID] }
    private var previousScaleXKeyframes: [Keyframe]?
    private var previousScaleYKeyframes: [Keyframe]?
    private var previousPositionXKeyframes: [Keyframe]?
    private var previousPositionYKeyframes: [Keyframe]?

    public init(
        clipID: UUID,
        startTime: TimeInterval,
        duration: TimeInterval,
        zoomStart: Double,
        zoomEnd: Double,
        centerX: Double = 0.5,
        centerY: Double = 0.5
    ) {
        self.clipID = clipID
        self.startTime = startTime
        self.duration = duration
        self.zoomStart = zoomStart
        self.zoomEnd = zoomEnd
        self.centerX = centerX
        self.centerY = centerY
    }

    public mutating func execute(context: EditingContext) throws {
        try modifyClip(id: clipID, context: context) { clip in
            previousScaleXKeyframes = clip.keyframes.tracks["scaleX"]
            previousScaleYKeyframes = clip.keyframes.tracks["scaleY"]
            previousPositionXKeyframes = clip.keyframes.tracks["positionX"]
            previousPositionYKeyframes = clip.keyframes.tracks["positionY"]

            let endTime = startTime + duration

            // Uniform scale on both axes — EffectCompositor reads scaleX/scaleY, not "scale".
            let scaleKfs = [
                Keyframe(time: startTime, value: zoomStart, interpolation: .easeIn),
                Keyframe(time: endTime, value: zoomEnd, interpolation: .easeOut)
            ]
            clip.keyframes.tracks["scaleX"] = scaleKfs
            clip.keyframes.tracks["scaleY"] = scaleKfs

            // Position keyframes: keep center point stable during zoom
            // centerX/centerY are 0..1 normalized; offset from 0.5 determines pan
            let panX = (centerX - 0.5) * (zoomEnd - 1.0)
            let panY = (centerY - 0.5) * (zoomEnd - 1.0)
            clip.keyframes.tracks["positionX"] = [
                Keyframe(time: startTime, value: 0, interpolation: .easeIn),
                Keyframe(time: endTime, value: -panX, interpolation: .easeOut)
            ]
            clip.keyframes.tracks["positionY"] = [
                Keyframe(time: startTime, value: 0, interpolation: .easeIn),
                Keyframe(time: endTime, value: -panY, interpolation: .easeOut)
            ]
        }
    }

    public func undo(context: EditingContext) throws {
        try modifyClip(id: clipID, context: context) { clip in
            clip.keyframes.tracks["scaleX"] = previousScaleXKeyframes
            clip.keyframes.tracks["scaleY"] = previousScaleYKeyframes
            clip.keyframes.tracks["positionX"] = previousPositionXKeyframes
            clip.keyframes.tracks["positionY"] = previousPositionYKeyframes
        }
    }
}

// MARK: - Helpers

@MainActor
private func modifyClip(id: UUID, context: EditingContext, _ body: (inout Clip) -> Void) throws {
    let location = try editableClipLocation(for: id, context: context)
    body(&context.timelineState.timeline.tracks[location.trackIndex].clips[location.clipIndex])
}

@MainActor
private func modifyTrack(id: UUID, context: EditingContext, _ body: (inout Track) -> Void) throws {
    guard let index = context.timelineState.timeline.tracks.firstIndex(where: { $0.id == id }) else {
        throw CommandError.trackNotFound(id)
    }
    body(&context.timelineState.timeline.tracks[index])
}

private func pipPresentation(for preset: OverlayPiPPreset) -> OverlayPresentation {
    switch preset {
    case .topLeft, .topRight, .bottomLeft, .bottomRight:
        return OverlayPresentation(
            mode: .pip,
            border: .init(isVisible: true, width: 4, colorHex: "#FFFFFF"),
            shadow: .medium,
            cornerRadius: 16,
            maskShape: .roundedRect,
            snapsToSafeMargins: true,
            entranceAnimation: .scaleIn,
            exitAnimation: .fadeOut
        )
    }
}

private func pipTransform(for preset: OverlayPiPPreset) -> Transform2D {
    let scale = 0.35
    switch preset {
    case .topLeft:
        return Transform2D(positionX: -0.45, positionY: 0.45, scaleX: scale, scaleY: scale)
    case .topRight:
        return Transform2D(positionX: 0.45, positionY: 0.45, scaleX: scale, scaleY: scale)
    case .bottomLeft:
        return Transform2D(positionX: -0.45, positionY: -0.45, scaleX: scale, scaleY: scale)
    case .bottomRight:
        return Transform2D(positionX: 0.45, positionY: -0.45, scaleX: scale, scaleY: scale)
    }
}

// MARK: - Broadcast Overlay

public struct SetBroadcastOverlayCommand: Command {
    public let name = "Set Broadcast Overlay"
    public let config: BroadcastOverlayConfig?
    public var affectedClipIDs: [UUID] { [] }
    public var affectedTrackIDs: [UUID] { [] }
    private var previousConfig: BroadcastOverlayConfig?

    public init(config: BroadcastOverlayConfig?) {
        self.config = config
    }

    public mutating func execute(context: EditingContext) throws {
        previousConfig = context.timelineState.broadcastOverlay
        context.timelineState.broadcastOverlay = config
    }

    public func undo(context: EditingContext) throws {
        context.timelineState.broadcastOverlay = previousConfig
    }
}

/// Set keyframes on a clip's animation track (e.g., "opacity", "scaleX", "positionX").
public struct SetClipKeyframesCommand: Command {
    public let name = "Set Keyframes"
    public let clipID: UUID
    public let track: String
    public let keyframes: [Keyframe]
    public var affectedClipIDs: [UUID] { [clipID] }
    private var previousKeyframes: [Keyframe]?

    public init(clipID: UUID, track: String, keyframes: [Keyframe]) {
        self.clipID = clipID
        self.track = track
        self.keyframes = keyframes
    }

    public mutating func execute(context: EditingContext) throws {
        try modifyClip(id: clipID, context: context) { clip in
            previousKeyframes = clip.keyframes.tracks[track]
            clip.keyframes.tracks[track] = keyframes
        }
    }

    public func undo(context: EditingContext) throws {
        try modifyClip(id: clipID, context: context) { clip in
            if let prev = previousKeyframes {
                clip.keyframes.tracks[track] = prev
            } else {
                clip.keyframes.tracks[track] = nil
            }
        }
    }
}
