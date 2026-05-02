import Foundation

/// After linked A/V clips are split, second halves still share the original `linkGroupID`.
/// Assign a new shared ID so each half-pair is independently movable (matches `AppState.relinkAfterSplit`).
public enum LinkedClipRelinker {
    @MainActor
    public static func relinkSecondHalvesAfterSplit(context: EditingContext, splitClipIDs: [UUID]) {
        let allClips = context.timelineState.timeline.tracks.flatMap(\.clips)
        let splitClips = allClips.filter { splitClipIDs.contains($0.id) }
        guard let linkGroup = splitClips.first?.linkGroupID else { return }

        let secondHalves = allClips.filter { $0.linkGroupID == linkGroup && !splitClipIDs.contains($0.id) }
        guard secondHalves.count > 1 else { return }

        let newLinkGroup = UUID()
        for clip in secondHalves {
            for (ti, track) in context.timelineState.timeline.tracks.enumerated() {
                if let ci = track.clips.firstIndex(where: { $0.id == clip.id }) {
                    context.timelineState.timeline.tracks[ti].clips[ci].linkGroupID = newLinkGroup
                }
            }
        }
    }
}
