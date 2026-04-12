import Foundation
import AVFoundation
import Vision
import CoreGraphics

/// Maps speaker diarization IDs to face track indices by correlating
/// lip movement with speaker activity windows.
///
/// For each unique speaker:
///   1. Pick their longest solo segment from diarization
///   2. Sample several frames during that segment
///   3. For each tracked face at those times, measure mouth openness variance
///   4. Assign the face with highest mouth activity to that speaker
public struct SpeakerFaceMapper: Sendable {

    public init() {}

    /// Naive fallback: map speakers to faces by first-appearance order, leftmost first.
    public func map(
        speakerSegments: [SpeakerSegment],
        faceTracks: [FaceTrack]
    ) -> [Int: Int] {
        guard !faceTracks.isEmpty, !speakerSegments.isEmpty else { return [:] }

        let faceCount = faceTracks.count
        var mapping: [Int: Int] = [:]
        var nextSlot = 0

        for seg in speakerSegments {
            let id = speakerIDFromString(seg.speakerID)
            if mapping[id] == nil {
                mapping[id] = nextSlot
                nextSlot += 1
                if nextSlot >= faceCount { break }
            }
        }
        return mapping
    }

    /// Accurate mapping via lip-activity correlation. Samples the video at each
    /// speaker's solo windows and measures mouth openness per face.
    public func mapByLipActivity(
        speakerSegments: [SpeakerSegment],
        faceTracks: [FaceTrack],
        videoURL: URL,
        sourceOffset: TimeInterval = 0
    ) async -> [Int: Int] {
        guard !faceTracks.isEmpty, !speakerSegments.isEmpty else { return [:] }
        if faceTracks.count == 1 {
            // One face — every speaker maps to it
            let speakerIDs = Set(speakerSegments.map { speakerIDFromString($0.speakerID) })
            return Dictionary(uniqueKeysWithValues: speakerIDs.map { ($0, 0) })
        }

        // Group speakers by ID, find each speaker's longest solo segment
        var longestSoloByID: [Int: SpeakerSegment] = [:]
        for seg in speakerSegments {
            let id = speakerIDFromString(seg.speakerID)
            let duration = seg.range.end - seg.range.start
            if duration < 1.5 { continue }  // Skip tiny blips
            if let existing = longestSoloByID[id] {
                let existingDur = existing.range.end - existing.range.start
                if duration > existingDur { longestSoloByID[id] = seg }
            } else {
                longestSoloByID[id] = seg
            }
        }

        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)
        generator.maximumSize = CGSize(width: 960, height: 540)

        var scores: [Int: [Int: Double]] = [:]  // [speakerID: [faceIdx: mouthOpenness]]

        for (speakerID, seg) in longestSoloByID {
            // Sample 5 evenly spaced frames inside the solo segment
            let segStart = seg.range.start + sourceOffset
            let segEnd = seg.range.end + sourceOffset
            let sampleCount = 5
            var faceScores: [Int: Double] = [:]
            var sampleHits: [Int: Int] = [:]

            for i in 0..<sampleCount {
                let fraction = (Double(i) + 0.5) / Double(sampleCount)
                let t = segStart + (segEnd - segStart) * fraction
                let cmTime = CMTime(seconds: t, preferredTimescale: 600)
                guard let cgImage = try? generator.copyCGImage(at: cmTime, actualTime: nil) else { continue }

                // Detect landmarks for all faces in the frame
                guard let perFaceOpenness = Self.detectMouthOpennessPerFace(in: cgImage) else { continue }

                // Match each detected face to a tracked face by center distance
                let frameWidth = CGFloat(cgImage.width)
                let frameHeight = CGFloat(cgImage.height)
                for (detectedCenter, openness) in perFaceOpenness {
                    let normalizedCenter = CGPoint(
                        x: detectedCenter.x / frameWidth,
                        y: detectedCenter.y / frameHeight
                    )
                    // Find closest tracked face
                    var bestIdx = 0
                    var bestDist = Double.infinity
                    for (idx, track) in faceTracks.enumerated() {
                        guard let faceCenter = track.interpolatedCenter(at: t) else { continue }
                        let dx = Double(normalizedCenter.x - faceCenter.x)
                        let dy = Double(normalizedCenter.y - faceCenter.y)
                        let dist = (dx * dx + dy * dy).squareRoot()
                        if dist < bestDist { bestDist = dist; bestIdx = idx }
                    }
                    faceScores[bestIdx, default: 0] += openness
                    sampleHits[bestIdx, default: 0] += 1
                }
            }

            // Average openness per face
            var averaged: [Int: Double] = [:]
            for (idx, total) in faceScores {
                let hits = sampleHits[idx] ?? 1
                averaged[idx] = total / Double(hits)
            }
            scores[speakerID] = averaged
        }

        // Assign: for each speaker, take the face with highest mouth openness.
        // Use Hungarian-style greedy assignment to avoid double-assigning the same face.
        var mapping: [Int: Int] = [:]
        var usedFaces: Set<Int> = []
        // Sort speakers by confidence (best score margin), so confident assignments go first
        let rankedSpeakers = scores.keys.sorted { a, b in
            let aMax = scores[a]?.values.max() ?? 0
            let bMax = scores[b]?.values.max() ?? 0
            return aMax > bMax
        }
        for speakerID in rankedSpeakers {
            guard let faceScores = scores[speakerID] else { continue }
            let available = faceScores.filter { !usedFaces.contains($0.key) }
            if let (faceIdx, _) = available.max(by: { $0.value < $1.value }) {
                mapping[speakerID] = faceIdx
                usedFaces.insert(faceIdx)
            }
        }

        // If some speakers didn't get mapped (no samples, sparse diarization),
        // fill them in with remaining faces in left-to-right order.
        let allSpeakerIDs = Set(speakerSegments.map { speakerIDFromString($0.speakerID) })
        for speakerID in allSpeakerIDs where mapping[speakerID] == nil {
            for idx in 0..<faceTracks.count where !usedFaces.contains(idx) {
                mapping[speakerID] = idx
                usedFaces.insert(idx)
                break
            }
        }

        // Final fallback: if nothing got mapped at all, use naive appearance order
        if mapping.isEmpty {
            return map(speakerSegments: speakerSegments, faceTracks: faceTracks)
        }
        return mapping
    }

    /// Detect mouth openness (distance between upper and lower lip) for each face in a frame.
    /// Returns [(face center in pixels, mouth openness 0-1)].
    private static func detectMouthOpennessPerFace(in image: CGImage) -> [(center: CGPoint, openness: Double)]? {
        let request = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil,
              let observations = request.results, !observations.isEmpty else {
            return nil
        }

        let w = CGFloat(image.width)
        let h = CGFloat(image.height)

        var output: [(center: CGPoint, openness: Double)] = []
        for obs in observations {
            // Face center in pixels
            let cx = obs.boundingBox.midX * w
            let cy = (1.0 - obs.boundingBox.midY) * h  // Vision origin = bottom-left

            var openness: Double = 0
            if let outerLips = obs.landmarks?.outerLips?.normalizedPoints, outerLips.count >= 4 {
                // outerLips points are normalized within the face bounding box.
                // Upper lip points are near top of the region; lower lip near bottom.
                // Measure the vertical range relative to face height.
                let ys = outerLips.map { $0.y }
                let minY = ys.min() ?? 0
                let maxY = ys.max() ?? 0
                let range = Double(maxY - minY)
                // Face landmarks normalize to the face bbox. Mouth range / total bbox ≈ how open.
                openness = range
            }
            output.append((center: CGPoint(x: cx, y: cy), openness: openness))
        }
        return output
    }

    private func speakerIDFromString(_ str: String) -> Int {
        let digits = str.filter(\.isNumber)
        return Int(digits) ?? 0
    }
}
