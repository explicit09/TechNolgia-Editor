import Foundation
import EditorCore

/// Deepgram transcription provider.
/// Nova-2 model, word-level timestamps, speaker diarization.
/// $200 free credits on signup.
public final class DeepgramProvider: TranscriptionProvider, @unchecked Sendable {
    public let name = "Deepgram"

    private let apiKey: String
    private let model: String
    private let session: URLSession

    public init(apiKey: String, model: String = "nova-3") {
        self.apiKey = apiKey
        self.model = model
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 600  // 10 min — large files need time to upload + process
        self.session = URLSession(configuration: config)
    }

    public static func fromEnvironment(model: String = "nova-3") -> DeepgramProvider? {
        guard let key = ProcessInfo.processInfo.environment["DEEPGRAM_API_KEY"] else { return nil }
        return DeepgramProvider(apiKey: key, model: model)
    }

    public func transcribe(
        audioURL: URL,
        language: String?,
        enableDiarization: Bool,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> TranscriptionResult {

        // Build query parameters
        var queryItems = [
            URLQueryItem(name: "model", value: model),
            URLQueryItem(name: "smart_format", value: "true"),
            URLQueryItem(name: "punctuate", value: "true"),
            URLQueryItem(name: "utterances", value: "true"),
            URLQueryItem(name: "words", value: "true"),
        ]
        if enableDiarization {
            queryItems.append(URLQueryItem(name: "diarize", value: "true"))
        }
        // `language=multi` lets Nova-3 handle multilingual input without the
        // separate language-detection pass that `detect_language=true` triggers.
        queryItems.append(URLQueryItem(name: "language", value: language ?? "multi"))

        var components = URLComponents(string: "https://api.deepgram.com/v1/listen")!
        components.queryItems = queryItems

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("audio/*", forHTTPHeaderField: "Content-Type")

        progress(0.1)

        // Stream file from disk instead of loading into memory
        let (data, response) = try await session.upload(for: request, fromFile: audioURL)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw DeepgramError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw DeepgramError.apiError(status: httpResponse.statusCode, body: body)
        }

        progress(0.9) // Response received, parsing

        let dgResponse = try JSONDecoder().decode(DeepgramResponse.self, from: data)
        let result = convertResponse(dgResponse)

        progress(1.0)
        return result
    }

    // MARK: - Convert response

    private func convertResponse(_ response: DeepgramResponse) -> TranscriptionResult {
        guard let channel = response.results.channels.first,
              let alternative = channel.alternatives.first else {
            return TranscriptionResult(text: "", words: [])
        }

        let words = alternative.words.map { word in
            TranscriptWord(
                word: word.punctuated_word ?? word.word,
                start: word.start,
                end: word.end,
                confidence: word.confidence
            )
        }

        // Build speaker segments from diarization
        var speakers: [SpeakerSegment]? = nil
        if let dgWords = alternative.words.first, dgWords.speaker != nil {
            speakers = buildSpeakerSegments(from: alternative.words)
        }

        let detectedLanguage = channel.detected_language

        return TranscriptionResult(
            text: alternative.transcript,
            words: words,
            speakers: speakers,
            language: detectedLanguage,
            duration: response.metadata?.duration ?? 0
        )
    }

    private func buildSpeakerSegments(from words: [DeepgramWord]) -> [SpeakerSegment] {
        var segments: [SpeakerSegment] = []
        var currentSpeaker: Int?
        var segmentStart: TimeInterval = 0

        for word in words {
            guard let speaker = word.speaker else { continue }
            if speaker != currentSpeaker {
                if let prev = currentSpeaker {
                    segments.append(SpeakerSegment(
                        speakerID: "Speaker \(prev)",
                        range: TimeRange(start: segmentStart, end: word.start)
                    ))
                }
                currentSpeaker = speaker
                segmentStart = word.start
            }
        }

        // Close last segment
        if let last = currentSpeaker, let lastWord = words.last {
            segments.append(SpeakerSegment(
                speakerID: "Speaker \(last)",
                range: TimeRange(start: segmentStart, end: lastWord.end)
            ))
        }

        return segments
    }
}

// MARK: - Deepgram API response types

private struct DeepgramResponse: Decodable {
    let results: DeepgramResults
    let metadata: DeepgramMetadata?
}

private struct DeepgramMetadata: Decodable {
    let duration: TimeInterval?
}

private struct DeepgramResults: Decodable {
    let channels: [DeepgramChannel]
}

private struct DeepgramChannel: Decodable {
    let alternatives: [DeepgramAlternative]
    let detected_language: String?
}

private struct DeepgramAlternative: Decodable {
    let transcript: String
    let words: [DeepgramWord]
}

private struct DeepgramWord: Decodable {
    let word: String
    let punctuated_word: String?
    let start: TimeInterval
    let end: TimeInterval
    let confidence: Double
    let speaker: Int?
}

// MARK: - DeepgramError

public enum DeepgramError: Error, LocalizedError {
    case invalidResponse
    case apiError(status: Int, body: String)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse: "Invalid response from Deepgram"
        case .apiError(let status, let body): "Deepgram error (\(status)): \(body)"
        }
    }
}
