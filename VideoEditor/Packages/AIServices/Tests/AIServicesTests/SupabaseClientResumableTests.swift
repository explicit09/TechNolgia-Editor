import Testing
import Foundation
@testable import AIServices

// MARK: - URLProtocol stub

/// Captures every request that passes through a `URLSession` and feeds back
/// synthetic responses. Records are stored on the class; tests should reset
/// state at the start of each run via `StubURLProtocol.reset`.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Recorded: Sendable {
        let method: String
        let url: URL
        let headers: [String: String]
        let body: Data
    }

    // nonisolated(unsafe) because URLProtocol is driven by URLSession's
    // internal queue; tests synchronize via `await` on session calls.
    nonisolated(unsafe) static var requests: [Recorded] = []
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest, Data) -> (HTTPURLResponse, Data))?
    static let lock = NSLock()

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        requests = []
        handler = nil
    }

    static func snapshot() -> [Recorded] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // Read body (URLSession.upload(for:from:) exposes body via
        // httpBodyStream, not httpBody, so drain the stream).
        var bodyData = Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buf = [UInt8](repeating: 0, count: 64 * 1024)
            while stream.hasBytesAvailable {
                let n = stream.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                bodyData.append(buf, count: n)
            }
        } else if let body = request.httpBody {
            bodyData = body
        }

        let recorded = Recorded(
            method: request.httpMethod ?? "GET",
            url: request.url!,
            headers: (request.allHTTPHeaderFields ?? [:]),
            body: bodyData
        )
        Self.lock.lock()
        Self.requests.append(recorded)
        let h = Self.handler
        Self.lock.unlock()

        guard let h else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (response, data) = h(request, bodyData)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - Tests

@Suite("SupabaseClient TUS resumable upload", .serialized)
struct SupabaseClientResumableTests {

    private func makeSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: cfg)
    }

    @Test("uploads 17 KB file in 3 chunks with correct offsets and headers")
    func uploadFlow() async throws {
        StubURLProtocol.reset()

        // 17 KB temp file.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tus_\(UUID().uuidString).bin")
        let totalBytes = 17 * 1024
        let payload = Data(repeating: 0, count: totalBytes)
        try payload.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let baseURL = URL(string: "https://example.supabase.co/")!
        let uploadLocation = "https://example.supabase.co/storage/v1/upload/resumable/fake-upload-id"

        // Advance server-side offset as each PATCH arrives.
        nonisolated(unsafe) var serverOffset: Int64 = 0
        StubURLProtocol.handler = { req, body in
            let method = req.httpMethod ?? ""
            if method == "POST" {
                let resp = HTTPURLResponse(
                    url: req.url!,
                    statusCode: 201,
                    httpVersion: "HTTP/1.1",
                    headerFields: [
                        "Location": uploadLocation,
                        "Tus-Resumable": "1.0.0"
                    ]
                )!
                return (resp, Data())
            } else if method == "PATCH" {
                serverOffset += Int64(body.count)
                let resp = HTTPURLResponse(
                    url: req.url!,
                    statusCode: 204,
                    httpVersion: "HTTP/1.1",
                    headerFields: [
                        "Upload-Offset": String(serverOffset),
                        "Tus-Resumable": "1.0.0"
                    ]
                )!
                return (resp, Data())
            }
            let resp = HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (resp, Data())
        }

        let client = SupabaseClient(
            baseURL: baseURL,
            serviceKey: "test-service-key",
            schema: "shorts_app",
            session: makeSession()
        )

        nonisolated(unsafe) var progressSamples: [Double] = []
        try await client.uploadFileResumable(
            bucket: "shorts-videos",
            objectPath: "abc.mp4",
            fileURL: tmp,
            contentType: "video/mp4",
            chunkSizeBytes: 8192,
            progress: { p in progressSamples.append(p) }
        )

        let reqs = StubURLProtocol.snapshot()

        // 1 POST + 3 PATCH (8192 + 8192 + 1024 = 17408).
        #expect(reqs.count == 4)

        // POST create.
        let post = reqs[0]
        #expect(post.method == "POST")
        #expect(post.url.absoluteString == "https://example.supabase.co/storage/v1/upload/resumable")
        #expect(post.headers["Authorization"] == "Bearer test-service-key")
        #expect(post.headers["apikey"] == "test-service-key")
        #expect(post.headers["Tus-Resumable"] == "1.0.0")
        #expect(post.headers["Upload-Length"] == "17408")
        #expect(post.headers["x-upsert"] == "true")

        // Upload-Metadata must be well-formed base64 of the three fields.
        let metaHeader = post.headers["Upload-Metadata"] ?? ""
        let expectedMeta = SupabaseClient.tusUploadMetadata(
            bucketName: "shorts-videos", objectName: "abc.mp4", contentType: "video/mp4"
        )
        #expect(metaHeader == expectedMeta)
        // Sanity: decodes back to the original fields.
        let parts = metaHeader.split(separator: ",").map(String.init)
        #expect(parts.count == 3)
        func decode(_ pair: String) -> (String, String)? {
            let pieces = pair.split(separator: " ", maxSplits: 1).map(String.init)
            guard pieces.count == 2, let d = Data(base64Encoded: pieces[1]),
                  let s = String(data: d, encoding: .utf8) else { return nil }
            return (pieces[0], s)
        }
        let decoded = Dictionary(uniqueKeysWithValues: parts.compactMap(decode))
        #expect(decoded["bucketName"] == "shorts-videos")
        #expect(decoded["objectName"] == "abc.mp4")
        #expect(decoded["contentType"] == "video/mp4")

        // PATCH #1 — offset 0, 8192 bytes.
        let patch1 = reqs[1]
        #expect(patch1.method == "PATCH")
        #expect(patch1.url.absoluteString == uploadLocation)
        #expect(patch1.headers["Upload-Offset"] == "0")
        #expect(patch1.headers["Content-Type"] == "application/offset+octet-stream")
        #expect(patch1.headers["Tus-Resumable"] == "1.0.0")
        #expect(patch1.body.count == 8192)

        // PATCH #2 — offset 8192, 8192 bytes.
        let patch2 = reqs[2]
        #expect(patch2.method == "PATCH")
        #expect(patch2.headers["Upload-Offset"] == "8192")
        #expect(patch2.body.count == 8192)

        // PATCH #3 — offset 16384, 1024 bytes (tail).
        let patch3 = reqs[3]
        #expect(patch3.method == "PATCH")
        #expect(patch3.headers["Upload-Offset"] == "16384")
        #expect(patch3.body.count == 1024)

        // Progress: 3 samples ending at 1.0.
        #expect(progressSamples.count == 3)
        if let last = progressSamples.last {
            #expect(abs(last - 1.0) < 0.0001)
        }
    }

    @Test("throws httpError on non-2xx create response")
    func createFailureThrows() async throws {
        StubURLProtocol.reset()

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tus_\(UUID().uuidString).bin")
        try Data(repeating: 0, count: 100).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        StubURLProtocol.handler = { req, _ in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 413, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (resp, Data("payload too large".utf8))
        }

        let client = SupabaseClient(
            baseURL: URL(string: "https://example.supabase.co/")!,
            serviceKey: "k",
            session: makeSession()
        )

        await #expect(throws: SupabaseError.self) {
            try await client.uploadFileResumable(
                bucket: "shorts-videos",
                objectPath: "x.mp4",
                fileURL: tmp,
                contentType: "video/mp4",
                chunkSizeBytes: 4096
            )
        }
    }

    @Test("metadata encoding uses standard base64")
    func metadataEncoding() {
        // "shorts-videos" -> c2hvcnRzLXZpZGVvcw==
        // "abc.mp4" -> YWJjLm1wNA==
        // "video/mp4" -> dmlkZW8vbXA0
        let meta = SupabaseClient.tusUploadMetadata(
            bucketName: "shorts-videos", objectName: "abc.mp4", contentType: "video/mp4"
        )
        #expect(meta == "bucketName c2hvcnRzLXZpZGVvcw==,objectName YWJjLm1wNA==,contentType dmlkZW8vbXA0")
    }
}
