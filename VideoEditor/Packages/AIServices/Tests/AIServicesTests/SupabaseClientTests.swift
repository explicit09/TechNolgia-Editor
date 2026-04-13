import Testing
import Foundation
@testable import AIServices

@Suite("SupabaseClient tests")
struct SupabaseClientTests {
    @Test("buildInsertRequest embeds service key in Authorization + apikey headers")
    func insertRequestHeaders() throws {
        let client = SupabaseClient(
            baseURL: URL(string: "https://example.supabase.co")!,
            serviceKey: "testkey"
        )
        let request = try client.buildInsertRequest(
            table: "shorts",
            body: ["id": "abc"]
        )

        #expect(request.url?.absoluteString == "https://example.supabase.co/rest/v1/shorts")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer testkey")
        #expect(request.value(forHTTPHeaderField: "apikey") == "testkey")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Prefer") == "return=representation")
    }

    @Test("buildInsertRequest sets Content-Profile when schema is provided")
    func insertRequestSchemaProfile() throws {
        let client = SupabaseClient(
            baseURL: URL(string: "https://example.supabase.co")!,
            serviceKey: "testkey",
            schema: "shorts_app"
        )
        let request = try client.buildInsertRequest(
            table: "shorts",
            body: ["id": "abc"]
        )

        #expect(request.value(forHTTPHeaderField: "Content-Profile") == "shorts_app")
    }

    @Test("buildStorageUploadRequest targets storage endpoint with correct content-type")
    func storageRequestHeaders() throws {
        let client = SupabaseClient(
            baseURL: URL(string: "https://example.supabase.co")!,
            serviceKey: "testkey"
        )
        let request = try client.buildStorageUploadRequest(
            bucket: "shorts-videos",
            objectPath: "abc.mp4",
            contentType: "video/mp4"
        )

        #expect(request.url?.absoluteString == "https://example.supabase.co/storage/v1/object/shorts-videos/abc.mp4")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer testkey")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "video/mp4")
        #expect(request.value(forHTTPHeaderField: "x-upsert") == "true")
    }
}
