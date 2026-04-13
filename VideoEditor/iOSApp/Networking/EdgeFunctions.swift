import Foundation

/// Thin HTTP client for invoking Supabase Edge Functions used by this app.
/// Keeps edge-function concerns out of `SupabaseShortsClient`, which is scoped
/// to the DB + storage domain.
enum EdgeFunctions {
    /// Result of a Claude-driven caption regeneration.
    struct RegeneratedCaption: Decodable {
        let title: String?
        let body: String
        let hashtags: [String]
    }

    /// Tone directives accepted by the `regenerate-caption` edge function.
    enum Tone: String {
        case `default`
        case spicier
        case moreProfessional = "more_professional"
    }

    enum EdgeError: Error, LocalizedError {
        case transport(URLError)
        case badStatus(Int, String)
        case decode(Error)

        var errorDescription: String? {
            switch self {
            case .transport(let err): return "Network error: \(err.localizedDescription)"
            case .badStatus(let code, let detail):
                return "Edge function failed (\(code)): \(detail)"
            case .decode(let err): return "Response decode failed: \(err.localizedDescription)"
            }
        }
    }

    /// Call the `regenerate-caption` edge function and decode its response.
    static func regenerateCaption(
        shortID: UUID,
        platform: Platform,
        tone: Tone = .default
    ) async throws -> RegeneratedCaption {
        let endpoint = Config.supabaseURL.appendingPathComponent("functions/v1/regenerate-caption")

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(Config.supabaseAnonKey)", forHTTPHeaderField: "Authorization")
        request.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")

        struct Payload: Encodable {
            let short_id: String
            let platform: String
            let tone: String
        }
        let payload = Payload(
            short_id: shortID.uuidString.lowercased(),
            platform: platform.rawValue,
            tone: tone.rawValue
        )
        request.httpBody = try JSONEncoder().encode(payload)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let urlErr as URLError {
            throw EdgeError.transport(urlErr)
        }

        guard let http = response as? HTTPURLResponse else {
            throw EdgeError.badStatus(-1, "No HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<non-utf8 body>"
            throw EdgeError.badStatus(http.statusCode, body)
        }

        do {
            return try JSONDecoder().decode(RegeneratedCaption.self, from: data)
        } catch {
            throw EdgeError.decode(error)
        }
    }
}
