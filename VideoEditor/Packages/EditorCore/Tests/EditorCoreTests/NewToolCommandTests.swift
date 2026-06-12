import Testing
import Foundation
@testable import EditorCore

@Suite("New Tool Command Tests")
struct NewToolCommandTests {

    // MARK: - Helpers

    @MainActor
    private func makeContext(with clip: Clip) -> EditingContext {
        let track = Track(name: "V1", type: .video, clips: [clip])
        let timeline = Timeline(tracks: [track])
        return EditingContext(timelineState: TimelineState(timeline: timeline))
    }

    // MARK: - SetMarker with color

    @MainActor
    @Test("SetMarker with custom color stores the color on the marker")
    func setMarkerWithColor() throws {
        let context = EditingContext(timelineState: TimelineState(timeline: Timeline()))

        var cmd = SetMarkerCommand(at: 10.0, label: "Chapter 1", color: "#00FF00")
        try cmd.execute(context: context)

        let markers = context.timelineState.timeline.markers
        #expect(markers.count == 1)
        #expect(markers[0].time == 10.0)
        #expect(markers[0].label == "Chapter 1")
        #expect(markers[0].color == "#00FF00")
    }

    @MainActor
    @Test("SetMarker default color is red")
    func setMarkerDefaultColor() throws {
        let context = EditingContext(timelineState: TimelineState(timeline: Timeline()))

        var cmd = SetMarkerCommand(at: 5.0, label: "Mark")
        try cmd.execute(context: context)

        #expect(context.timelineState.timeline.markers[0].color == "#FF0000")
    }

    @MainActor
    @Test("SetMarker undo removes the marker")
    func setMarkerUndo() throws {
        let context = EditingContext(timelineState: TimelineState(timeline: Timeline()))

        var cmd = SetMarkerCommand(at: 3.0, label: "Test", color: "#0000FF")
        try cmd.execute(context: context)
        #expect(context.timelineState.timeline.markers.count == 1)

        try cmd.undo(context: context)
        #expect(context.timelineState.timeline.markers.isEmpty)
    }

    // MARK: - AddTextOverlay

    @MainActor
    @Test("AddTextOverlay appends overlay to clip and undo removes it")
    func addTextOverlay() throws {
        let clip = Clip(assetID: UUID(), timelineRange: TimeRange(start: 0, end: 10), sourceRange: TimeRange(start: 0, end: 10))
        let context = makeContext(with: clip)

        let overlay = TextOverlay(
            text: "Hello World",
            startTime: 1.0,
            duration: 3.0,
            positionX: 0.5,
            positionY: 0.8,
            fontSize: 48,
            colorHex: "#FFFFFF"
        )

        var cmd = AddTextOverlayCommand(clipID: clip.id, overlay: overlay)
        try cmd.execute(context: context)

        let overlays = context.timelineState.timeline.tracks[0].clips[0].textOverlays
        #expect(overlays.count == 1)
        #expect(overlays[0].text == "Hello World")
        #expect(overlays[0].id == overlay.id)

        try cmd.undo(context: context)
        #expect(context.timelineState.timeline.tracks[0].clips[0].textOverlays.isEmpty)
    }

    @MainActor
    @Test("AddTextOverlay via intent resolver works end-to-end")
    func addTextOverlayViaIntent() throws {
        let clip = Clip(assetID: UUID(), timelineRange: TimeRange(start: 0, end: 10), sourceRange: TimeRange(start: 0, end: 10))
        let context = makeContext(with: clip)
        let resolver = IntentResolver()

        let overlay = TextOverlay(text: "Caption", startTime: 0, duration: 2)
        var cmd = try resolver.resolve(.addTextOverlay(clipID: clip.id, overlay: overlay))
        try cmd.execute(context: context)

        #expect(context.timelineState.timeline.tracks[0].clips[0].textOverlays.count == 1)
    }

    // MARK: - RemoveTextOverlay

    @MainActor
    @Test("RemoveTextOverlay removes overlay and undo restores it")
    func removeTextOverlay() throws {
        let overlay = TextOverlay(text: "Remove Me", startTime: 0, duration: 2)
        let clip = Clip(
            assetID: UUID(),
            timelineRange: TimeRange(start: 0, end: 10),
            sourceRange: TimeRange(start: 0, end: 10),
            textOverlays: [overlay]
        )
        let context = makeContext(with: clip)

        var cmd = RemoveTextOverlayCommand(clipID: clip.id, overlayID: overlay.id)
        try cmd.execute(context: context)
        #expect(context.timelineState.timeline.tracks[0].clips[0].textOverlays.isEmpty)

        try cmd.undo(context: context)
        let restored = context.timelineState.timeline.tracks[0].clips[0].textOverlays
        #expect(restored.count == 1)
        #expect(restored[0].id == overlay.id)
    }

    // MARK: - ApplySpeedRamp

    @MainActor
    @Test("ApplySpeedRamp sets speed keyframes on clip and undo restores previous state")
    func applySpeedRamp() throws {
        let clip = Clip(assetID: UUID(), timelineRange: TimeRange(start: 0, end: 10), sourceRange: TimeRange(start: 0, end: 10))
        let context = makeContext(with: clip)

        var cmd = ApplySpeedRampCommand(
            clipID: clip.id,
            startTime: 2.0,
            endTime: 6.0,
            speedStart: 1.0,
            speedEnd: 2.0,
            easing: .easeInOut
        )
        try cmd.execute(context: context)

        let speedTrack = context.timelineState.timeline.tracks[0].clips[0].keyframes.tracks["speed"]
        #expect(speedTrack != nil)
        #expect(speedTrack?.count == 2)
        #expect(speedTrack?[0].time == 2.0)
        #expect(speedTrack?[0].value == 1.0)
        #expect(speedTrack?[1].time == 6.0)
        #expect(speedTrack?[1].value == 2.0)
        #expect(speedTrack?[0].interpolation == .easeInOut)

        try cmd.undo(context: context)
        // Previously no speed keyframes, so track should be nil after undo
        #expect(context.timelineState.timeline.tracks[0].clips[0].keyframes.tracks["speed"] == nil)
    }

    @MainActor
    @Test("ApplySpeedRamp via intent resolver")
    func applySpeedRampViaIntent() throws {
        let clip = Clip(assetID: UUID(), timelineRange: TimeRange(start: 0, end: 10), sourceRange: TimeRange(start: 0, end: 10))
        let context = makeContext(with: clip)
        let resolver = IntentResolver()

        var cmd = try resolver.resolve(.applySpeedRamp(
            clipID: clip.id,
            startTime: 0,
            endTime: 5,
            speedStart: 0.5,
            speedEnd: 1.0,
            easing: .linear
        ))
        try cmd.execute(context: context)

        let speedTrack = context.timelineState.timeline.tracks[0].clips[0].keyframes.tracks["speed"]
        #expect(speedTrack?.count == 2)
    }

    // MARK: - AddZoomEffect

    @MainActor
    @Test("AddZoomEffect sets scale and position keyframes and undo restores")
    func addZoomEffect() throws {
        let clip = Clip(assetID: UUID(), timelineRange: TimeRange(start: 0, end: 10), sourceRange: TimeRange(start: 0, end: 10))
        let context = makeContext(with: clip)

        var cmd = AddZoomEffectCommand(
            clipID: clip.id,
            startTime: 1.0,
            duration: 3.0,
            zoomStart: 1.0,
            zoomEnd: 1.5,
            centerX: 0.5,
            centerY: 0.5
        )
        try cmd.execute(context: context)

        let clip0 = context.timelineState.timeline.tracks[0].clips[0]
        // EffectCompositor reads scaleX/scaleY (not "scale"), so AddZoomEffectCommand
        // writes uniform scale to both axes.
        let scaleXTrack = clip0.keyframes.tracks["scaleX"]
        let scaleYTrack = clip0.keyframes.tracks["scaleY"]
        let posXTrack = clip0.keyframes.tracks["positionX"]
        let posYTrack = clip0.keyframes.tracks["positionY"]

        #expect(scaleXTrack != nil)
        #expect(scaleXTrack?.count == 2)
        #expect(scaleXTrack?[0].value == 1.0)
        #expect(scaleXTrack?[1].value == 1.5)
        #expect(scaleXTrack?[0].time == 1.0)
        #expect(scaleXTrack?[1].time == 4.0) // startTime + duration
        #expect(scaleYTrack?.count == 2)
        #expect(scaleYTrack?[1].value == 1.5)

        #expect(posXTrack != nil)
        #expect(posYTrack != nil)

        try cmd.undo(context: context)

        let undone = context.timelineState.timeline.tracks[0].clips[0]
        #expect(undone.keyframes.tracks["scaleX"] == nil)
        #expect(undone.keyframes.tracks["scaleY"] == nil)
        #expect(undone.keyframes.tracks["positionX"] == nil)
        #expect(undone.keyframes.tracks["positionY"] == nil)
    }

    @MainActor
    @Test("AddZoomEffect via intent resolver")
    func addZoomEffectViaIntent() throws {
        let clip = Clip(assetID: UUID(), timelineRange: TimeRange(start: 0, end: 10), sourceRange: TimeRange(start: 0, end: 10))
        let context = makeContext(with: clip)
        let resolver = IntentResolver()

        var cmd = try resolver.resolve(.addZoomEffect(
            clipID: clip.id,
            startTime: 0,
            duration: 5,
            zoomStart: 1.0,
            zoomEnd: 2.0,
            centerX: 0.3,
            centerY: 0.7
        ))
        try cmd.execute(context: context)

        let scaleXTrack = context.timelineState.timeline.tracks[0].clips[0].keyframes.tracks["scaleX"]
        #expect(scaleXTrack?.count == 2)
        #expect(scaleXTrack?[1].value == 2.0)
    }
}
